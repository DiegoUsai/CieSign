import 'dart:io';

import 'package:cie_sign_desktop/main.dart';
import 'package:cie_sign_desktop/src/sign_workflow.dart';
import 'package:cie_sign_desktop/src/signers.dart';
import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('la schermata iniziale invita ad aprire un documento', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CieSignApp(startLink: false));
    expect(find.text('Trascina qui un documento'), findsOneWidget);
    expect(find.text('Apri documento'), findsOneWidget);
  });

  test('nomi dei file firmati', () {
    expect(SignWorkflow.signedName('contratto.pdf', SignFormat.pades), 'contratto-signed.pdf');
    expect(SignWorkflow.signedName('contratto.pdf', SignFormat.cades), 'contratto.pdf.p7m');
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
