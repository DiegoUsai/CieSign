import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../channel.dart';
import '../keys.dart';
import 'signaling.dart';

/// Collegamento diretto tra due dispositivi (un **RTCPeerConnection** con un
/// **data channel**), visto dal protocollo come un semplice [FrameChannel].
///
/// Il pacchetto resta in Dart puro: l'implementazione con `flutter_webrtc`
/// sta in `packages/ciesign_webrtc`, quella finta dei test in memoria.
abstract class PeerLink {
  /// Lato telefono: descrizione locale (**SDP**) con tutti i candidati ICE già
  /// raccolti, così basta un solo messaggio per parte.
  Future<String> createOffer();

  /// Lato PC: riceve l'offerta e restituisce la risposta, anch'essa completa.
  Future<String> acceptOffer(String offerSdp);

  /// Lato telefono: applica la risposta del PC.
  Future<void> acceptAnswer(String answerSdp);

  /// Si completa quando il data channel è aperto.
  Future<FrameChannel> get channel;

  Future<void> close();
}

typedef PeerLinkFactory = Future<PeerLink> Function(List<IceServer> iceServers);

/// Stanza (room) del servizio di signaling dove telefono e PC si scambiano
/// offerta e risposta. Identificativo e chiave derivano da un segreto che il
/// servizio non conosce:
/// - nell'abbinamento, il segreto `t` del QR code;
/// - nelle riconnessioni, il segreto **X25519** tra le chiavi statiche dei
///   due dispositivi, che solo loro possono calcolare.
///
/// Il servizio vede quindi solo nomi casuali e testo cifrato con
/// **ChaCha20-Poly1305**: né i nomi dei dispositivi, né gli indirizzi IP
/// contenuti negli SDP.
class Room {
  Room._(this.id, this._key);

  final String id;
  final SecretKey _key;

  static final _aead = Chacha20.poly1305Aead();

  static Future<Room> forPairing(List<int> qrToken) async {
    final id = await hkdf(qrToken, salt: utf8.encode('ciesign room v1'), info: 'pair id');
    final k = await hkdf(qrToken, salt: utf8.encode('ciesign room v1'), info: 'pair key');
    return Room._(b64u(id), SecretKey(k));
  }

  static Future<Room> forPairedDevices(SimpleKeyPair mine, List<int> theirPublic) async {
    final ss = await dh(mine, theirPublic);
    final id = await hkdf(ss, salt: utf8.encode('ciesign room v1'), info: 'hello id');
    final k = await hkdf(ss, salt: utf8.encode('ciesign room v1'), info: 'hello key');
    return Room._(b64u(id), SecretKey(k));
  }

  String path(String slot) => 'v1/r/$id/$slot';

  Future<Map<String, Object?>> seal(String slot, Map<String, Object?> clear) async {
    final box = await _aead.encrypt(
      utf8.encode(jsonEncode(clear)),
      secretKey: _key,
      nonce: _aead.newNonce(),
      aad: utf8.encode('$id/$slot'),
    );
    return {
      'c': b64u(box.concatenation()),
      'ts': {'.sv': 'timestamp'},
    };
  }

  Future<Map<String, Object?>?> open(String slot, Object? sealed) async {
    if (sealed is! Map || sealed['c'] is! String) return null;
    try {
      final raw = unb64u(sealed['c'] as String);
      final box = SecretBox.fromConcatenation(raw, nonceLength: 12, macLength: 16);
      final clear = await _aead.decrypt(box, secretKey: _key, aad: utf8.encode('$id/$slot'));
      return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
    } on Object {
      return null; // valore non nostro o alterato: si ignora
    }
  }
}

/// Messaggi nella stanza: `o` (offerta del telefono) e `a` (risposta del PC).
/// Ogni tentativo ha un identificativo `sid`, così il PC non risponde due
/// volte alla stessa offerta e il telefono scarta le risposte vecchie.
class Rendezvous {
  Rendezvous(this.signaling, this.peers);

  final SignalingClient signaling;
  final PeerLinkFactory peers;

  /// Un'offerta più vecchia di così si considera abbandonata.
  static const offerLifetime = Duration(seconds: 60);

  /// Lato telefono: pubblica l'offerta e attende la risposta del PC.
  Future<FrameChannel> dial(Room room, {Duration timeout = const Duration(seconds: 25)}) async {
    final ice = await signaling.iceServers();
    final peer = await peers(ice);
    final sid = b64u(randomBytes(9));
    StreamSubscription<Object?>? sub;
    try {
      final sdp = await peer.createOffer();
      final answer = Completer<String>();
      sub = signaling
          .watch(room.path('a'))
          .listen(
            (v) async {
              final m = await room.open('a', v);
              if (m != null && m['sid'] == sid && !answer.isCompleted) answer.complete(m['sdp'] as String);
            },
            onError: (Object e) {
              if (!answer.isCompleted) answer.completeError(e);
            },
          );
      await signaling.put(
        room.path('o'),
        await room.seal('o', {'sid': sid, 'sdp': sdp, 'at': DateTime.now().millisecondsSinceEpoch}),
      );
      final deadline = DateTime.now().add(timeout);
      final a = await answer.future.timeout(
        timeout,
        onTimeout: () => throw const LinkException('Il PC non risponde via internet: è acceso con CIE Sign aperta?'),
      );
      await peer.acceptAnswer(a);
      final ch = await peer.channel.timeout(
        deadline.difference(DateTime.now()) + const Duration(seconds: 10),
        onTimeout: () => throw const LinkException(
          'Collegamento diretto non riuscito: le due reti non lo permettono senza un server TURN',
        ),
      );
      unawaited(_cleanup(room));
      return ch;
    } on Object {
      await peer.close();
      unawaited(_cleanup(room));
      rethrow;
    } finally {
      await sub?.cancel();
    }
  }

  Future<void> _cleanup(Room room) async {
    try {
      await signaling.delete('v1/r/${room.id}');
    } on Object {
      // la stanza verrà sovrascritta dal prossimo tentativo
    }
  }

  /// Lato PC: resta in ascolto nella stanza e per ogni nuova offerta
  /// restituisce il canale appena il data channel si apre. La stretta di mano
  /// del protocollo ([Handshake.acceptAsPc]) avviene poi sopra il canale.
  Stream<FrameChannel> listen(Room room) {
    final seen = <String>{};
    late StreamController<FrameChannel> out;
    StreamSubscription<Object?>? sub;
    out = StreamController<FrameChannel>(
      onListen: () {
        sub = signaling
            .watch(room.path('o'))
            .listen(
              (v) async {
                final m = await room.open('o', v);
                if (m == null) return;
                final sid = m['sid'] as String?;
                final at = DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0);
                if (sid == null || !seen.add(sid)) return;
                if (DateTime.now().difference(at).abs() > offerLifetime) return;
                PeerLink? peer;
                try {
                  peer = await peers(await signaling.iceServers());
                  final answer = await peer.acceptOffer(m['sdp'] as String);
                  await signaling.put(room.path('a'), await room.seal('a', {'sid': sid, 'sdp': answer}));
                  final ch = await peer.channel.timeout(const Duration(seconds: 40));
                  if (!out.isClosed) out.add(ch);
                } on Object catch (e) {
                  await peer?.close();
                  if (!out.isClosed) out.addError(e);
                }
              },
              onError: (Object e) {
                if (!out.isClosed) out.addError(e);
              },
            );
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }
}

/// Spezza i frame del protocollo in messaggi del data channel di al massimo
/// [maxMessage] byte e li ricompone: il primo byte vale 1 sull'ultimo pezzo.
/// Serve perché non tutte le implementazioni di WebRTC accettano messaggi
/// grandi come un pezzo di documento (48 KB) più la cifratura.
class Fragmenter {
  Fragmenter({this.maxMessage = 16 * 1024});

  final int maxMessage;
  final _pending = BytesBuilder(copy: false);

  List<Uint8List> split(Uint8List frame) {
    final out = <Uint8List>[];
    final step = maxMessage - 1;
    var off = 0;
    do {
      final end = off + step < frame.length ? off + step : frame.length;
      final m = Uint8List(1 + end - off);
      m[0] = end == frame.length ? 1 : 0;
      m.setRange(1, m.length, frame, off);
      out.add(m);
      off = end;
    } while (off < frame.length);
    return out;
  }

  /// Restituisce il frame completo quando arriva l'ultimo pezzo.
  Uint8List? join(Uint8List message) {
    if (message.isEmpty) throw const LinkException('Messaggio WebRTC vuoto');
    _pending.add(Uint8List.sublistView(message, 1));
    if (_pending.length > (1 << 20) + maxMessage) throw const LinkException('Frame troppo grande');
    return message[0] == 1 ? _pending.takeBytes() : null;
  }
}
