import 'dart:io';
import 'dart:typed_data';

import 'package:cie_sign_companion/local_sign.dart';
import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart' show SignFormat;
import 'package:flutter_test/flutter_test.dart';

Uint8List _res(String name) => File('../packages/ciesign_ades/test/resources/$name').readAsBytesSync();

void main() {
  final certDer = _res('titolare-test.der');
  final key = RsaPrivateKey.fromPkcs8(_res('titolare-test.pk8'));
  final cert = Certificate.fromDer(certDer);
  final valid = cert.notBefore.add(const Duration(days: 1));

  test('firma PAdES visibile sul telefono, integra alla verifica', () {
    final doc = LocalDocument('contratto.pdf', _res('semplice.pdf'));
    final p = LocalSigner.prepare(
      doc,
      SignFormat.pades,
      certDer,
      visible: VisibleSignature(pageIndex: 0, x: 50, y: 50, width: 200, height: 64),
      now: valid,
    );
    final out = p.finish(key.signSha256(p.digestToSign));
    final reports = PadesVerifier.verify(out);
    expect(reports, hasLength(1));
    expect(reports.single.isIntact, isTrue);
  });

  test('firma CAdES di un file qualsiasi, con il documento sbustabile', () {
    final content = Uint8List.fromList('testo da firmare'.codeUnits);
    final p = LocalSigner.prepare(LocalDocument('nota.txt', content), SignFormat.cades, certDer, now: valid);
    final out = p.finish(key.signSha256(p.digestToSign));
    final f = CadesFile.open(out);
    expect(f.content, content);
    expect(f.reports.single.isIntact, isTrue);
  });

  test('su un .p7m la firma si aggiunge alla busta (firma parallela)', () {
    final content = Uint8List.fromList('offerta'.codeUnits);
    final first = LocalSigner.prepare(LocalDocument('offerta.txt', content), SignFormat.cades, certDer, now: valid);
    final p7m = first.finish(key.signSha256(first.digestToSign));
    final doc = LocalDocument('offerta.txt.p7m', p7m);
    expect(LocalSigner.isCosign(doc, SignFormat.cades), isTrue);
    expect(LocalSigner.signedName(doc.name, SignFormat.cades, cosign: true), 'offerta.txt.p7m');
    final second = LocalSigner.prepare(doc, SignFormat.cades, certDer, now: valid);
    final out = second.finish(key.signSha256(second.digestToSign));
    final f = CadesFile.open(out);
    expect(f.content, content);
    expect(f.reports, hasLength(2));
    expect(f.reports.every((r) => r.isIntact), isTrue);
  });

  test('rifiuta un certificato scaduto prima di far firmare la carta', () {
    final doc = LocalDocument('contratto.pdf', _res('semplice.pdf'));
    expect(
      () => LocalSigner.prepare(doc, SignFormat.pades, certDer, now: cert.notAfter.add(const Duration(days: 1))),
      throwsA(isA<LocalSignException>().having((e) => e.message, 'message', contains('scaduto'))),
    );
  });

  test('una firma di un\'altra chiave viene respinta', () {
    final content = Uint8List.fromList([1, 2, 3]);
    final p = LocalSigner.prepare(LocalDocument('a.bin', content), SignFormat.cades, certDer, now: valid);
    expect(() => p.finish(Uint8List(256)), throwsA(isA<LocalSignException>()));
  });

  test('PAdES su un file che non è PDF è rifiutata', () {
    expect(
      () => LocalSigner.prepare(LocalDocument('a.txt', Uint8List(10)), SignFormat.pades, certDer, now: valid),
      throwsA(isA<LocalSignException>()),
    );
  });

  test('nomi dei file firmati', () {
    expect(LocalSigner.signedName('atto.pdf', SignFormat.pades), 'atto-signed.pdf');
    expect(LocalSigner.signedName('atto.pdf', SignFormat.cades), 'atto.pdf.p7m');
  });

  test('l\'archivio non sovrascrive e mostra prima il più recente', () async {
    final tmp = await Directory.systemTemp.createTemp('firmati');
    final store = SignedStore(Directory('${tmp.path}/firmati'));
    final a = await store.save('atto.pdf', Uint8List.fromList([1]));
    await a.setLastModified(DateTime(2026, 1, 1));
    final b = await store.save('atto.pdf', Uint8List.fromList([2]));
    expect(b.path, endsWith('atto (2).pdf'));
    final list = await store.list();
    expect(list.map((f) => f.path), [b.path, a.path]);
    await tmp.delete(recursive: true);
  });
}
