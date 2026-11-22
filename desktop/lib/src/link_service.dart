import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:ciesign_webrtc/ciesign_webrtc.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'key_store.dart';

export 'key_store.dart';

/// Stato del collegamento con lo smartphone: identità del PC, telefoni
/// abbinati, server sulla rete locale, annuncio mDNS e sessione attiva.
///
/// Il seme della chiave privata del PC sta nel portachiavi di sistema
/// (Windows Credential Manager, Portachiavi di macOS, libsecret su Linux);
/// nel file JSON della cartella dati restano solo identificativo, nome e
/// chiavi pubbliche dei telefoni abbinati, che non sono segreti.
///
/// Oltre alla rete locale, se la build ha un servizio di signaling
/// ([SignalingConfig.fromEnvironment]) e l'utente sceglie "Il telefono non è
/// sulla stessa rete", il PC ascolta anche via internet: una stanza per ogni
/// telefono abbinato e una per il QR code mostrato. Le
/// sessioni che arrivano da WebRTC seguono la stessa strada di quelle TCP.
class LinkService extends ChangeNotifier {
  LinkService._(this._file, this.identity, this._paired, this.keyInSystemStore, this._rendezvous, this._internet);

  static const _seedKey = 'ciesign.pc.seed';

  static Future<LinkService> open({
    KeyStore? keyStore,
    SignalingConfig? signaling,
    PeerLinkFactory peers = createWebRtcPeer,
  }) async {
    // Su Linux libsecret termina il processo se manca un servizio portachiavi
    // attivo: finché Linux non è una piattaforma supportata, il seme resta nel file.
    final store = keyStore ?? (Platform.isLinux ? MemoryKeyStore(broken: true) : SystemKeyStore());
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}collegamento.json');
    Map<String, Object?> j = {};
    if (file.existsSync()) j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final paired = <String, PairedDevice>{
      for (final p in ((j['paired'] as List?) ?? const []).cast<Map<String, Object?>>())
        PairedDevice.fromJson(p).id: PairedDevice.fromJson(p),
    };
    final idJson = j['identity'] as Map<String, Object?>?;
    final loaded = await loadIdentity(idJson, store, fallbackName: Platform.localHostname);
    final config = signaling ?? SignalingConfig.fromEnvironment();
    final rv = config == null ? null : Rendezvous(SignalingClient(config), peers);
    final s = LinkService._(file, loaded.identity, paired, loaded.inSystemStore, rv, j['internet'] == true);
    s._save();
    await s._startServer();
    await s._announce();
    for (final p in paired.values) {
      await s._listenRemote(p);
    }
    return s;
  }

  /// Recupera o crea l'identità del PC. Se trova il seme nel vecchio file
  /// JSON lo sposta nel portachiavi; se il portachiavi non è disponibile, il
  /// seme resta nel file e [inSystemStore] vale false.
  @visibleForTesting
  static Future<({DeviceIdentity identity, bool inSystemStore})> loadIdentity(
    Map<String, Object?>? json,
    KeyStore store, {
    required String fallbackName,
  }) async {
    String? stored;
    var storeWorks = true;
    try {
      stored = await store.read(_seedKey);
    } on Object {
      storeWorks = false;
    }
    final legacySeed = json?['seed'] as String?;
    DeviceIdentity identity;
    if (json != null && (stored != null || legacySeed != null)) {
      identity = await DeviceIdentity.fromJson({...json, 'seed': stored ?? legacySeed});
    } else {
      identity = await DeviceIdentity.create(json?['name'] as String? ?? fallbackName);
    }
    if (storeWorks && stored == null) {
      try {
        await store.write(_seedKey, identity.toJson()['seed'] as String);
      } on Object {
        storeWorks = false;
      }
    }
    return (identity: identity, inSystemStore: storeWorks);
  }

  /// Vero se il seme della chiave è protetto dal portachiavi di sistema.
  final bool keyInSystemStore;
  BonsoirBroadcast? _broadcast;

  /// Annuncia il PC sulla rete locale come servizio _ciesign._tcp, con
  /// l'identificativo del PC nei record TXT, così il telefono già abbinato lo
  /// trova anche se il suo indirizzo IP è cambiato. Se mDNS non è disponibile
  /// restano gli indirizzi contenuti nel QR code.
  Future<void> _announce() async {
    final port = _server?.port;
    if (port == null) return;
    try {
      final b = BonsoirBroadcast(
        service: BonsoirService(
          name: 'Firmami su ${identity.name}',
          type: PcLinkServer.mdnsService,
          port: port,
          attributes: {'id': identity.id, 'v': '1'},
        ),
      );
      await b.initialize();
      await b.start();
      _broadcast = b;
    } on Object catch (e) {
      lastError = 'Annuncio mDNS non disponibile: $e';
    }
  }

  final Rendezvous? _rendezvous;
  final _remote = <String, StreamSubscription<FrameChannel>>{};
  static const _pairingRoom = '#pairing';

  /// Vero se questa build sa collegarsi via internet.
  bool get remoteAvailable => _rendezvous != null;

  bool _internet;

  /// Scelta dell'utente "Il telefono non è sulla stessa rete", spenta in
  /// partenza: senza, il PC non contatta nessun servizio esterno.
  bool get internetEnabled => _internet;

  /// Vero se il PC ascolta anche via internet.
  bool get remoteEnabled => remoteAvailable && _internet;

  /// Accende o spegne l'ascolto via internet. Se è in corso un abbinamento,
  /// il QR code si rigenera con o senza l'indicazione r=1.
  Future<void> setInternetEnabled(bool on) async {
    if (on == _internet) return;
    _internet = on;
    _save();
    if (on) {
      for (final p in _paired.values) {
        await _listenRemote(p);
      }
    } else {
      for (final sub in _remote.values) {
        await sub.cancel();
      }
      _remote.clear();
      remoteError = null;
    }
    if (pairingOffer != null && pairingSession == null) {
      await startPairing();
    } else {
      notifyListeners();
    }
  }

  /// Ultimo problema del collegamento via internet, da mostrare con
  /// discrezione: la rete locale continua a funzionare.
  String? remoteError;

  void _watchRoom(String key, Room room) {
    final rv = _rendezvous;
    if (rv == null || !_internet) return;
    _remote.remove(key)?.cancel();
    _remote[key] = rv
        .listen(room)
        .listen(
          (ch) {
            remoteError = null;
            _server?.accept(ch);
          },
          onError: (Object e) {
            remoteError = '$e';
            notifyListeners();
          },
        );
  }

  Future<void> _listenRemote(PairedDevice p) async {
    if (!remoteEnabled) return;
    _watchRoom(p.id, await Room.forPairedDevices(identity.keyPair, p.publicKey));
  }

  void _stopPairingRoom() => _remote.remove(_pairingRoom)?.cancel();

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
    pairingOffer = await _server!.newPairingOffer(remote: remoteEnabled);
    if (remoteEnabled) _watchRoom(_pairingRoom, await Room.forPairing(pairingOffer!.token));
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
    _stopPairingRoom();
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
      unawaited(_listenRemote(_paired[c.peerId]!));
      pairingOffer = null;
      _server?.pendingOffer = null;
      _stopPairingRoom();
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
    _remote.remove(id)?.cancel();
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
    final id = identity.toJson();
    // Il seme va nel file solo se il portachiavi di sistema non funziona.
    if (keyInSystemStore) id.remove('seed');
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({
        'identity': id,
        'paired': _paired.values.map((p) => p.toJson()).toList(),
        if (_internet) 'internet': true,
      }),
    );
  }

  @override
  void dispose() {
    _broadcast?.stop();
    for (final s in _remote.values) {
      s.cancel();
    }
    _rendezvous?.signaling.close();
    _server?.close();
    _active?.close();
    super.dispose();
  }
}
