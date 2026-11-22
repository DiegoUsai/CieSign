import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:ciesign_webrtc/ciesign_webrtc.dart';
import 'package:flutter/foundation.dart';

/// PC abbinato, con gli indirizzi letti dal QR code per ricollegarsi.
class PairedPc {
  PairedPc(this.device, this.addresses);

  final PairedDevice device;
  final List<String> addresses;

  Map<String, Object?> toJson() => {...device.toJson(), 'addresses': addresses};

  factory PairedPc.fromJson(Map<String, Object?> j) =>
      PairedPc(PairedDevice.fromJson(j), ((j['addresses'] as List?) ?? const []).cast<String>());
}

enum LinkState { notPaired, disconnected, connecting, connected }

/// Abbinamento in corso: canale già cifrato e codice di sei cifre da
/// confrontare con quello mostrato sul PC.
class PairingAttempt {
  PairingAttempt._(this._link, this.channel, this.addresses);

  final PhoneLink _link;
  final SecureChannel channel;
  final List<String> addresses;
  final _pcAnswer = Completer<bool>();

  String get sas => channel.sas!;
  String get pcName => channel.peerName;

  /// L'utente conferma (o nega) sul telefono che il codice coincide. Il
  /// Future si completa con true quando anche il PC ha confermato e
  /// l'abbinamento è salvato.
  Future<bool> confirm(bool ok) => _link._confirmPairing(this, ok);

  void cancel() => channel.close();
}

/// Collegamento dello smartphone al PC: identità del telefono, PC abbinato,
/// certificato della CIE già letto e sessione cifrata attiva.
///
/// Nel prototipo i dati stanno in un file privato dell'app; il seme della
/// chiave andrà nell'Android Keystore prima della beta.
///
/// Il collegamento usa la rete locale. Se la build ha un servizio di
/// signaling e l'utente lo attiva ("Non sono sulla stessa rete"), passa anche
/// da internet con **WebRTC**, così funziona con il telefono in 4G/5G o su
/// un'altra Wi-Fi. Quando il PC non risponde e l'opzione è spenta, l'app la
/// propone ([InternetSuggested]).
class PhoneLink extends ChangeNotifier {
  PhoneLink._(this._file, this._internet, this.identity, this.pc, this.certificate, this._rendezvous);

  static Future<PhoneLink> open(
    Directory dir, {
    required String deviceName,
    SignalingConfig? signaling,
    PeerLinkFactory peers = createWebRtcPeer,
  }) async {
    final file = File('${dir.path}${Platform.pathSeparator}collegamento.json');
    Map<String, Object?> j = {};
    if (file.existsSync()) {
      try {
        j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      } on FormatException {
        j = {};
      }
    }
    final idJson = j['identity'] as Map<String, Object?>?;
    final identity = idJson != null ? await DeviceIdentity.fromJson(idJson) : await DeviceIdentity.create(deviceName);
    final pcJson = j['pc'] as Map<String, Object?>?;
    final cert = j['certificate'] as String?;
    final config = signaling ?? SignalingConfig.fromEnvironment();
    final link = PhoneLink._(
      file,
      j['internet'] == true,
      identity,
      pcJson == null ? null : PairedPc.fromJson(pcJson),
      cert == null ? null : base64.decode(cert),
      config == null ? null : Rendezvous(SignalingClient(config), peers),
    );
    link._save();
    return link;
  }

  final File _file;
  final DeviceIdentity identity;
  final Rendezvous? _rendezvous;
  PairedPc? pc;

  /// Vero se questa build sa collegarsi anche via internet.
  bool get remoteAvailable => _rendezvous != null;

  bool _internet;

  /// Scelta dell'utente "Non sono sulla stessa rete": spenta in partenza.
  bool get internetEnabled => _internet;

  /// Vero se il collegamento via internet è disponibile e attivo.
  bool get remoteEnabled => remoteAvailable && _internet;

  /// Ultimo tentativo fallito perché il PC non risponde sulla rete locale
  /// con il collegamento via internet spento: la schermata principale propone
  /// di attivarlo.
  bool suggestInternet = false;

  void setInternetEnabled(bool on) {
    _internet = on;
    suggestInternet = false;
    _save();
    notifyListeners();
  }

  /// Vero se la sessione attiva passa da internet e non dalla rete locale.
  bool viaInternet = false;

  /// Certificato dell'ultima CIE letta: lo si manda al PC senza chiedere di
  /// nuovo la carta, perché è un dato pubblico.
  Uint8List? certificate;

  SecureChannel? _session;
  bool _connecting = false;
  String? lastError;
  final _requests = StreamController<LinkMessage>.broadcast();

  LinkState get state {
    if (pc == null) return LinkState.notPaired;
    if (_session != null) return LinkState.connected;
    return _connecting ? LinkState.connecting : LinkState.disconnected;
  }

  /// Richieste del PC da mostrare all'utente: [CertificateRequest],
  /// [SignRequest] e [Cancel].
  Stream<LinkMessage> get requests => _requests.stream;

  /// Primo abbinamento: si collega agli indirizzi del QR code e fa la
  /// stretta di mano; poi l'utente confronta il codice di sei cifre.
  Future<PairingAttempt> startPairing(PairingOffer offer) async {
    final remote = offer.remote && remoteEnabled ? _rendezvous : null;
    if (offer.addresses.isEmpty && remote == null && !(offer.remote && remoteAvailable)) {
      throw const LinkException('Il QR code non contiene indirizzi: il PC non è collegato a una rete locale');
    }
    final (ch, internet) = await _open(
      offer.addresses,
      () async => Room.forPairing(offer.token),
      remote,
      canSuggest: remoteAvailable,
    );
    final SecureChannel c;
    try {
      c = await Handshake.pairAsPhone(ch, offer, identity);
    } on Object {
      await ch.close();
      rethrow;
    }
    viaInternet = internet;
    final attempt = PairingAttempt._(this, c, offer.addresses);
    _listen(c, attempt);
    return attempt;
  }

  /// Rete locale prima, internet poi. Restituisce il canale e se passa da
  /// internet.
  Future<(FrameChannel, bool)> _open(
    List<String> addresses,
    Future<Room> Function() room,
    Rendezvous? remote, {
    required bool canSuggest,
  }) async {
    Object? lanError;
    var same = true;
    try {
      same = addresses.isNotEmpty && await onSameNetwork(addresses);
    } on Object {
      same = true; // nel dubbio si prova la rete locale
    }
    // Su reti diverse, con internet attivo, non si aspettano i tempi della
    // rete locale; con internet spento la si prova comunque, perché alcune
    // reti instradano più sottoreti.
    if (addresses.isNotEmpty && (same || remote == null)) {
      try {
        return (await PhoneLinkClient.connect(addresses), false);
      } on Object catch (e) {
        lanError = e;
      }
    }
    if (remote == null) {
      if (canSuggest) {
        throw InternetSuggested(
          same ? 'Il PC non risponde sulla rete locale' : 'Il telefono e il PC non sembrano sulla stessa rete',
          sameNetwork: same,
        );
      }
      throw lanError ?? const LinkException('PC non raggiungibile');
    }
    try {
      return (await remote.dial(await room()), true);
    } on Object catch (e) {
      final m = e is LinkException ? e.message : 'servizio di collegamento non raggiungibile ($e)';
      throw LinkException(lanError == null ? m : 'PC non raggiungibile sulla rete locale né via internet: $m');
    }
  }

  Future<bool> _confirmPairing(PairingAttempt a, bool ok) async {
    await a.channel.send(PairConfirm(ok));
    if (!ok) {
      await a.channel.close();
      return false;
    }
    final pcOk = await a._pcAnswer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () => throw const LinkException('Il PC non ha confermato in tempo'),
    );
    if (!pcOk) {
      await a.channel.close();
      return false;
    }
    pc = PairedPc(
      PairedDevice(
        id: a.channel.peerId,
        name: a.channel.peerName,
        publicKey: a.channel.peerPublicKey,
        pairedAt: DateTime.now(),
      ),
      a.addresses,
    );
    _save();
    // La sessione dell'abbinamento diventa quella attiva, come sul PC.
    await _session?.close();
    _session = a.channel;
    lastError = null;
    notifyListeners();
    return true;
  }

  /// Si ricollega al PC abbinato, se non c'è già una sessione attiva.
  Future<void> connect() async {
    final p = pc;
    if (p == null || _session != null || _connecting) return;
    _connecting = true;
    notifyListeners();
    try {
      final (ch, internet) = await _open(
        p.addresses,
        () => Room.forPairedDevices(identity.keyPair, p.device.publicKey),
        remoteEnabled ? _rendezvous : null,
        canSuggest: remoteAvailable,
      );
      try {
        final c = await Handshake.helloAsPhone(ch, p.device, identity);
        _session = c;
        viaInternet = internet;
        suggestInternet = false;
        _listen(c, null);
        lastError = null;
      } on Object {
        await ch.close();
        rethrow;
      }
    } on InternetSuggested catch (e) {
      lastError = e.message;
      suggestInternet = true;
    } on Object catch (e) {
      lastError = '$e';
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  void _listen(SecureChannel c, PairingAttempt? attempt) {
    c.messages.listen(
      (m) {
        switch (m) {
          case PairConfirm(:final ok):
            if (attempt != null && !attempt._pcAnswer.isCompleted) attempt._pcAnswer.complete(ok);
          case Ping():
            c.send(const Pong());
          case Pong():
            break;
          case CertificateRequest() || SignRequest() || Cancel():
            if (c == _session) _requests.add(m);
          default:
            break;
        }
      },
      onError: (Object e) {
        lastError = '$e';
        _drop(c, attempt);
      },
      onDone: () => _drop(c, attempt),
    );
  }

  void _drop(SecureChannel c, PairingAttempt? attempt) {
    if (attempt != null && !attempt._pcAnswer.isCompleted) {
      attempt._pcAnswer.completeError(const LinkException('Il PC ha chiuso il collegamento'));
    }
    if (_session == c) {
      _session = null;
      notifyListeners();
    }
  }

  /// Invia una risposta al PC sulla sessione attiva.
  Future<void> send(LinkMessage m) async {
    final s = _session;
    if (s == null) throw const LinkException('Il PC non è collegato');
    await s.send(m);
  }

  void rememberCertificate(Uint8List cert) {
    certificate = cert;
    _save();
    notifyListeners();
  }

  Future<void> unpair() async {
    await _session?.close();
    _session = null;
    pc = null;
    _save();
    notifyListeners();
  }

  void _save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({
        'identity': identity.toJson(),
        if (_internet) 'internet': true,
        if (pc != null) 'pc': pc!.toJson(),
        if (certificate != null) 'certificate': base64.encode(certificate!),
      }),
    );
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    // La sessione può chiudersi dopo dispose(), quando nessuno ascolta più.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session?.close();
    _rendezvous?.signaling.close();
    _requests.close();
    super.dispose();
  }
}
