import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cie_sign_companion/link_service.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// Giro completo sul loopback contro un PC simulato con lo stesso server
/// dell'app desktop: abbinamento, richiesta del certificato, riconnessione.
Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory dir;
  late DeviceIdentity pcId;
  late PcLinkServer server;
  final paired = <String, PairedDevice>{};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ciesign_link_test');
    pcId = await DeviceIdentity.create('PC-PROVA');
    paired.clear();
    server = await PcLinkServer.start(pcId, lookup: (id) => paired[id], port: 0);
  });

  tearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
  });

  PairingOffer offer() => server.pendingOffer = PairingOffer(
    pcId: pcId.id,
    pcName: pcId.name,
    pcPublicKey: pcId.publicKey,
    token: randomBytes(16),
    addresses: ['127.0.0.1:${server.port}'],
  );

  test('abbina, risponde al PC e si ricollega dopo un riavvio', () async {
    final o = offer();
    // Il QR code passa per il testo, come quando lo inquadra la fotocamera.
    final parsed = PairingOffer.parse(o.toUri().toString());

    final phone = await PhoneLink.open(dir, deviceName: 'Telefono di prova');
    expect(phone.state, LinkState.notPaired);

    final pcSession = server.sessions.first;
    final attempt = await phone.startPairing(parsed);
    final pc = await pcSession;
    expect(pc.sas, attempt.sas);
    expect(pc.peerName, 'Telefono di prova');

    // Il PC conferma e aspetta la conferma del telefono.
    final pcMessages = StreamIterator(pc.messages);
    await pc.send(const PairConfirm(true));
    expect(await attempt.confirm(true), isTrue);
    expect(await pcMessages.moveNext(), isTrue);
    expect((pcMessages.current as PairConfirm).ok, isTrue);
    paired[pc.peerId] = PairedDevice(id: pc.peerId, name: pc.peerName, publicKey: pc.peerPublicKey, pairedAt: DateTime.now());

    expect(phone.state, LinkState.connected);
    expect(phone.pc!.device.name, 'PC-PROVA');

    // Il PC chiede il certificato: la richiesta arriva all'interfaccia.
    final req = phone.requests.first;
    await pc.send(const CertificateRequest());
    expect(await req, isA<CertificateRequest>());
    await phone.send(CertificateResponse(Uint8List.fromList([1, 2, 3])));
    expect(await pcMessages.moveNext(), isTrue);
    expect((pcMessages.current as CertificateResponse).certificate, [1, 2, 3]);

    // Riavvio dell'app: l'abbinamento resta e il telefono si ricollega con hello.
    phone.dispose();
    await pc.close();
    final again = await PhoneLink.open(dir, deviceName: 'Telefono di prova');
    expect(again.state, LinkState.disconnected);
    expect(again.identity.id, phone.identity.id);
    final next = server.sessions.first;
    await again.connect();
    expect(again.state, LinkState.connected);
    final pc2 = await next;
    expect(pc2.sas, isNull);
    expect(pc2.peerId, phone.identity.id);
    again.dispose();
    await pc2.close();
  });

  test('se il PC nega il codice l\'abbinamento non si salva', () async {
    final phone = await PhoneLink.open(dir, deviceName: 'Telefono');
    final pcSession = server.sessions.first;
    final attempt = await phone.startPairing(offer());
    final pc = await pcSession;
    await pc.send(const PairConfirm(false));
    expect(await attempt.confirm(true), isFalse);
    expect(phone.state, LinkState.notPaired);
    phone.dispose();
  });

  test('un QR code senza indirizzi dà un errore chiaro', () async {
    final phone = await PhoneLink.open(dir, deviceName: 'Telefono');
    final o = PairingOffer(pcId: 'x', pcName: 'PC', pcPublicKey: pcId.publicKey, token: randomBytes(16), addresses: const []);
    await expectLater(phone.startPairing(o), throwsA(isA<LinkException>()));
    phone.dispose();
  });
}
