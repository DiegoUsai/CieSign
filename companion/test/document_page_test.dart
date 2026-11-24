import 'dart:convert';
import 'dart:io';

import 'package:cie_sign_companion/cie_bridge.dart';
import 'package:cie_sign_companion/document_page.dart';
import 'package:cie_sign_companion/local_sign.dart';
import 'package:cie_sign_companion/main.dart';
import 'package:cie_sign_companion/recents_page.dart';
import 'package:cie_sign_companion/workspace.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late MobileWorkspace ws;

  Future<void> setUpWs(WidgetTester tester, Map<String, String> files) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('firmami-test');
      ws = await MobileWorkspace.open(dir: dir, network: false);
      await ws.openFiles([
        for (final e in files.entries) (name: e.key, read: () async => utf8.encode(e.value)),
      ]);
      await ws.set.fingerprintAll();
    });
  }

  // Salva subito l'archivio: annulla il salvataggio differito, che altrimenti
  // resterebbe in sospeso a fine test.
  Future<void> done(WidgetTester tester) => tester.runAsync(() => ws.store.save());

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  testWidgets('il fascicolo mostra i documenti e le marcature', (tester) async {
    await setUpWs(tester, {'offerta.txt': 'offerta economica', 'capitolato.txt': 'capitolato tecnico'});
    await tester.pumpWidget(CieSignCompanionApp(home: DossierPage(ws: ws, openDocument: (_) async {})));
    await tester.pump();
    expect(find.text('Fascicolo · 2 documenti'), findsOneWidget);
    expect(find.text('offerta.txt'), findsOneWidget);
    expect(find.text('capitolato.txt'), findsOneWidget);
    expect(find.textContaining('Non ancora visto'), findsNWidgets(2));
    // Aperto il primo nella sua pagina, risulta visto adesso.
    final first = ws.set.items.first;
    await tester.runAsync(() async {
      ws.viewed(first, first.tree!);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.textContaining('Visto adesso'), findsOneWidget);
    expect(find.textContaining('Non ancora visto'), findsOneWidget);
    await done(tester);
  });

  testWidgets('la pagina del documento mostra anteprima ed esito, e scorre il fascicolo', (tester) async {
    await setUpWs(tester, {'a.txt': 'primo documento', 'b.txt': 'secondo documento'});
    await tester.pumpWidget(CieSignCompanionApp(
      home: DocumentPage(ws: ws, bridge: CieBridge(), signedStore: SignedStore(dir)),
    ));
    await tester.pump();
    expect(find.text('Il documento non contiene firme'), findsOneWidget);
    expect(find.text('primo documento'), findsOneWidget);
    expect(find.text('1 di 2'), findsOneWidget);
    await tester.runAsync(() => ws.select(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('secondo documento'), findsOneWidget);
    expect(find.text('2 di 2'), findsOneWidget);
    expect(find.text('Firma'), findsOneWidget);
    await done(tester);
  });

  testWidgets('i Recenti filtrano firmati e verificati', (tester) async {
    await setUpWs(tester, {'a.txt': 'x'});
    ws.store.markSigned('abc', name: 'contratto.pdf', output: '${dir.path}/contratto-signed.pdf', format: 'PAdES', holder: 'Prova');
    await tester.pumpWidget(CieSignCompanionApp(home: RecentsPage(ws: ws, openFile: (_) async {})));
    await tester.pump();
    expect(find.text('contratto-signed.pdf'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    await tester.tap(find.text('Firmati'));
    await tester.pump();
    expect(find.text('contratto-signed.pdf'), findsOneWidget);
    expect(find.text('a.txt'), findsNothing);
    await tester.tap(find.text('Verificati'));
    await tester.pump();
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('contratto-signed.pdf'), findsNothing);
    await done(tester);
  });

  test('marcature in una riga', () {
    expect(marksLine(null), 'Non ancora visto');
    final m = DocumentMarks('x')..viewedAt = DateTime.now();
    expect(marksLine(m), 'Visto adesso');
  });
}
