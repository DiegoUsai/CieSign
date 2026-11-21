import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Stato del collegamento con lo smartphone: identità del PC, telefoni
/// abbinati, server sulla rete locale e sessione attiva.
///
/// Nella PoC identità e abbinamenti stanno in un file JSON nella cartella
/// dati dell'app; prima della beta il seme della chiave andrà nel portachiavi
/// di sistema (Windows Credential Manager, Portachiavi di macOS).
class LinkService extends ChangeNotifier {
  LinkService._(this._file, this.identity, this._paired);

  static Future<LinkService> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}collegamento.json');
    DeviceIdentity identity;
    final paired = <String, PairedDevice>{};
    if (file.existsSync()) {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      identity = await DeviceIdentity.fromJson(j['identity'] as Map<String, Object?>);
      for (final p in (j['paired'] as List).cast<Map<String, Object?>>()) {
        final d = PairedDevice.fromJson(p);
        paired[d.id] = d;
      }
    } else {
      identity = await DeviceIdentity.create(Platform.localHostname);
    }
    final s = LinkService._(file, identity, paired);
    s._save();
    await s._startServer();
    return s;
  }

  final File _file;
  final DeviceIdentity identity;
  final Map<String, PairedDevice> _paired;
  PcLinkServer? _server;
  SecureChannel? _active;
  final _incoming = StreamController<(SecureChannel, LinkMessage)>.broadcast();
  String? lastError;

  List<PairedDevice> get pairedDevices => _paired.values.toList();
  SecureChannel? get activeSession => _active;
  int? get port => _server?.port;

  /// Abbinamento in corso: QR code mostrato e, appena lo smartphone si
  /// collega, il codice di sei cifre da confrontare.
  PairingOffer? pairingOffer;
  SecureChannel? pairingSession;

  Future<void> _startServer() async {
    final server = await PcLinkServer.start(identity, lookup: (id) => _paired[id]);
    _server = server;
    server.errors.listen((e) {
      lastError = '$e';
      notifyListeners();
    });
    server.sessions.listen(_onSession);
  }

  void _onSession(SecureChannel c) {
    if (c.sas != null) {
      pairingSession = c;
    } else {
      _active?.close();
      _active = c;
    }
    c.messages.listen(
      (m) => _onMessage(c, m),
      onError: (Object e) {
        lastError = '$e';
        _drop(c);
      },
      onDone: () => _drop(c),
    );
    notifyListeners();
  }

  void _onMessage(SecureChannel c, LinkMessage m) {
    if (m is Ping) {
      c.send(const Pong());
      return;
    }
    if (m is PairConfirm && c == pairingSession) {
      _phoneConfirmed = m.ok;
      _maybeCompletePairing();
      return;
    }
    _incoming.add((c, m));
  }

  void _drop(SecureChannel c) {
    if (_active == c) _active = null;
    if (pairingSession == c) pairingSession = null;
    notifyListeners();
  }

  bool? _phoneConfirmed;
  bool? _pcConfirmed;
  final _pairingDone = StreamController<bool>.broadcast();

  /// Emette true quando l'abbinamento è salvato, false se è annullato.
  Stream<bool> get pairingResults => _pairingDone.stream;

  Future<PairingOffer> startPairing() async {
    _phoneConfirmed = null;
    _pcConfirmed = null;
    pairingSession = null;
    pairingOffer = await _server!.newPairingOffer();
    notifyListeners();
    return pairingOffer!;
  }

  /// L'utente conferma (o nega) sul PC che il codice coincide.
  Future<void> confirmPairing(bool ok) async {
    _pcConfirmed = ok;
    await pairingSession?.send(PairConfirm(ok));
    _maybeCompletePairing();
  }

  void cancelPairing() {
    pairingSession?.close();
    pairingSession = null;
    pairingOffer = null;
    _server?.pendingOffer = null;
    notifyListeners();
  }

  void _maybeCompletePairing() {
    final c = pairingSession;
    if (c == null) return;
    if (_pcConfirmed == false || _phoneConfirmed == false) {
      _pairingDone.add(false);
      cancelPairing();
      return;
    }
    if (_pcConfirmed == true && _phoneConfirmed == true) {
      _paired[c.peerId] = PairedDevice(
        id: c.peerId,
        name: c.peerName,
        publicKey: c.peerPublicKey,
        pairedAt: DateTime.now(),
      );
      _save();
      pairingOffer = null;
      _server?.pendingOffer = null;
      // La sessione dell'abbinamento diventa quella attiva.
      pairingSession = null;
      _active?.close();
      _active = c;
      _pairingDone.add(true);
      notifyListeners();
    }
  }

  void unpair(String id) {
    _paired.remove(id);
    if (_active?.peerId == id) {
      _active?.close();
      _active = null;
    }
    _save();
    notifyListeners();
  }

  /// Invia [m] e attende la prima risposta che soddisfa [match].
  Future<LinkMessage> request(
    SecureChannel c,
    LinkMessage m,
    bool Function(LinkMessage) match, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final reply = _incoming.stream.where((e) => e.$1 == c && match(e.$2)).map((e) => e.$2).first;
    await c.send(m);
    return reply.timeout(timeout, onTimeout: () => throw TimeoutException('Lo smartphone non ha risposto in tempo'));
  }

  /// Messaggi non gestiti qui, per esempio le richieste del documento (UC10).
  Stream<(SecureChannel, LinkMessage)> get incoming => _incoming.stream;

  void _save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({'identity': identity.toJson(), 'paired': _paired.values.map((p) => p.toJson()).toList()}),
    );
  }

  @override
  void dispose() {
    _server?.close();
    _active?.close();
    super.dispose();
  }
}
