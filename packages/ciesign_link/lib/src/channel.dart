import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keys.dart';
import 'messages.dart';
import 'pairing_offer.dart';

/// Trasporto a messaggi (frame) indipendente dal mezzo: TCP sulla Wi-Fi di
/// casa oggi, **BLE** domani, con la stessa cifratura sopra.
abstract class FrameChannel {
  Stream<Uint8List> get frames;
  void send(Uint8List frame);
  Future<void> close();
}

/// Errore di protocollo o di autenticazione: il collegamento va chiuso.
class LinkException implements Exception {
  const LinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Canale cifrato e autenticato con **ChaCha20-Poly1305**, una chiave per
/// direzione e un contatore come nonce, che impedisce di riordinare o
/// ripetere i messaggi.
class SecureChannel {
  SecureChannel._(
    this._raw,
    this._sendKey,
    this._recvKey,
    this.peerId,
    this.peerName,
    this.peerPublicKey,
    this.sas,
    Stream<Uint8List> incoming,
  ) {
    _sub = incoming.listen(
      _onFrame,
      onError: _messages.addError,
      onDone: () {
        _messages.close();
      },
    );
  }

  static final _aead = Chacha20.poly1305Aead();

  final FrameChannel _raw;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final String peerId;
  final String peerName;
  final Uint8List peerPublicKey;

  /// Codice di sei cifre da confrontare a voce o a occhio; presente solo
  /// durante l'abbinamento.
  final String? sas;

  int _sendCounter = 0;
  int _recvCounter = 0;
  final _messages = StreamController<LinkMessage>();
  late final StreamSubscription<Uint8List> _sub;
  Future<void> _decryptChain = Future.value();
  Future<void> _sendChain = Future.value();

  Stream<LinkMessage> get messages => _messages.stream;

  static List<int> _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  Future<void> send(LinkMessage m) {
    final counter = _sendCounter++;
    return _sendChain = _sendChain.then((_) async {
      final box = await _aead.encrypt(m.encode(), secretKey: _sendKey, nonce: _nonce(counter));
      _raw.send(Uint8List.fromList([...box.cipherText, ...box.mac.bytes]));
    });
  }

  void _onFrame(Uint8List f) {
    final counter = _recvCounter++;
    _decryptChain = _decryptChain
        .then((_) async {
          if (f.length < 16) throw const LinkException('Messaggio cifrato troppo corto');
          final box = SecretBox(
            f.sublist(0, f.length - 16),
            nonce: _nonce(counter),
            mac: Mac(f.sublist(f.length - 16)),
          );
          final clear = await _aead.decrypt(box, secretKey: _recvKey);
          _messages.add(LinkMessage.decode(clear));
        })
        .catchError((Object e) {
          _messages.addError(LinkException('Messaggio non autentico o fuori sequenza: $e'));
          close();
        });
  }

  Future<void> close() async {
    await _sub.cancel();
    await _raw.close();
    // Senza ascoltatori il Future di close() non si completerebbe mai.
    if (!_messages.isClosed) unawaited(_messages.close());
  }
}

/// Stretta di mano (handshake) ispirata al modello **Noise KK**: entrambe le
/// parti conoscono la chiave statica dell'altra e usano chiavi effimere, per
/// cui una chiave rubata in futuro non decifra le sessioni passate.
///
/// Primo messaggio, in chiaro, dallo smartphone al PC:
/// - abbinamento: `{t: pair, v, id, name, k: statica, e: effimera, proof}`, dove
///   `proof` dimostra di conoscere il segreto `t` del QR code;
/// - riconnessione: `{t: hello, v, id, e: effimera}`.
///
/// Risposta del PC: `{t: pair_ok | hello_ok, v, id, name, e: effimera}`.
/// Da quel momento tutto viaggia cifrato.
class Handshake {
  static const version = 1;

  /// Lato smartphone, primo abbinamento con un QR code.
  static Future<SecureChannel> pairAsPhone(FrameChannel ch, PairingOffer offer, DeviceIdentity me) async {
    final eph = await newEphemeral();
    final ePub = await publicOf(eph);
    final proof = await _proof(
      ss: await dh(me.keyPair, offer.pcPublicKey),
      se: await dh(eph, offer.pcPublicKey),
      token: offer.token,
      phoneStatic: me.publicKey,
      phoneEph: ePub,
    );
    final m1 = _json({
      't': 'pair',
      'v': version,
      'id': me.id,
      'name': me.name,
      'k': b64u(me.publicKey),
      'e': b64u(ePub),
      'proof': b64u(proof),
    });
    return _phoneSide(ch, m1, me, eph, offer.pcPublicKey, expectType: 'pair_ok', token: offer.token);
  }

  /// Lato smartphone, riconnessione a un PC già abbinato.
  static Future<SecureChannel> helloAsPhone(FrameChannel ch, PairedDevice pc, DeviceIdentity me) async {
    final eph = await newEphemeral();
    final m1 = _json({'t': 'hello', 'v': version, 'id': me.id, 'e': b64u(await publicOf(eph))});
    final c = await _phoneSide(ch, m1, me, eph, pc.publicKey, expectType: 'hello_ok');
    if (c.peerId != pc.id) {
      await c.close();
      throw const LinkException('Il PC ha risposto con un identificativo diverso');
    }
    return c;
  }

  static Future<SecureChannel> _phoneSide(
    FrameChannel ch,
    Uint8List m1,
    DeviceIdentity me,
    SimpleKeyPair eph,
    List<int> pcStatic, {
    required String expectType,
    List<int>? token,
  }) async {
    final frames = _Splitter(ch.frames);
    ch.send(m1);
    final m2 = await frames.first('Il PC ha chiuso il collegamento');
    final j = jsonDecode(utf8.decode(m2)) as Map<String, Object?>;
    if (j['t'] == 'error') throw LinkException('Il PC ha rifiutato il collegamento: ${j['msg']}');
    if (j['t'] != expectType || j['v'] != version) throw const LinkException('Risposta inattesa dal PC');
    final pcEph = unb64u(j['e'] as String);
    final keys = await _sessionKeys(
      ee: await dh(eph, pcEph),
      ss: await dh(me.keyPair, pcStatic),
      se: await dh(eph, pcStatic),
      es: await dh(me.keyPair, pcEph),
      m1: m1,
      m2: m2,
      token: token,
    );
    return SecureChannel._(
      ch,
      keys.phoneToPc,
      keys.pcToPhone,
      j['id'] as String,
      j['name'] as String? ?? 'PC',
      Uint8List.fromList(pcStatic),
      keys.sas,
      frames.rest,
    );
  }

  /// Lato PC. [pending] è l'offerta mostrata nel QR code, se ce n'è una
  /// attiva; [lookup] trova i telefoni già abbinati.
  static Future<SecureChannel> acceptAsPc(
    FrameChannel ch,
    DeviceIdentity me, {
    required PairedDevice? Function(String phoneId) lookup,
    PairingOffer? pending,
  }) async {
    final frames = _Splitter(ch.frames);
    final m1 = await frames.first('Lo smartphone ha chiuso il collegamento');
    final Map<String, Object?> j;
    try {
      j = jsonDecode(utf8.decode(m1)) as Map<String, Object?>;
    } on FormatException {
      throw const LinkException('Primo messaggio non valido');
    }
    if (j['v'] != version) {
      ch.send(_json({'t': 'error', 'msg': 'versione non supportata'}));
      throw const LinkException('Versione del protocollo non supportata');
    }
    final phoneEph = unb64u(j['e'] as String);
    final Uint8List phoneStatic;
    final String phoneName;
    List<int>? token;
    String replyType;
    if (j['t'] == 'pair') {
      if (pending == null) {
        ch.send(_json({'t': 'error', 'msg': 'nessun abbinamento in corso'}));
        throw const LinkException('Richiesta di abbinamento senza QR code attivo');
      }
      phoneStatic = unb64u(j['k'] as String);
      phoneName = j['name'] as String? ?? 'Smartphone';
      final expected = await _proof(
        ss: await dh(me.keyPair, phoneStatic),
        se: await dh(me.keyPair, phoneEph),
        token: pending.token,
        phoneStatic: phoneStatic,
        phoneEph: phoneEph,
      );
      if (!constantTimeEquals(expected, unb64u(j['proof'] as String))) {
        ch.send(_json({'t': 'error', 'msg': 'QR code non valido'}));
        throw const LinkException('Prova di possesso del QR code errata');
      }
      token = pending.token;
      replyType = 'pair_ok';
    } else if (j['t'] == 'hello') {
      final known = lookup(j['id'] as String);
      if (known == null) {
        ch.send(_json({'t': 'error', 'msg': 'smartphone non abbinato'}));
        throw const LinkException('Smartphone non abbinato');
      }
      phoneStatic = known.publicKey;
      phoneName = known.name;
      replyType = 'hello_ok';
    } else {
      throw const LinkException('Primo messaggio inatteso');
    }
    final eph = await newEphemeral();
    final m2 = _json({'t': replyType, 'v': version, 'id': me.id, 'name': me.name, 'e': b64u(await publicOf(eph))});
    final keys = await _sessionKeys(
      ee: await dh(eph, phoneEph),
      ss: await dh(me.keyPair, phoneStatic),
      se: await dh(me.keyPair, phoneEph),
      es: await dh(eph, phoneStatic),
      m1: m1,
      m2: m2,
      token: token,
    );
    ch.send(m2);
    return SecureChannel._(
      ch,
      keys.pcToPhone,
      keys.phoneToPc,
      j['id'] as String,
      phoneName,
      phoneStatic,
      keys.sas,
      frames.rest,
    );
  }

  static Future<Uint8List> _proof({
    required List<int> ss,
    required List<int> se,
    required List<int> token,
    required List<int> phoneStatic,
    required List<int> phoneEph,
  }) async {
    final k = await hkdf([...ss, ...se], salt: token, info: 'ciesign pair proof v1');
    return hmacSha256(k, [...phoneStatic, ...phoneEph]);
  }

  static Future<({SecretKey phoneToPc, SecretKey pcToPhone, String? sas})> _sessionKeys({
    required List<int> ee,
    required List<int> ss,
    required List<int> se,
    required List<int> es,
    required List<int> m1,
    required List<int> m2,
    List<int>? token,
  }) async {
    final h = await sha256Of([...m1, ...m2]);
    final hHex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final okm = await hkdf(
      [...ee, ...ss, ...se, ...es],
      salt: utf8.encode('ciesign session v1'),
      info: hHex,
      length: 64,
    );
    String? sas;
    if (token != null) {
      final s = await hkdf([...ss, ...ee], salt: token, info: 'ciesign sas v1 $hHex', length: 4);
      final v = ByteData.sublistView(s).getUint32(0) % 1000000;
      sas = v.toString().padLeft(6, '0');
    }
    return (phoneToPc: SecretKey(okm.sublist(0, 32)), pcToPhone: SecretKey(okm.sublist(32)), sas: sas);
  }

  static Uint8List _json(Map<String, Object?> m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));
}

/// Separa il primo frame (in chiaro, della stretta di mano) dai successivi,
/// senza perdere quelli che arrivano subito dopo.
class _Splitter {
  _Splitter(Stream<Uint8List> source) {
    _sub = source.listen(
      (f) {
        if (!_first.isCompleted) {
          _first.complete(f);
        } else {
          _rest.add(f);
        }
      },
      onError: (Object e) {
        if (!_first.isCompleted) {
          _first.completeError(e);
        } else {
          _rest.addError(e);
        }
      },
      onDone: () {
        if (!_first.isCompleted) _first.completeError(const LinkException('Collegamento chiuso'));
        _rest.close();
      },
    );
    _rest.onCancel = () => _sub.cancel();
  }

  late final StreamSubscription<Uint8List> _sub;
  final _first = Completer<Uint8List>();
  final _rest = StreamController<Uint8List>();

  Future<Uint8List> first(String closedMessage) => _first.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => throw LinkException('$closedMessage (tempo scaduto)'),
  );

  Stream<Uint8List> get rest => _rest.stream;
}
