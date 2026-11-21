import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:test/test.dart';

/// I file di prova sono generati con pyHanko e una TSA di prova
/// ("TSA di prova CIE Sign"), firmati con il certificato titolare-test.
Uint8List res(String n) => File('test/resources/$n').readAsBytesSync();

void main() {
  test('CAdES-T: marca temporale di firma riconosciuta e verificata', () {
    final f = CadesFile.open(res('cades-t.p7m'));
    final r = f.reports.single;
    expect(r.isIntact, isTrue);
    expect(r.hasTimestamp, isTrue);
    final t = r.timestamp!;
    expect(t.isValid, isTrue);
    expect(t.tsaName, 'TSA di prova CIE Sign');
    expect(t.genTime.year, greaterThanOrEqualTo(2026));
  });

  test('una marca su dati diversi non risulta valida', () {
    final s = CmsSignedData.parse(res('cades-t.p7m')).signers.single;
    final t = TimestampInfo.parse(s.signatureTimestampToken!, Uint8List.fromList([1, 2, 3]));
    expect(t.imprintMatches, isFalse);
    expect(t.isValid, isFalse);
    expect(t.integrity, SignatureIntegrity.valid);
  });

  test('PAdES-T: marca temporale di firma', () {
    final r = PadesVerifier.verify(res('pades-t.pdf')).single;
    expect(r.isIntact, isTrue);
    expect(r.isDocumentTimestamp, isFalse);
    expect(r.timestamp!.isValid, isTrue);
  });

  test('PAdES con DocTimeStamp: firma e marca del documento distinte', () {
    final rs = PadesVerifier.verify(res('pades-t-doctimestamp.pdf'));
    expect(rs, hasLength(2));
    final firma = rs.firstWhere((r) => !r.isDocumentTimestamp);
    final marca = rs.firstWhere((r) => r.isDocumentTimestamp);
    expect(firma.isIntact, isTrue);
    expect(firma.coversWholeDocument, isFalse);
    expect(marca.isIntact, isTrue);
    expect(marca.coversWholeDocument, isTrue);
    expect(marca.subFilter, 'ETSI.RFC3161');
    expect(marca.timestamp!.tsaName, 'TSA di prova CIE Sign');
    expect(marca.signingTime, marca.timestamp!.genTime);
  });

  group('validità del certificato rispetto a oggi', () {
    final cert = Certificate.fromDer(res('titolare-test.der'));
    final dopoScadenza = cert.notAfter.add(const Duration(days: 1));

    test('certificato valido oggi', () {
      final r = SignatureReport(integrity: SignatureIntegrity.valid, certificate: cert, signingTime: cert.notBefore);
      expect(r.certificateTimeAt(cert.notBefore.add(const Duration(days: 30))), CertificateTime.valid);
    });

    test('scaduto senza marca temporale: la data dichiarata non basta', () {
      final r = SignatureReport(
        integrity: SignatureIntegrity.valid,
        certificate: cert,
        signingTime: cert.notBefore.add(const Duration(days: 1)),
      );
      expect(r.certificateTimeAt(dopoScadenza), CertificateTime.expired);
    });

    test('scaduto ma con marca temporale anteriore alla scadenza', () {
      final r = PadesVerifier.verify(res('pades-t.pdf')).single;
      expect(r.certificateTimeAt(dopoScadenza), CertificateTime.validAtTimestamp);
      final c = CadesFile.open(res('cades-t.p7m')).reports.single;
      expect(c.certificateTimeAt(dopoScadenza), CertificateTime.validAtTimestamp);
    });

    test('data dichiarata anteriore al rilascio del certificato', () {
      final r = SignatureReport(
        integrity: SignatureIntegrity.valid,
        certificate: cert,
        signingTime: cert.notBefore.subtract(const Duration(days: 10)),
      );
      expect(r.certificateTimeAt(cert.notBefore.add(const Duration(days: 1))), CertificateTime.notYetValid);
    });

    test('firma senza certificato', () {
      final r = SignatureReport(integrity: SignatureIntegrity.certificateMissing, certificate: null);
      expect(r.certificateTimeAt(DateTime.now()), CertificateTime.unknown);
    });
  });
}
