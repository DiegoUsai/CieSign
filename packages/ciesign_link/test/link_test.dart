import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Prova l'intero giro sulla rete locale (127.0.0.1): abbinamento,
/// riconnessione, lettura del certificato e firma CAdES con una CIE simulata.
void main() {
  final certDer = File('test/resources/titolare-test.der').readAsBytesSync();
  final key = RsaPrivateKey.fromPkcs8(File('test/resources/titolare-test.pk8').readAsBytesSync());

  late DeviceIdentity pc, phone;
  late PcLinkServer server;
  final pairedPhones = <String, PairedDevice>{};

  setUp(() async {
    pc = await DeviceIdentity.create('UFFICIO-DIEGO');
    phone = await DeviceIdentity.create('Pixel di Diego');
    pairedPhones.clear();
    server = await PcLinkServer.start(pc, lookup: (id) => pairedPhones[id], port: 0);
  });
  tearDown(() => server.close());

  List<String> local() => ['127.0.0.1:${server.port}'];

  test('QR code: andata e ritorno', () async {
    final o = await server.newPairingOffer(bluetooth: true);
    final p = PairingOffer.parse(o.toUri().toString());
    expect(p.pcName, 'UFFICIO-DIEGO');
    expect(p.pcPublicKey, pc.publicKey);
    expect(p.token, o.token);
    expect(p.bluetooth, isTrue);
    expect(() => PairingOffer.parse('https://example.com'), throwsFormatException);
  });

  test('abbinamento con codice di sei cifre, poi firma CAdES', () async {
    final offer = await server.newPairingOffer();
    final pcSide = server.sessions.first;
    final phoneCh = await Handshake.pairAsPhone(
      await PhoneLinkClient.connect(local()),
      PairingOffer.parse(offer.toUri().toString()),
      phone,
    );
    final pcCh = await pcSide;

    expect(phoneCh.sas, matches(RegExp(r'^\d{6}$')));
    expect(pcCh.sas, phoneCh.sas, reason: 'i due schermi mostrano lo stesso codice');
    expect(pcCh.peerName, 'Pixel di Diego');
    expect(phoneCh.peerName, 'UFFICIO-DIEGO');

    // Entrambi confermano il codice; il PC salva l'abbinamento.
    await phoneCh.send(const PairConfirm(true));
    await pcCh.send(const PairConfirm(true));
    expect(await pcCh.messages.first, isA<PairConfirm>());
    expect(await phoneCh.messages.first, isA<PairConfirm>());
    pairedPhones[pcCh.peerId] = PairedDevice(
      id: pcCh.peerId,
      name: pcCh.peerName,
      publicKey: pcCh.peerPublicKey,
      pairedAt: DateTime.now(),
    );
    final pcRecord = PairedDevice(
      id: phoneCh.peerId,
      name: phoneCh.peerName,
      publicKey: phoneCh.peerPublicKey,
      pairedAt: DateTime.now(),
    );
    await phoneCh.close();
    await pcCh.close();
    server.pendingOffer = null;

    // Riconnessione senza QR code.
    final pcSide2 = server.sessions.first;
    final phone2 = await Handshake.helloAsPhone(await PhoneLinkClient.connect(local()), pcRecord, phone);
    final pc2 = await pcSide2;
    expect(phone2.sas, isNull);

    // Smartphone simulato: risponde con il certificato e firma con la "carta".
    unawaited(
      phone2.messages.listen((m) async {
        if (m is CertificateRequest) await phone2.send(CertificateResponse(certDer));
        if (m is SignRequest) {
          expect(m.isExpired(), isFalse);
          expect(m.documentName, 'contratto.txt');
          // Lo smartphone controlla l'impronta del documento dichiarata.
          expect(m.documentDigest, sha256.convert('Contratto di prova.'.codeUnits).bytes);
          await phone2.send(SignResponse(m.id, key.signSha256(m.digestToSign), certDer));
        }
      }).asFuture<void>(),
    );

    final inbox = StreamIterator(pc2.messages);
    await pc2.send(const CertificateRequest());
    expect(await inbox.moveNext(), isTrue);
    final cert = Certificate.fromDer((inbox.current as CertificateResponse).certificate);
    expect(cert.holderName, 'MARIO ROSSI');

    final content = Uint8List.fromList('Contratto di prova.'.codeUnits);
    final prep = CadesPreparation.prepare(content, cert);
    await pc2.send(
      SignRequest(
        id: 'r1',
        documentName: 'contratto.txt',
        documentSize: content.length,
        format: SignFormat.cades,
        signedAttributes: prep.signedAttributes,
        expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      ),
    );
    expect(await inbox.moveNext(), isTrue);
    final resp = inbox.current as SignResponse;
    final p7m = prep.finish(resp.signature);
    expect(CadesFile.open(p7m).reports.single.isIntact, isTrue);
    await pc2.close();
    await phone2.close();
  });

  test('rifiuta chi non ha visto il QR code', () async {
    final offer = await server.newPairingOffer();
    final forged = PairingOffer(
      pcId: offer.pcId,
      pcName: offer.pcName,
      pcPublicKey: offer.pcPublicKey,
      token: List.filled(16, 1),
      addresses: local(),
    );
    final err = server.errors.first;
    await expectLater(
      Handshake.pairAsPhone(await PhoneLinkClient.connect(local()), forged, phone),
      throwsA(isA<LinkException>()),
    );
    expect((await err).toString(), contains('QR code'));
  });

  test('rifiuta uno smartphone non abbinato', () async {
    final fakePc = PairedDevice(id: pc.id, name: pc.name, publicKey: pc.publicKey, pairedAt: DateTime.now());
    await expectLater(
      Handshake.helloAsPhone(await PhoneLinkClient.connect(local()), fakePc, phone),
      throwsA(isA<LinkException>()),
    );
  });

  test('un PC impostore non completa la riconnessione', () async {
    // Il telefono crede di parlare con "pc", ma risponde un altro PC.
    final impostor = await DeviceIdentity.create('IMPOSTORE');
    final other = await PcLinkServer.start(
      impostor,
      lookup: (_) => PairedDevice(id: phone.id, name: 'x', publicKey: phone.publicKey, pairedAt: DateTime.now()),
      port: 0,
    );
    final record = PairedDevice(id: impostor.id, name: pc.name, publicKey: pc.publicKey, pairedAt: DateTime.now());
    final pcSide = other.sessions.first;
    final phoneCh = await Handshake.helloAsPhone(
      await PhoneLinkClient.connect(['127.0.0.1:${other.port}']),
      record,
      phone,
    );
    final impostorCh = await pcSide;
    // Le chiavi di sessione non coincidono: il primo messaggio non si decifra.
    await impostorCh.send(const Ping());
    await expectLater(phoneCh.messages.first, throwsA(isA<LinkException>()));
    await impostorCh.close();
    await other.close();
  });
}
