import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:test/test.dart';

/// Revisione di sicurezza del 22/11/2026, punto 1: una firma integra non
/// basta. Chiunque può creare un certificato autofirmato con il nome del
/// titolare e dell'emittente che preferisce, e una marca temporale di una TSA
/// non verificata.
void main() {
  Uint8List res(String n) => File('test/resources/$n').readAsBytesSync();
  final cert = Certificate.fromDer(res('titolare-test.der'));
  final key = RsaPrivateKey.fromPkcs8(res('titolare-test.pk8'));

  SignatureReport selfSigned() {
    final p = CadesPreparation.prepare(Uint8List.fromList('contratto'.codeUnits), cert);
    return CadesFile.open(p.finish(key.signSha256(p.digestToSign))).reports.single;
  }

  test('certificato autofirmato con il nome di una persona: da controllare, mai valida', () {
    final r = selfSigned();
    expect(r.isIntact, isTrue);
    expect(r.chain!.status, ChainStatus.unknownIssuer);
    expect(r.certificate!.holderName, 'MARIO ROSSI');
    final e = SignatureEvaluation(r, revocation: const RevocationReport(status: RevocationStatus.good));
    expect(e.outcome, Outcome.warning);
    expect(e.verdict, 'DA CONTROLLARE');
    expect(e.headline, contains('emittente del certificato non è riconosciuto'));
    expect(e.chainText, contains('non da una CA della CIE'));
  });

  test('marca temporale del documento di una TSA non verificata: da controllare', () {
    final marca = PadesVerifier.verify(res('pades-t-doctimestamp.pdf')).firstWhere((r) => r.isDocumentTimestamp);
    expect(marca.isIntact, isTrue);
    final e = SignatureEvaluation(marca);
    expect(e.outcome, Outcome.warning);
    expect(e.headline, contains('autorità di marcatura non verificata'));
  });

  group('con il certificato di prova accettato come radice CIE', () {
    setUpAll(() => CieTrust.testRoots.add(cert));
    tearDownAll(CieTrust.testRoots.clear);

    test('firma integra con catena riconosciuta: valida', () {
      final e = SignatureEvaluation(selfSigned(), revocation: const RevocationReport(status: RevocationStatus.good));
      expect(e.outcome, Outcome.valid);
    });

    test('certificato scaduto salvato solo da una marca non verificata: da controllare', () {
      final r = PadesVerifier.verify(res('pades-t.pdf')).firstWhere((r) => !r.isDocumentTimestamp);
      expect(r.timestamp?.isValid, isTrue);
      final dopo = r.certificate!.notAfter.add(const Duration(days: 1));
      final e = SignatureEvaluation(
        r,
        at: dopo,
        revocation: const RevocationReport(status: RevocationStatus.good),
      );
      expect(e.certificateTime, CertificateTime.validAtTimestamp);
      expect(e.outcome, Outcome.warning);
      expect(e.reason, contains('autorità di marcatura non verificata'));
    });
  });
}
