import 'dart:io';

import 'package:cie_sign_desktop/main.dart';
import 'package:cie_sign_desktop/src/sign_workflow.dart';
import 'package:cie_sign_desktop/src/signers.dart';
import 'package:cie_sign_desktop/src/workspace.dart';
import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('la schermata iniziale invita ad aprire un documento', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ws')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final ws = (await tester.runAsync(() => Workspace.open(dir: dir, network: false)))!;
    await tester.pumpWidget(CieSignApp(startLink: false, workspace: ws));
    await tester.pump();
    expect(find.text('Trascina qui documenti o cartelle'), findsOneWidget);
    expect(find.text('Apri documenti'), findsOneWidget);
    expect(find.text('Apri una cartella'), findsOneWidget);
  });

  test('nomi dei file firmati', () {
    expect(SignWorkflow.signedName('contratto.pdf', SignFormat.pades), 'contratto-signed.pdf');
    expect(SignWorkflow.signedName('contratto.pdf', SignFormat.cades), 'contratto.pdf.p7m');
  });

  testWidgets('firma parallela su un .p7m esistente', (tester) async {
    await tester.runAsync(() async {
      final pdf = File('test/resources/semplice.pdf').readAsBytesSync();
      final wf = SignWorkflow(TestSigner());
      final first = await wf.run(OpenedDocument('C:\\Doc\\a.pdf', pdf), SignFormat.cades);
      final p7m = OpenedDocument('C:\\Doc\\a.pdf.p7m', first.bytes);
      expect(SignWorkflow.isCosign(p7m, SignFormat.cades), isTrue);
      final second = await wf.run(p7m, SignFormat.cades);
      expect(second.suggestedName, 'a.pdf.p7m');
      final f = CadesFile.open(second.bytes);
      expect(f.content, pdf);
      expect(f.reports, hasLength(2));
      expect(f.reports.every((r) => r.isIntact), isTrue);
    });
  });

  testWidgets('firma di prova PAdES visibile e CAdES', (tester) async {
    await tester.runAsync(() async {
      final pdf = File('test/resources/semplice.pdf').readAsBytesSync();
      final doc = OpenedDocument('C:\\Documenti\\contratto.pdf', pdf);
      expect(doc.kind, DocumentKind.pdf);
      final wf = SignWorkflow(TestSigner());

      final pades = await wf.run(
        doc,
        SignFormat.pades,
        visible: const VisibleSignature(pageIndex: 1, x: 300, y: 60, width: 200, height: 64),
      );
      expect(pades.suggestedName, 'contratto-signed.pdf');
      final r = PadesVerifier.verify(pades.bytes).single;
      expect(r.isIntact, isTrue);
      expect(r.certificate!.holderName, 'PROVA FIRMA DI PROVA');

      final cades = await wf.run(doc, SignFormat.cades);
      final f = CadesFile.open(cades.bytes);
      expect(f.content, pdf);
      expect(f.reports.single.isIntact, isTrue);
    });
  });
}
