import 'dart:convert';
import 'dart:typed_data';

import 'package:ciesign_cie/ciesign_cie.dart';
import 'package:ciesign_cie/src/constants.dart';
import 'package:ciesign_cie/src/tlv.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:test/test.dart';

import 'simulated_cie.dart';

Uint8List sha(String s) => Uint8List.fromList(c.sha256.convert(utf8.encode(s)).bytes);

Future<CieSessionResult> session(SimulatedCie card, String pin, Uint8List? digest) =>
    CieSigner.run(CieCard(card, caPrivateExponent: card.caPrivateExponent), pin, (_) async => digest);

void main() {
  group('primitive', () {
    test('padding ISO 9797-1 metodo 2', () {
      expect(Bytes.hex(Bytes.isoPad(Bytes.fromHex('010203'))), '0102038000000000');
      expect(Bytes.hex(Bytes.isoPad(Bytes.fromHex('0102030405060708'))), '01020304050607088000000000000000');
      expect(Bytes.isoUnpad(Bytes.fromHex('0102038000000000')), Bytes.fromHex('010203'));
      expect(() => Bytes.isoUnpad(Bytes.fromHex('0102030000000000')), throwsA(isA<SecureMessagingException>()));
    });

    test('incremento del contatore con riporto', () {
      final ctr = Bytes.fromHex('00000000000000FF');
      Bytes.increment(ctr);
      expect(Bytes.hex(ctr), '0000000000000100');
    });

    test('Retail MAC secondo il vettore di prova ICAO 9303', () {
      final ksMac = Bytes.fromHex('F1CB1F1FB5ADF208806B89DC579DC1F8');
      final n = Bytes.fromHex('887022120C06C2270CA4020C800000008709016375432908C044F68000000000');
      expect(Bytes.hex(CieCrypto.retailMac(ksMac, n)), 'BF8B92D635FF24F8');
    });

    test('cifratura 3DES secondo il vettore di prova ICAO 9303', () {
      final ksEnc = Bytes.fromHex('979EC13B1CBFE9DCD01AB0FED307EAE5');
      expect(Bytes.hex(CieCrypto.tdesEncrypt(ksEnc, Bytes.isoPad(Bytes.fromHex('011E')))), '6375432908C044F6');
    });

    test('codifica e analisi TLV', () {
      expect(Bytes.hex(Tlv.encode(0x91, Uint8List(256)).sublist(0, 4)), '91820100');
      final nested = Tlv.encode(0x70, Tlv.encode(0x7F49, Bytes.concat([Tlv.encode(0x81, [1, 2]), Tlv.encode(0x5F20, [3])])));
      final root = Tlv.parse(nested);
      expect(root.child(0).child(0).value, [1, 2]);
      expect(root.child(0).childWithTag([0x5F, 0x20]).value, [3]);
    });

    test('DigestInfo SHA-256', () {
      final di = CieSigner.digestInfoSha256(Uint8List(32));
      expect(di.length, 51);
      expect(Bytes.hex(di.sublist(0, 19)), '3031300D060960864801650304020105000420');
    });

    test('rimozione del riempimento dopo il certificato', () {
      final der = Tlv.encode(0x30, Uint8List(300)..fillRange(0, 300, 7));
      expect(CieCard.trimDer(Bytes.concat([der, Uint8List(50)])), der);
    });

    test('le chiavi del dispositivo formano una coppia RSA valida', () {
      final n = Bytes.toBigInt(CieConstants.ifdModulus);
      final m = Bytes.toBigInt(Bytes.random(200));
      final x = m.modPow(Bytes.toBigInt(CieConstants.ifdPrivateExponent), n);
      expect(x.modPow(Bytes.toBigInt(CieConstants.ifdPublicExponent), n), m);
    });
  });

  group('carta simulata', () {
    test("legge il certificato e firma un'impronta", () async {
      final card = SimulatedCie();
      final digest = sha('Prova CIE Sign');
      final r = await session(card, '12345678', digest);
      expect(r.certificate, card.certificateDer);
      expect(r.signature!.length, 256);
      expect(CieSigner.verifyPkcs1Sha256(card.holderModulus, BigInt.from(65537), digest, r.signature!), isTrue);
    });

    test("calcola l'impronta dal certificato letto nella stessa sessione", () async {
      final card = SimulatedCie();
      Uint8List? seen;
      final r = await CieSigner.run(CieCard(card, caPrivateExponent: card.caPrivateExponent), '12345678', (cert) async {
        seen = cert;
        return Uint8List.fromList(c.sha256.convert([...cert, ...utf8.encode('attributi')]).bytes);
      });
      expect(seen, card.certificateDer);
      expect(CieSigner.verifyPkcs1Sha256(card.holderModulus, BigInt.from(65537), r.digest!, r.signature!), isTrue);
    });

    test('senza impronta si ferma alla lettura del certificato', () async {
      final card = SimulatedCie();
      final r = await session(card, '12345678', null);
      expect(r.certificate, card.certificateDer);
      expect(r.signature, isNull);
    });

    test('una firma alterata non viene accettata', () async {
      final card = SimulatedCie();
      final digest = sha('documento');
      final r = await session(card, '12345678', digest);
      final tampered = Uint8List.fromList(r.signature!)..[100] ^= 1;
      final e = BigInt.from(65537);
      expect(CieSigner.verifyPkcs1Sha256(card.holderModulus, e, digest, tampered), isFalse);
      expect(CieSigner.verifyPkcs1Sha256(card.holderModulus, e, sha('altro'), r.signature!), isFalse);
    });

    test('PIN errato riporta i tentativi rimasti', () async {
      await expectLater(session(SimulatedCie(), '00000000', null),
          throwsA(isA<WrongPinException>().having((e) => e.remainingAttempts, 'tentativi', 2)));
    });

    test('PIN errato con status non protetto', () async {
      await expectLater(session(SimulatedCie(plainPinErrors: true, remainingAttempts: 2), '00000000', null),
          throwsA(isA<WrongPinException>().having((e) => e.remainingAttempts, 'tentativi', 1)));
    });

    test('PIN bloccato', () async {
      await expectLater(session(SimulatedCie(remainingAttempts: 0), '12345678', null), throwsA(isA<PinBlockedException>()));
      await expectLater(session(SimulatedCie(remainingAttempts: 1), '11111111', null), throwsA(isA<PinBlockedException>()));
    });

    test('PIN di formato errato non arriva alla carta', () async {
      final card = SimulatedCie();
      final cie = CieCard(card, caPrivateExponent: card.caPrivateExponent);
      await cie.openSecureChannel();
      final before = card.commandCount;
      await expectLater(cie.verifyPin('1234'), throwsA(isA<InvalidPinFormatException>()));
      await expectLater(cie.verifyPin('1234567a'), throwsA(isA<InvalidPinFormatException>()));
      expect(card.commandCount, before);
      expect(card.remainingAttempts, 3);
    });

    test('la firma funziona anche se la carta rifiuta la selezione con P2=0C', () async {
      final card = SimulatedCie(rejectSelectWithoutFci: true);
      final digest = sha('prova');
      final r = await session(card, '12345678', digest);
      expect(CieSigner.verifyPkcs1Sha256(card.holderModulus, BigInt.from(65537), digest, r.signature!), isTrue);
    });

    test('una carta diversa dalla CIE viene riconosciuta', () async {
      final notCie = FunctionTransport((_) async => Uint8List.fromList([0x6A, 0x82]));
      await expectLater(CieCard(notCie).openSecureChannel(), throwsA(isA<NotACieException>()));
    });
  });
}
