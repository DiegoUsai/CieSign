
import 'package:ciesign_link/ciesign_link.dart';
import 'package:ciesign_webrtc/ciesign_webrtc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Due peer WebRTC veri nello stesso processo: offerta e risposta complete,
/// apertura del data channel, stretta di mano di ciesign_link sopra il canale
/// e un frame da 200 KB spezzato e ricomposto.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('data channel WebRTC con il protocollo di CIE Sign', (tester) async {
    debugPrint('creo i peer');
    final phonePeer = await createWebRtcPeer(const []);
    final pcPeer = await createWebRtcPeer(const []);
    final offer = await phonePeer.createOffer();
    expect(offer, contains('a=candidate'), reason: "l'SDP contiene già i candidati");
    final answer = await pcPeer.acceptOffer(offer);
    await phonePeer.acceptAnswer(answer);
    debugPrint('risposta applicata');
    final phoneCh = await phonePeer.channel.timeout(const Duration(seconds: 20));
    final pcCh = await pcPeer.channel.timeout(const Duration(seconds: 20));

    debugPrint('data channel aperto');
    final pc = await DeviceIdentity.create('PC'), phone = await DeviceIdentity.create('Telefono');
    final qr = PairingOffer(
      pcId: pc.id,
      pcName: pc.name,
      pcPublicKey: pc.publicKey,
      token: List<int>.generate(16, (i) => i),
      addresses: const [],
      remote: true,
    );
    final pcSide = Handshake.acceptAsPc(pcCh, pc, lookup: (_) => null, pending: qr);
    final phoneSide = await Handshake.pairAsPhone(phoneCh, qr, phone);
    final pcSession = await pcSide;
    expect(phoneSide.sas, pcSession.sas);

    final doc = Uint8List.fromList(List.generate(200 * 1024, (i) => i % 253));
    await pcSession.send(DocumentChunk('d1', 0, doc, true));
    final got = await phoneSide.messages.first.timeout(const Duration(seconds: 20));
    expect((got as DocumentChunk).data, doc);

    await phoneSide.close();
    await pcSession.close();
  });

  // Giro completo con un servizio vero, per esempio gli emulatori di Firebase:
  //   flutter test integration_test -d linux \
  //     --dart-define=CIESIGN_SIGNALING_URL=http://127.0.0.1:9000/?ns=demo-ciesign-default-rtdb \
  //     --dart-define=CIESIGN_FIREBASE_API_KEY=demo-key \
  //     --dart-define=CIESIGN_TEST_AUTH_EMULATOR=http://127.0.0.1:9099/
  final env = SignalingConfig.fromEnvironment();
  testWidgets('abbinamento via internet con WebRTC vero e signaling vero', (tester) async {
    const authEmulator = String.fromEnvironment('CIESIGN_TEST_AUTH_EMULATOR');
    final config = SignalingConfig(
      endpoint: env!.endpoint,
      firebaseApiKey: env.firebaseApiKey,
      authEndpoint: authEmulator.isEmpty ? null : Uri.parse(authEmulator),
    );
    final pc = await DeviceIdentity.create('PC'), phone = await DeviceIdentity.create('Telefono');
    final qr = PairingOffer(
      pcId: pc.id,
      pcName: pc.name,
      pcPublicKey: pc.publicKey,
      token: List<int>.generate(16, (i) => 40 + i),
      addresses: const [],
      remote: true,
    );
    final pcSignal = SignalingClient(config), phoneSignal = SignalingClient(config);
    final incoming = Rendezvous(pcSignal, createWebRtcPeer).listen(await Room.forPairing(qr.token)).first;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final phoneCh = await Rendezvous(phoneSignal, createWebRtcPeer).dial(await Room.forPairing(qr.token));
    final pcSide = Handshake.acceptAsPc(await incoming, pc, lookup: (_) => null, pending: qr);
    final phoneSide = await Handshake.pairAsPhone(phoneCh, qr, phone);
    expect(phoneSide.sas, (await pcSide).sas);
    debugPrint('abbinamento via signaling riuscito, codice ${phoneSide.sas}');
    await phoneSide.close();
    pcSignal.close();
    phoneSignal.close();
  }, skip: env == null);
}
