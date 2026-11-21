import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:test/test.dart';

/// I test simulano la CIE con una chiave di prova: il motore riceve solo la
/// firma, esattamente come accadrà con lo smartphone.
void main() {
  final cert = Certificate.fromDer(File('test/resources/titolare-test.der').readAsBytesSync());
  final key = RsaPrivateKey.fromPkcs8(File('test/resources/titolare-test.pk8').readAsBytesSync());
  final out = Directory('build/test-output')..createSync(recursive: true);

  group('certificato', () {
    test('legge titolare, emittente e chiave', () {
      expect(cert.holderName, 'MARIO ROSSI');
      expect(cert.subject.get(Oids.serialNumber), 'TINIT-RSSMRA80A01H501U');
      expect(cert.rsaPublicKey.sizeInBytes, 256);
      expect(cert.notAfter.isAfter(cert.notBefore), isTrue);
    });

    test('firma e verifica PKCS#1 v1.5', () {
      final d = Uint8List.fromList(List.generate(32, (i) => i));
      final s = key.signSha256(d);
      expect(cert.rsaPublicKey.verifySha256(d, s), isTrue);
      d[0] ^= 1;
      expect(cert.rsaPublicKey.verifySha256(d, s), isFalse);
    });
  });

  group('catena CIE', () {
    test('le CA intermedie risalgono alle radici del Ministero', () {
      for (final ca in CieTrust.intermediates) {
        final r = CieTrust.verify(ca, at: DateTime.utc(2030, 1, 1));
        expect(r.status, ChainStatus.cie, reason: ca.subject.toString());
        expect(r.path.length, 2);
        expect(CieTrust.roots, contains(r.path.last));
      }
    });

    test('SUBCA003 è emessa dalla radice del 2024', () {
      final sub3 = CieTrust.intermediates.last;
      expect(sub3.subject.get(Oids.commonName), endsWith('SUBCA003'));
      expect(CieTrust.verify(sub3).path.last.notAfter.year, 2044);
    });

    test('fuori validità alla data della firma', () {
      final subca1 = CieTrust.intermediates.first;
      expect(CieTrust.verify(subca1, at: DateTime.utc(2032, 1, 1)).status, ChainStatus.cieExpired);
    });

    test('un certificato di altri emittenti non è CIE', () {
      final r = CieTrust.verify(cert);
      expect(r.status, ChainStatus.unknownIssuer);
      expect(r.isCieFea, isFalse);
      expect(CieTrust.intermediateFor(cert), isNull);
    });

    test('una firma alterata con il nome della CA della CIE rompe la catena', () {
      final der = Uint8List.fromList(CieTrust.intermediates.last.der);
      der[der.length - 10] ^= 0xFF;
      final r = CieTrust.verify(Certificate.fromDer(der));
      expect(r.status, ChainStatus.brokenChain);
    });

    test('le radici sono quelle pubblicate dal Ministero', () {
      String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      expect(CieTrust.roots.map((r) => hex(r.sha256Fingerprint)), [
        '87364fb476e74962e7c495b9bbaf727813ee007cb56a0ada6ab9868123db267e',
        '40f425927e8a1e6a297a15c2a9d79e2221bf4fe25b2f21e3bfad53a1ba58b0d7',
      ]);
    });
  });

  group('DER', () {
    test('SET OF ordinato e OID', () {
      final s = Der.setOf([Der.smallInt(300), Der.smallInt(1)]);
      expect(DerNode.parse(s)[0].asInt, 1);
      expect(DerNode.parse(Der.oid(Oids.signingCertificateV2)).asOid, Oids.signingCertificateV2);
    });

    test('lunghezza indefinita BER', () {
      final ber = Uint8List.fromList([0x30, 0x80, 0x02, 0x01, 0x05, 0x00, 0x00]);
      final n = DerNode.parse(ber);
      expect(n[0].asInt, 5);
      expect(n.raw.length, 7);
    });
  });

  group('CAdES', () {
    final content = Uint8List.fromList('Contratto di prova, versione 1.'.codeUnits);

    test('firma imbustata, verifica e sbustamento', () {
      final prep = CadesPreparation.prepare(content, cert, signingTime: DateTime.utc(2026, 11, 21, 15));
      final p7m = prep.finish(key.signSha256(prep.digestToSign));
      File('${out.path}/contratto.txt.p7m').writeAsBytesSync(p7m);

      final f = CadesFile.open(p7m);
      expect(f.content, content);
      expect(f.reports.single.isIntact, isTrue);
      expect(f.reports.single.certificate!.holderName, 'MARIO ROSSI');
      expect(f.reports.single.signingTime, DateTime.utc(2026, 11, 21, 15));
      expect(f.reports.single.hasTimestamp, isFalse);
    });

    test('firma staccata', () {
      final prep = CadesPreparation.prepare(content, cert, detached: true);
      final p7s = prep.finish(key.signSha256(prep.digestToSign));
      expect(CadesFile.open(p7s, detachedContent: content).reports.single.isIntact, isTrue);
      final altered = Uint8List.fromList([...content, 0x20]);
      expect(
        CadesFile.open(p7s, detachedContent: altered).reports.single.integrity,
        SignatureIntegrity.contentModified,
      );
    });

    test('rifiuta una firma prodotta da un altra carta', () {
      final prep = CadesPreparation.prepare(content, cert);
      final wrong = key.signSha256(List.filled(32, 7));
      expect(() => prep.finish(wrong), throwsA(isA<SignatureMismatchException>()));
    });

    test('accetta un .p7m in Base64', () {
      final prep = CadesPreparation.prepare(content, cert);
      final p7m = prep.finish(key.signSha256(prep.digestToSign));
      final b64 = Uint8List.fromList(_base64Lines(p7m));
      expect(CadesFile.open(b64).content, content);
    });

    test('nome del file estratto', () {
      expect(CadesFile.unwrappedName('contratto.pdf.p7m'), 'contratto.pdf');
      expect(CadesFile.unwrappedName('contratto.pdf.P7M.p7m'), 'contratto.pdf');
    });
  });

  group('PAdES', () {
    for (final name in ['semplice', 'compresso']) {
      test('firma invisibile su $name.pdf', () {
        final pdf = File('test/resources/$name.pdf').readAsBytesSync();
        final prep = PadesPreparation.prepare(pdf, cert, signingTime: DateTime.utc(2026, 11, 21, 15));
        final signed = prep.finish(key.signSha256(prep.digestToSign));
        File('${out.path}/$name-invisibile-signed.pdf').writeAsBytesSync(signed);

        expect(signed.sublist(0, pdf.length), pdf, reason: 'aggiornamento incrementale: i byte originali restano');
        final r = PadesVerifier.verify(signed).single;
        expect(r.isIntact, isTrue);
        expect(r.coversWholeDocument, isTrue);
        expect(r.subFilter, 'ETSI.CAdES.detached');
        expect(r.fieldName, 'FirmaCIE1');
        expect(PdfDocument.parse(signed).pages.length, 2);
      });

      test('firma visibile su $name.pdf e seconda firma', () {
        final pdf = File('test/resources/$name.pdf').readAsBytesSync();
        final vis = const VisibleSignature(pageIndex: 1, x: 300, y: 60, width: 220, height: 70);
        final p1 = PadesPreparation.prepare(pdf, cert, visible: vis);
        final once = p1.finish(key.signSha256(p1.digestToSign));
        File('${out.path}/$name-visibile-signed.pdf').writeAsBytesSync(once);

        final p2 = PadesPreparation.prepare(
          once,
          cert,
          visible: const VisibleSignature(pageIndex: 0, x: 72, y: 60, width: 200, height: 60),
        );
        final twice = p2.finish(key.signSha256(p2.digestToSign));
        File('${out.path}/$name-due-firme-signed.pdf').writeAsBytesSync(twice);

        final reports = PadesVerifier.verify(twice);
        expect(reports.map((r) => r.fieldName), ['FirmaCIE1', 'FirmaCIE2']);
        expect(reports.every((r) => r.isIntact), isTrue);
        expect(reports.first.coversWholeDocument, isFalse, reason: 'la prima firma non copre la seconda revisione');
        expect(reports.last.coversWholeDocument, isTrue);
      });
    }

    test('rileva la modifica del documento firmato', () {
      final pdf = File('test/resources/semplice.pdf').readAsBytesSync();
      final prep = PadesPreparation.prepare(pdf, cert);
      final signed = prep.finish(key.signSha256(prep.digestToSign));
      final i = String.fromCharCodes(signed).indexOf('Contratto di prova');
      signed[i] = 'K'.codeUnitAt(0);
      expect(PadesVerifier.verify(signed).single.integrity, SignatureIntegrity.contentModified);
    });

    test('rifiuta un file che non è un PDF', () {
      expect(() => PadesPreparation.prepare(Uint8List.fromList([1, 2, 3]), cert), throwsA(isA<PdfFormatException>()));
    });
  });
}

List<int> _base64Lines(Uint8List der) {
  final b = base64.encode(der);
  final lines = [for (var i = 0; i < b.length; i += 64) b.substring(i, i + 64 > b.length ? b.length : i + 64)];
  return latin1.encode(lines.join('\r\n'));
}
