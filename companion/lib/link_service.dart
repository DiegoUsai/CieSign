import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_link/ciesign_link.dart';
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
class PhoneLink extends ChangeNotifier {
  PhoneLink._(this._file, this.identity, this.pc, this.certificate);

  static Future<PhoneLink> open(Directory dir, {required String deviceName}) async {
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
    final link = PhoneLink._(
      file,
      identity,
      pcJson == null ? null : PairedPc.fromJson(pcJson),
      cert == null ? null : base64.decode(cert),
    );
    link._save();
    return link;
  }

  final File _file;
  final DeviceIdentity identity;
  PairedPc? pc;

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
    if (offer.addresses.isEmpty) {
      throw const LinkException('Il QR code non contiene indirizzi: il PC non è collegato a una rete locale');
    }
    final ch = await PhoneLinkClient.connect(offer.addresses);
    final SecureChannel c;
    try {
      c = await Handshake.pairAsPhone(ch, offer, identity);
    } on Object {
      await ch.close();
      rethrow;
    }
    final attempt = PairingAttempt._(this, c, offer.addresses);
    _listen(c, attempt);
    return attempt;
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
      final ch = await PhoneLinkClient.connect(p.addresses);
      try {
        final c = await Handshake.helloAsPhone(ch, p.device, identity);
        _session = c;
        _listen(c, null);
        lastError = null;
      } on Object {
        await ch.close();
        rethrow;
      }
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
    _requests.close();
    super.dispose();
  }
}
