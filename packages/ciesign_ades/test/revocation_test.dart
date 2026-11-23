import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:test/test.dart';

/// Rete simulata: restituisce le risposte OCSP e la CRL generate da
/// tool/genera-prove-revoca.sh con una CA di prova.
class _FakeFetcher implements RevocationFetcher {
  _FakeFetcher({this.ocsp, this.ocspFails = false});

  final Uint8List? ocsp;
  final bool ocspFails;
  var crlDownloads = 0;

  @override
  Future<Uint8List> get(Uri url) async {
    if (url.path.endsWith('ca.der')) return File('test/resources/revoca/ca.der').readAsBytesSync();
    crlDownloads++;
    return File('test/resources/revoca/ca.crl').readAsBytesSync();
  }

  @override
  Future<Uint8List> post(Uri url, Uint8List body, String contentType) async {
    expect(contentType, 'application/ocsp-request');
    if (ocspFails || ocsp == null) throw const SocketException('rete assente');
    return ocsp!;
  }
}

Certificate _cert(String n) => Certificate.fromDer(File('test/resources/revoca/$n.der').readAsBytesSync());
Uint8List _bytes(String n) => File('test/resources/revoca/$n').readAsBytesSync();

void main() {
  final ca = _cert('ca'), valido = _cert('valido'), revocato = _cert('revocato');

  test('legge gli indirizzi OCSP e CRL dal certificato', () {
    expect(valido.ocspUrls.single.toString(), 'http://ocsp.prova.invalid/');
    expect(valido.crlUrls.single.toString(), 'http://crl.prova.invalid/ca.crl');
    expect(valido.caIssuersUrls.single.toString(), 'http://ca.prova.invalid/ca.der');
  });

  group('OCSP', () {
    test('certificato non revocato', () async {
      final r = await RevocationChecker(_FakeFetcher(ocsp: _bytes('ocsp-valido.der'))).check(valido, ca);
      expect(r.status, RevocationStatus.good);
      expect(r.source, 'OCSP');
    });

    test('certificato revocato con data e motivo', () async {
      final r = await RevocationChecker(_FakeFetcher(ocsp: _bytes('ocsp-revocato.der'))).check(revocato, ca);
      expect(r.status, RevocationStatus.revoked);
      expect(r.reason, 'chiave compromessa');
      expect(r.revokedAt(DateTime.now().add(const Duration(minutes: 1))), isTrue);
      expect(r.revokedAt(DateTime.utc(2025, 6, 1)), isFalse, reason: 'alla data scelta non era ancora revocato');
    });

    test('risposta per un altro certificato: si passa alla CRL', () async {
      final f = _FakeFetcher(ocsp: _bytes('ocsp-valido.der'));
      final r = await RevocationChecker(f).check(revocato, ca);
      expect(r.source, 'CRL');
      expect(r.status, RevocationStatus.revoked);
    });

    test('risposta non firmata dall\'emittente: non affidabile', () {
      final other = Certificate.fromDer(File('test/resources/titolare-test.der').readAsBytesSync());
      final r = OcspResponse.parse(_bytes('ocsp-valido.der')).evaluate(valido, other);
      expect(r.status, RevocationStatus.unknown);
    });
  });

  group('CRL', () {
    test('senza OCSP usa la CRL e la tiene in memoria', () async {
      final f = _FakeFetcher(ocspFails: true);
      final checker = RevocationChecker(f);
      expect((await checker.check(valido, ca)).status, RevocationStatus.good);
      final r = await checker.check(revocato, ca);
      expect(r.status, RevocationStatus.revoked);
      expect(r.source, 'CRL');
      expect(r.reason, 'chiave compromessa');
      expect(f.crlDownloads, 1);
    });

    test('CRL firmata da un altro: rifiutata', () {
      final crl = Crl.parse(_bytes('ca.crl'));
      expect(crl.isSignedBy(ca), isTrue);
      expect(crl.isSignedBy(valido), isFalse);
    });
  });

  group('valutazione alla data', () {
    final key = RsaPrivateKey.fromPkcs8(_bytes('valido.pk8'));

    SignatureReport signed() {
      final prep = CadesPreparation.prepare(Uint8List.fromList('ciao'.codeUnits), valido);
      final p7m = prep.finish(key.signSha256(prep.digestToSign));
      return CadesFile.open(p7m).reports.single;
    }

    test('revocato prima della data di verifica: non valida', () {
      final r = signed();
      final rev = RevocationReport(
        status: RevocationStatus.revoked,
        source: 'OCSP',
        revocationTime: DateTime.now().subtract(const Duration(days: 1)),
        reason: 'chiave compromessa',
      );
      final e = SignatureEvaluation(r, revocation: rev);
      expect(e.outcome, Outcome.invalid);
      expect(e.reason, startsWith('Certificato revocato il'));
      expect(e.verdict, 'NON VALIDA');
    });

    test('revocato dopo la data scelta: valida a quella data', () {
      final r = signed();
      final rev = RevocationReport(status: RevocationStatus.revoked, revocationTime: DateTime.now().subtract(const Duration(days: 1)));
      final e = SignatureEvaluation(r, revocation: rev, at: DateTime.now().subtract(const Duration(days: 10)));
      expect(e.outcome, Outcome.valid);
      expect(e.revocationText, contains('dopo la data di verifica'));
    });

    test('certificato scaduto alla data scelta', () {
      final r = signed();
      final e = SignatureEvaluation(r, at: valido.notAfter.add(const Duration(days: 1)));
      expect(e.outcome, Outcome.invalid);
      expect(e.reason, contains('scaduto'));
    });

    test('revoca non verificabile: da controllare', () {
      final e = SignatureEvaluation(signed(), revocation: const RevocationReport(status: RevocationStatus.unknown, message: 'rete assente'));
      expect(e.outcome, Outcome.warning);
      expect(e.verdict, 'DA CONTROLLARE');
    });

    test('checkRevocations trova l\'emittente anche fuori dalla busta', () async {
      final prep = CadesPreparation.prepare(Uint8List.fromList('x'.codeUnits), valido);
      final p7m = prep.finish(key.signSha256(prep.digestToSign));
      // La CA di prova non è nella busta: si scarica dall'indirizzo caIssuers.
      final reports = CadesFile.open(p7m).reports;
      final out = await checkRevocations(reports, RevocationChecker(_FakeFetcher(ocspFails: true)));
      expect(out.single.status, RevocationStatus.good);
      expect(out.single.source, 'CRL');
    });
  });
}
