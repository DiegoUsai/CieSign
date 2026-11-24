import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:test/test.dart';

const _res = '../ciesign_ades/test/resources';

class _NoNetwork implements RevocationFetcher {
  @override
  Future<Uint8List> get(Uri url) async => throw const SocketException('rete assente');
  @override
  Future<Uint8List> post(Uri url, Uint8List body, String contentType) async => throw const SocketException('rete assente');
}

void main() {
  final cert = Certificate.fromDer(File('$_res/titolare-test.der').readAsBytesSync());
  final key = RsaPrivateKey.fromPkcs8(File('$_res/titolare-test.pk8').readAsBytesSync());
  late Directory tmp;
  // Il certificato di prova, autofirmato, fa da radice CIE: altrimenti ogni
  // firma risulterebbe "da controllare" per l'emittente non riconosciuto.
  setUpAll(() => CieTrust.testRoots.add(cert));
  tearDownAll(CieTrust.testRoots.clear);

  setUp(() => tmp = Directory.systemTemp.createTempSync('docset'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Uint8List wrap(Uint8List content) {
    final p = CadesPreparation.prepare(content, cert);
    return p.finish(key.signSha256(p.digestToSign));
  }

  group('tempo relativo', () {
    final now = DateTime(2026, 11, 22, 18, 30);
    test('adesso, di recente, oggi, ieri, data', () {
      expect(relativeTime(DateTime(2026, 11, 22, 18, 28), now: now), 'adesso');
      expect(relativeTime(DateTime(2026, 11, 22, 18, 0), now: now), 'di recente');
      expect(relativeTime(DateTime(2026, 11, 22, 9, 5), now: now), 'oggi alle 09:05');
      expect(relativeTime(DateTime(2026, 11, 21, 23, 59), now: now), 'ieri alle 23:59');
      expect(relativeTime(DateTime(2026, 11, 3, 8), now: now), 'il 03/11/2026');
      expect(freshnessOf(DateTime(2026, 11, 22, 18, 0), now: now), Freshness.now);
      expect(freshnessOf(DateTime(2026, 11, 22, 9), now: now), Freshness.today);
      expect(freshnessOf(DateTime(2026, 11, 21, 23), now: now), Freshness.earlier);
    });
  });

  test('le marcature restano dopo la riapertura e seguono il contenuto', () async {
    final f = File('${tmp.path}/ciesign.json');
    final store = await MarkStore.open(f);
    final set = DocumentSet(store: store);
    final pdf = File('$_res/semplice.pdf').readAsBytesSync();
    final p7m = wrap(File('$_res/revoca/gara.zip').readAsBytesSync());
    final items = set.add([MemorySource('a/semplice.pdf', 'semplice.pdf', pdf), MemorySource('a/gara.zip.p7m', 'gara.zip.p7m', p7m)]);
    expect(items, hasLength(2));
    expect(set.add([MemorySource('a/semplice.pdf', 'semplice.pdf', pdf)]), isEmpty, reason: 'niente doppioni');

    await set.load(items[1]);
    final gara = items[1];
    expect(gara.outcome, Outcome.valid);
    expect(gara.summary, '1 firma, valida');
    final unviewed = set.unviewedFiles(gara);
    expect(unviewed.map((f) => f.name), unorderedEquals(['offerta.txt', 'con-allegato.pdf', 'capitolato.txt']));
    set.markFileViewed(gara, unviewed.first, external: true);
    expect(set.unviewedFiles(gara), hasLength(2));
    await store.close();

    // Riapertura: stesso contenuto da un altro percorso.
    final store2 = await MarkStore.open(f);
    expect(store2.workingSet, ['a/semplice.pdf', 'a/gara.zip.p7m']);
    final set2 = DocumentSet(store: store2);
    final again = set2.add([MemorySource('b/copia.p7m', 'copia.p7m', p7m)]).single;
    await set2.load(again);
    final m = set2.marksOf(again)!;
    expect(m.verifiedOutcome, Outcome.valid);
    expect(m.files.values.single.external, isTrue);
    expect(set2.unviewedFiles(again), hasLength(2));
    expect(store2.recents(kind: ActivityKind.verified).first.name, 'copia.p7m');
  });

  test('senza rete la revoca è da controllare, non blocca la verifica', () async {
    final store = await MarkStore.open(File('${tmp.path}/s.json'));
    final set = DocumentSet(store: store, checker: RevocationChecker(_NoNetwork()));
    // Il titolare di prova non indica servizi di revoca.
    final it = set.add([MemorySource('x.p7m', 'x.p7m', wrap(Uint8List.fromList([1, 2, 3])))]).single;
    await set.load(it);
    expect(it.revocations!.single.status, RevocationStatus.unknown);
    expect(it.outcome, Outcome.warning);
  });

  test('verifica alla data: cambia l\'esito senza ricaricare', () async {
    final store = await MarkStore.open(File('${tmp.path}/s.json'));
    final set = DocumentSet(store: store);
    final it = set.add([MemorySource('x.p7m', 'x.p7m', wrap(Uint8List.fromList([1])))]).single;
    await set.load(it);
    expect(it.outcome, Outcome.valid);
    set.reference = cert.notBefore.subtract(const Duration(days: 1));
    expect(it.outcome, Outcome.invalid);
    expect(store.marksOf(it.fingerprint!).verifiedReference, set.reference);
  });

  test('verifica di tutti, firmati e Recenti', () async {
    final store = await MarkStore.open(File('${tmp.path}/s.json'));
    final set = DocumentSet(store: store, keepLoaded: 1);
    set.add([for (var i = 0; i < 4; i++) MemorySource('d$i.p7m', 'd$i.p7m', wrap(Uint8List.fromList([i])))]);
    var last = 0;
    await set.verifyAll(onProgress: (d, t) => last = d);
    expect(last, 4);
    expect(set.items.every((i) => i.outcome == Outcome.valid), isTrue);
    expect(set.items.where((i) => i.tree != null).length, lessThanOrEqualTo(2));
    store.markSigned('abc', name: 'd0.p7m', output: '/tmp/d0.p7m.p7m', format: 'CAdES', holder: 'MARIO ROSSI');
    expect(store.recents(kind: ActivityKind.signed).single.name, 'd0.p7m.p7m');
    expect(store.recents(), hasLength(5));
  });

  test('rapporto PDF di più documenti', () async {
    final store = await MarkStore.open(File('${tmp.path}/s.json'));
    final set = DocumentSet(store: store);
    set.add([
      MemorySource('g.p7m', 'gara.zip.p7m', wrap(File('$_res/revoca/gara.zip').readAsBytesSync())),
      MemorySource('t.pdf', 'pades-t.pdf', File('$_res/pades-t.pdf').readAsBytesSync()),
    ]);
    for (final i in set.items) {
      await set.load(i);
    }
    final pdf = await VerificationReportPdf.build([
      for (final i in set.items) ReportDocument(name: i.name, tree: i.tree!, evaluations: i.evaluationsAt(null), marks: set.marksOf(i)),
    ], appVersion: '0.1.0');
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    Directory('build/test-output').createSync(recursive: true);
    File('build/test-output/rapporto-verifica.pdf').writeAsBytesSync(pdf);
  });
}
