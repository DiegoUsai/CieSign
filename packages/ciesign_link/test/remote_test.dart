import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:test/test.dart';

import 'fake_signaling.dart';

/// Collegamento via internet: stanze del signaling, offerta e risposta
/// cifrate, stretta di mano del protocollo sopra un canale "WebRTC" finto.
void main() {
  late FakeSignalingServer server;
  late DeviceIdentity pc, phone;

  setUp(() async {
    server = await FakeSignalingServer.start(requireAuth: true);
    pc = await DeviceIdentity.create('UFFICIO-DIEGO');
    phone = await DeviceIdentity.create('Pixel di Diego');
  });
  tearDown(() => server.close());

  SignalingClient client() => SignalingClient(
    SignalingConfig(endpoint: server.url, firebaseApiKey: 'chiave-di-prova', authEndpoint: server.url),
  );
  Future<PeerLink> fakePeers(List<IceServer> ice) async => FakePeerLink(ice);

  test('la stanza dei dispositivi abbinati è la stessa dai due lati', () async {
    final a = await Room.forPairedDevices(pc.keyPair, phone.publicKey);
    final b = await Room.forPairedDevices(phone.keyPair, pc.publicKey);
    expect(a.id, b.id);
    expect(a.id, hasLength(43));
    final other = await Room.forPairedDevices(pc.keyPair, (await DeviceIdentity.create('x')).publicKey);
    expect(other.id, isNot(a.id));
  });

  test('i messaggi della stanza sono cifrati e legati al loro posto', () async {
    final token = List<int>.generate(16, (i) => i);
    final a = await Room.forPairing(token), b = await Room.forPairing(token);
    expect(a.id, b.id);
    final sealed = await a.seal('o', {'sdp': 'v=0 192.168.1.20'});
    expect(jsonEncode(sealed), isNot(contains('192.168')));
    expect((await b.open('o', sealed))!['sdp'], 'v=0 192.168.1.20');
    expect(await b.open('a', sealed), isNull, reason: "un'offerta non può passare per risposta");
    final c = await Room.forPairing(List<int>.filled(16, 9));
    expect(await c.open('o', sealed), isNull);
  });

  test('eventi put e patch del Realtime Database', () {
    var v = SignalingClient.applyEvent(null, 'put', '/', {'c': 'x', 'ts': 1});
    expect(v, {'c': 'x', 'ts': 1});
    v = SignalingClient.applyEvent(v, 'put', '/c', 'y');
    expect(v, {'c': 'y', 'ts': 1});
    v = SignalingClient.applyEvent(v, 'patch', '/', {'ts': 2, 'c': null});
    expect(v, {'ts': 2});
    expect(SignalingClient.applyEvent(v, 'put', '/', null), isNull);
  });

  test('frame grandi spezzati e ricomposti', () {
    final f = Fragmenter();
    final frame = Uint8List.fromList(List.generate(100 * 1024 + 7, (i) => i % 251));
    final parts = f.split(frame);
    expect(parts.length, 7);
    expect(parts.every((p) => p.length <= 16 * 1024), isTrue);
    Uint8List? out;
    for (final p in parts) {
      out = f.join(p) ?? out;
    }
    expect(out, frame);
    expect(f.join(f.split(Uint8List(0)).single), isEmpty);
  });

  test('abbinamento via internet, poi riconnessione senza QR code', () async {
    final pcSignal = client(), phoneSignal = client();
    final pcRv = Rendezvous(pcSignal, fakePeers), phoneRv = Rendezvous(phoneSignal, fakePeers);

    // Il PC mostra il QR con r=1 e ascolta nella stanza del token.
    final offer = PairingOffer(
      pcId: pc.id,
      pcName: pc.name,
      pcPublicKey: pc.publicKey,
      token: List<int>.generate(16, (i) => 200 - i),
      addresses: const [],
      remote: true,
    );
    final scanned = PairingOffer.parse(offer.toUri().toString());
    expect(scanned.remote, isTrue);
    final pcIncoming = pcRv.listen(await Room.forPairing(offer.token)).first;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final phoneCh = await phoneRv.dial(await Room.forPairing(scanned.token));
    final pcFrames = await pcIncoming;
    final pcSession = Handshake.acceptAsPc(pcFrames, pc, lookup: (_) => null, pending: offer);
    final phoneSession = await Handshake.pairAsPhone(phoneCh, scanned, phone);
    final pcS = await pcSession;
    expect(phoneSession.sas, pcS.sas);
    expect(pcS.peerName, 'Pixel di Diego');
    await phoneSession.send(const Ping());
    expect(await pcS.messages.first, isA<Ping>());
    await phoneSession.close();

    // Il servizio ha visto solo testo cifrato e ha cancellato la stanza.
    expect(server.signUps, 2, reason: 'accesso anonimo una volta per client');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(jsonEncode(server.data), isNot(contains('offer-')));

    // Riconnessione: stanza derivata dalle chiavi statiche.
    final known = PairedDevice(id: phone.id, name: phone.name, publicKey: phone.publicKey, pairedAt: DateTime.now());
    final pcRecord = PairedDevice(id: pc.id, name: pc.name, publicKey: pc.publicKey, pairedAt: DateTime.now());
    final pcIncoming2 = pcRv.listen(await Room.forPairedDevices(pc.keyPair, phone.publicKey)).first;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final phoneCh2 = await phoneRv.dial(await Room.forPairedDevices(phone.keyPair, pc.publicKey));
    final pcSession2 = Handshake.acceptAsPc(await pcIncoming2, pc, lookup: (id) => id == phone.id ? known : null);
    final phone2 = await Handshake.helloAsPhone(phoneCh2, pcRecord, phone);
    final pc2 = await pcSession2;
    expect(phone2.sas, isNull);
    expect(pc2.peerId, phone.id);
    await phone2.close();
    pcSignal.close();
    phoneSignal.close();
  });

  test('il PC ignora le offerte vecchie e quelle già viste', () async {
    final pcSignal = client(), phoneSignal = client();
    final room = await Room.forPairing(List<int>.filled(16, 1));
    // Offerta di due minuti fa rimasta nel database.
    await phoneSignal.put(
      room.path('o'),
      await room.seal('o', {
        'sid': 'vecchia',
        'sdp': 'offer-x',
        'at': DateTime.now().subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
      }),
    );
    final got = <FrameChannel>[];
    final sub = Rendezvous(pcSignal, fakePeers).listen(room).listen(got.add, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(got, isEmpty);
    expect(await pcSignal.get(room.path('a')), isNull, reason: 'nessuna risposta a offerte scadute');
    await sub.cancel();
    pcSignal.close();
    phoneSignal.close();
  });

  test('senza PC in ascolto il telefono rinuncia con un messaggio chiaro', () async {
    final phoneSignal = client();
    final room = await Room.forPairing(List<int>.filled(16, 2));
    await expectLater(
      Rendezvous(phoneSignal, fakePeers).dial(room, timeout: const Duration(milliseconds: 500)),
      throwsA(isA<LinkException>().having((e) => e.message, 'message', contains('PC non risponde'))),
    );
    phoneSignal.close();
  });

  test('server ICE pubblicati dal servizio prima di quelli predefiniti', () async {
    server.data = {
      'v1': {
        'ice': {
          'iceServers': [
            {'urls': 'turn:turn.example:3478', 'username': 'u', 'credential': 'p'},
          ],
        },
      },
    };
    final c = client();
    final ice = await c.iceServers();
    expect(ice.first.urls, ['turn:turn.example:3478']);
    expect(ice.first.toJson()['credential'], 'p');
    expect(ice.last.urls.first, startsWith('stun:'));
    c.close();
  });

  test('stessa rete: confronto delle sottoreti /24', () async {
    expect(await onSameNetwork(['192.168.1.20:47321'], localAddresses: ['192.168.1.33']), isTrue);
    expect(await onSameNetwork(['192.168.1.20:47321'], localAddresses: ['10.20.30.40']), isFalse);
    expect(await onSameNetwork(['[fe80::1]:47321'], localAddresses: ['192.168.1.33']), isFalse);
    expect(await onSameNetwork(const [], localAddresses: ['192.168.1.33']), isFalse);
  });

  test('il QR code tiene solo indirizzi della rete locale', () {
    expect(isLocalAddress('192.168.1.20:47321'), isTrue);
    expect(isLocalAddress('10.0.0.5:47321'), isTrue);
    expect(isLocalAddress('172.20.1.1:47321'), isTrue);
    expect(isLocalAddress('[fe80::1]:47321'), isTrue);
    expect(isLocalAddress('[fd12::5]:47321'), isTrue);
    expect(isLocalAddress('172.32.1.1:47321'), isFalse);
    expect(isLocalAddress('8.8.8.8:47321'), isFalse);
    expect(isLocalAddress('[2001:db8::1]:47321'), isFalse);
    expect(isLocalAddress('attaccante.example:47321'), isFalse);
    final o = PairingOffer.parse(
      'ciesign://pair?v=1&id=x&n=PC&k=${'A' * 43}&t=${'B' * 21}A&a=203.0.113.9:47321,192.168.1.20:47321',
    );
    expect(o.addresses, ['192.168.1.20:47321']);
  });
}
