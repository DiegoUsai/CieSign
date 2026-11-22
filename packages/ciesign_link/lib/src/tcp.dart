import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'channel.dart';
import 'keys.dart';
import 'pairing_offer.dart';

/// Trasporto TCP sulla rete locale: ogni frame è preceduto dalla sua
/// lunghezza su 4 byte (big-endian). Lo stesso formato vale sul BLE, dove i
/// frame vengono poi spezzati secondo la dimensione massima (MTU) negoziata.
class TcpFrameChannel implements FrameChannel {
  TcpFrameChannel(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.listen(_onData, onError: _frames.addError, onDone: _frames.close, cancelOnError: true);
  }

  static const maxFrame = 1 << 20;

  final Socket socket;
  final _frames = StreamController<Uint8List>();
  final _buf = BytesBuilder(copy: false);

  @override
  Stream<Uint8List> get frames => _frames.stream;

  void _onData(Uint8List data) {
    _buf.add(data);
    var bytes = _buf.takeBytes();
    var off = 0;
    while (bytes.length - off >= 4) {
      final len = ByteData.sublistView(bytes, off).getUint32(0);
      if (len > maxFrame) {
        _frames.addError(const LinkException('Frame troppo grande'));
        close();
        return;
      }
      if (bytes.length - off - 4 < len) break;
      _frames.add(Uint8List.fromList(bytes.sublist(off + 4, off + 4 + len)));
      off += 4 + len;
    }
    if (off < bytes.length) _buf.add(bytes.sublist(off));
  }

  @override
  void send(Uint8List frame) {
    final h = Uint8List(4);
    ByteData.sublistView(h).setUint32(0, frame.length);
    socket.add(h);
    socket.add(frame);
  }

  @override
  Future<void> close() async {
    try {
      await socket.flush().timeout(const Duration(seconds: 1));
    } on Object {
      // il collegamento è già chiuso
    }
    socket.destroy();
  }
}

/// Server del PC sulla rete locale. Ascolta su tutte le interfacce e accetta
/// solo smartphone abbinati, oppure chi presenta la prova del QR code attivo.
class PcLinkServer {
  PcLinkServer._(this._server, this.identity, this.lookup);

  /// Porta predefinita; se è occupata si usa una porta libera, che il QR
  /// code e l'annuncio mDNS riportano comunque.
  static const defaultPort = 47321;

  /// Nome del servizio annunciato con mDNS / DNS-SD.
  static const mdnsService = '_ciesign._tcp';

  static Future<PcLinkServer> start(
    DeviceIdentity identity, {
    required PairedDevice? Function(String id) lookup,
    int port = defaultPort,
  }) async {
    ServerSocket s;
    try {
      s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    final server = PcLinkServer._(s, identity, lookup);
    s.listen(server._onSocket);
    return server;
  }

  final ServerSocket _server;
  final DeviceIdentity identity;
  final PairedDevice? Function(String id) lookup;
  final _sessions = StreamController<SecureChannel>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// Offerta di abbinamento attiva, cioè il QR code mostrato a schermo.
  PairingOffer? pendingOffer;

  int get port => _server.port;

  Stream<SecureChannel> get sessions => _sessions.stream;
  Stream<Object> get errors => _errors.stream;

  /// Crea un nuovo QR code di abbinamento con gli indirizzi locali del PC.
  Future<PairingOffer> newPairingOffer({bool bluetooth = false, bool remote = false}) async {
    final addresses = <String>[];
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) addresses.add('${a.address}:$port');
      }
    }
    return pendingOffer = PairingOffer(
      pcId: identity.id,
      pcName: identity.name,
      pcPublicKey: identity.publicKey,
      token: randomBytes(16),
      addresses: addresses,
      bluetooth: bluetooth,
      remote: remote,
    );
  }

  Future<void> _onSocket(Socket s) => accept(TcpFrameChannel(s));

  /// Stretta di mano su un canale arrivato da un altro trasporto, per
  /// esempio WebRTC via internet: la sessione finisce in [sessions] come
  /// quelle della rete locale.
  Future<void> accept(FrameChannel ch) async {
    try {
      final c = await Handshake.acceptAsPc(ch, identity, lookup: lookup, pending: pendingOffer);
      _sessions.add(c);
    } on Object catch (e) {
      _errors.add(e);
      await ch.close();
    }
  }

  Future<void> close() async {
    await _server.close();
    await _sessions.close();
    await _errors.close();
  }
}

/// Collegamento dello smartphone al PC, provando gli indirizzi in ordine.
class PhoneLinkClient {
  static Future<TcpFrameChannel> connect(
    List<String> addresses, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Object? last;
    for (final a in addresses) {
      final i = a.lastIndexOf(':');
      final host = a.substring(0, i).replaceAll('[', '').replaceAll(']', '');
      try {
        final s = await Socket.connect(host, int.parse(a.substring(i + 1)), timeout: timeout);
        return TcpFrameChannel(s);
      } on Object catch (e) {
        last = e;
      }
    }
    throw LinkException('PC non raggiungibile sulla rete locale ($last)');
  }
}

/// Vero se almeno uno degli indirizzi del PC (dal QR code) sta nella stessa
/// sottorete /24 di un'interfaccia del dispositivo. È un indizio, non una
/// prova: serve a capire subito che telefono e PC sono su reti diverse e a
/// proporre il collegamento via internet senza attendere i tempi di attesa.
Future<bool> onSameNetwork(List<String> pcAddresses, {List<String>? localAddresses}) async {
  final local =
      localAddresses ??
      [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
  String? prefix(String ip) {
    final p = ip.split('.');
    return p.length == 4 ? p.take(3).join('.') : null;
  }

  final mine = {for (final a in local) ?prefix(a)};
  for (final a in pcAddresses) {
    final host = a.substring(0, a.lastIndexOf(':'));
    if (mine.contains(prefix(host))) return true;
  }
  return false;
}

/// Il PC non risponde sulla rete locale e il collegamento via internet è
/// disponibile ma spento: l'app chiede all'utente se attivarlo.
class InternetSuggested extends LinkException {
  const InternetSuggested(super.message, {required this.sameNetwork});

  /// Falso se gli indirizzi del PC non sono nemmeno nella sottorete del
  /// telefono.
  final bool sameNetwork;
}
