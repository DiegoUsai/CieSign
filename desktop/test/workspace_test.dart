import 'dart:io';
import 'dart:typed_data';

import 'package:cie_sign_desktop/main.dart';
import 'package:cie_sign_desktop/src/reference_date.dart';
import 'package:cie_sign_desktop/src/workspace.dart';
import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

const _res = '../packages/ciesign_ades/test/resources';

void main() {
  test('data di riferimento in italiano', () {
    expect(parseItalianDate('07/04/2025 10:30'), DateTime(2025, 4, 7, 10, 30));
    expect(parseItalianDate('7/4/2025'), DateTime(2025, 4, 7, 23, 59));
    expect(parseItalianDate('31/02/2025'), isNull);
    expect(parseItalianDate('2025-04-07'), isNull);
  });

  testWidgets('fascicolo: cartella con più documenti, elenco, contenuto del p7m e marcature', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('fascicolo')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final gara = Directory('${dir.path}/gara')..createSync();
    final cert = Certificate.fromDer(File('$_res/titolare-test.der').readAsBytesSync());
    final key = RsaPrivateKey.fromPkcs8(File('$_res/titolare-test.pk8').readAsBytesSync());
    final prep = CadesPreparation.prepare(File('$_res/revoca/gara.zip').readAsBytesSync(), cert);
    File('${gara.path}/offerta.zip.p7m').writeAsBytesSync(prep.finish(key.signSha256(prep.digestToSign)));
    File('${gara.path}/note.txt').writeAsBytesSync(Uint8List.fromList('note'.codeUnits));
    File('${gara.path}/.nascosto').writeAsStringSync('x');

    // L'anteprima (pdfrx) chiede la cartella temporanea al sistema.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    final ws = (await tester.runAsync(() => Workspace.open(dir: dir, network: false)))!;
    await tester.pumpWidget(CieSignApp(startLink: false, workspace: ws));
    await tester.runAsync(() => ws.addPaths([gara.path]));
    await tester.pump();
    expect(ws.set.items.map((i) => i.name), ['note.txt', 'offerta.zip.p7m'], reason: 'file nascosti esclusi, ordine alfabetico');
    expect(find.text('Documenti (2)'), findsOneWidget);

    await tester.runAsync(() => ws.select(1));
    await tester.pump();
    expect(find.text('1 firma, valida'), findsWidgets);
    expect(find.text('Contenuto'), findsOneWidget);
    expect(find.text('1 di 3 file visualizzati'), findsOneWidget, reason: 'il PDF dello zip è mostrato subito');
    expect(find.text('Verificato adesso'), findsWidgets);
    expect(find.textContaining('firma parallela'), findsOneWidget);

    // Verifica alla data: prima della validità del certificato la firma non è valida.
    ws.reference = cert.notBefore.subtract(const Duration(days: 2));
    await tester.pump();
    expect(find.textContaining('NON VALIDA'), findsOneWidget);
    expect(find.textContaining('Verifica al'), findsWidgets);

    // Le marcature restano dopo la chiusura e il fascicolo si riprende.
    await tester.runAsync(() => ws.store.save());
    final ws2 = (await tester.runAsync(() => Workspace.open(dir: dir, network: false)))!;
    expect(ws2.resumable, hasLength(2));
    await tester.runAsync(ws2.resume);
    final it = ws2.set.items.firstWhere((i) => i.name == 'offerta.zip.p7m');
    expect(ws2.set.marksOf(it)!.verifiedAt, isNotNull);
    expect(ws2.reference, ws.reference);
  });
}
