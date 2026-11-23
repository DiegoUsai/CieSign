@Tags(['servizio'])
library;

import 'dart:io';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:test/test.dart';

import 'fake_signaling.dart';

/// Stesso giro di remote_test.dart contro un servizio di signaling vero:
/// gli emulatori di Firebase con le regole di tools/signaling-firebase,
/// oppure il Worker di tools/signaling-worker avviato con `wrangler dev`.
///
/// Firebase (dalla cartella tools/signaling-firebase):
///   firebase emulators:exec --only auth,database --project demo-ciesign \
///     "cd ../../packages/ciesign_link && dart test -t servizio"
///
/// Cloudflare (con `npx wrangler dev --port 8787` avviato):
///   CIESIGN_TEST_SIGNALING_URL=http://127.0.0.1:8787 dart test -t servizio
void main() {
  final env = Platform.environment;
  final dbHost = env['FIREBASE_DATABASE_EMULATOR_HOST'];
  final authHost = env['FIREBASE_AUTH_EMULATOR_HOST'];
  final url =
      env['CIESIGN_TEST_SIGNALING_URL'] ?? (dbHost == null ? null : 'http://$dbHost/?ns=demo-ciesign-default-rtdb');
  final firebase = dbHost != null && env['CIESIGN_TEST_SIGNALING_URL'] == null;
  final skip = url == null ? 'nessun servizio di signaling avviato' : false;

  SignalingClient client({bool withAuth = true}) => SignalingClient(
    SignalingConfig(
      endpoint: Uri.parse(url!),
      firebaseApiKey: firebase && withAuth ? 'demo-key' : null,
      authEndpoint: authHost == null ? null : Uri.parse('http://$authHost/'),
    ),
  );
  Future<PeerLink> fakePeers(List<IceServer> ice) async => FakePeerLink(ice);

  test('abbinamento attraverso il servizio', () async {
    final pc = await DeviceIdentity.create('PC'), phone = await DeviceIdentity.create('Telefono');
    final offer = PairingOffer(
      pcId: pc.id,
      pcName: pc.name,
      pcPublicKey: pc.publicKey,
      token: List<int>.generate(16, (i) => i * 3 + DateTime.now().millisecond % 7),
      addresses: const [],
      remote: true,
    );
    final pcSignal = client(), phoneSignal = client();
    final pcIn = Rendezvous(pcSignal, fakePeers).listen(await Room.forPairing(offer.token)).first;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final phoneCh = await Rendezvous(phoneSignal, fakePeers).dial(await Room.forPairing(offer.token));
    final pcSession = Handshake.acceptAsPc(await pcIn, pc, lookup: (_) => null, pending: offer);
    final s = await Handshake.pairAsPhone(phoneCh, offer, phone);
    expect(s.sas, (await pcSession).sas);
    await s.close();
    pcSignal.close();
    phoneSignal.close();
  }, skip: skip);

  test('il servizio respinge dati non cifrati, stanze non valide e gli elenchi', () async {
    final ok = client();
    final room = await Room.forPairing(List<int>.filled(16, 7));
    if (firebase) {
      final anon = client(withAuth: false);
      await expectLater(anon.put(room.path('o'), await room.seal('o', {'x': 1})), throwsA(isA<LinkException>()));
      anon.close();
    }
    await expectLater(ok.put(room.path('o'), {'sdp': 'in chiaro'}), throwsA(isA<LinkException>()));
    await expectLater(ok.put('v1/r/stanza-corta/o', await room.seal('o', {'x': 1})), throwsA(isA<LinkException>()));
    await expectLater(ok.get('v1/r'), throwsA(isA<LinkException>()), reason: 'non si possono elencare le stanze');
    await ok.put(room.path('o'), await room.seal('o', {'x': 1}));
    expect((await room.open('o', await ok.get(room.path('o'))))!['x'], 1);
    await ok.delete('v1/r/${room.id}');
    expect(await ok.get(room.path('o')), isNull);
    ok.close();
  }, skip: skip);
}
