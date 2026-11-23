import 'dart:io';

import 'package:cie_sign_desktop/src/signature_box.dart';
import 'package:cie_sign_desktop/src/verification_panel.dart';
import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _res = '../packages/ciesign_ades/test/resources';

void main() {
  group('riquadro della firma', () {
    const page = Size(595, 842);

    test('centrato sul clic e tenuto dentro la pagina', () {
      final b = SignatureBoxGeometry.centeredAt(const Offset(5, 5), pageIndex: 0, page: page);
      expect(b.x, 0);
      expect(b.y, page.height - SignatureBoxGeometry.defaultHeight);
      expect(b.width, SignatureBoxGeometry.defaultWidth);
    });

    test('conversione tra coordinate dello schermo e del PDF', () {
      const r = Rect.fromLTWH(100, 200, 180, 50);
      final b = SignatureBoxGeometry.fromTopLeft(r, pageIndex: 2, page: page);
      expect(b.y, 842 - 250);
      expect(SignatureBoxGeometry.toTopLeft(b, page), r);
    });

    test('spostamento limitato ai bordi della pagina', () {
      const r = Rect.fromLTWH(500, 10, 80, 40);
      final m = SignatureBoxGeometry.move(r, const Offset(100, -50), page);
      expect(m, const Rect.fromLTWH(515, 0, 80, 40));
    });

    test('ridimensionamento dagli angoli con misura minima', () {
      const r = Rect.fromLTWH(100, 100, 200, 64);
      final big = SignatureBoxGeometry.resize(r, Alignment.bottomRight, const Offset(40, 20), page);
      expect(big, const Rect.fromLTRB(100, 100, 340, 184));
      final small = SignatureBoxGeometry.resize(r, Alignment.topLeft, const Offset(500, 500), page);
      expect(small.width, SignatureBoxGeometry.minWidth);
      expect(small.height, SignatureBoxGeometry.minHeight);
      expect(small.bottomRight, r.bottomRight);
    });

    test('il corpo del testo segue quello del PDF firmato', () {
      const lines = ['Firmato con CIE da', 'Nome Cognome', 'il gg/mm/aaaa alle hh:mm', 'Firma elettronica avanzata'];
      expect(SignatureBoxGeometry.fontSize(200, 64, lines), closeTo(11.2, 0.5));
      expect(SignatureBoxGeometry.fontSize(400, 200, lines), 11);
      expect(SignatureBoxGeometry.fontSize(100, 32, lines), lessThan(6));
    });
  });

  group('verifica', () {
    final pdf = File('$_res/pades-t-doctimestamp.pdf').readAsBytesSync();
    final reports = PadesVerifier.verify(pdf);
    final evals = [for (final r in reports) SignatureEvaluation(r, pades: true)];

    test('esito complessivo e rapporto', () {
      expect(overallText(const []), 'Il documento non contiene firme');
      expect(overallText(evals), '1 firma e 1 marca temporale del documento, tutte valide');
      final text = verificationReportText('contratto.pdf', evals);
      expect(text, contains('Titolare: MARIO ROSSI'));
      expect(text, contains('Valore della firma: Certificato di CIE Sign test, non CIE'));
      expect(text, contains('Codice fiscale: RSSMRA80A01H501U'));
      expect(text, contains('TSA di prova CIE Sign'));
      expect(text, contains('Marca temporale del documento (PAdES, DocTimeStamp)'));
    });

    testWidgets('pannello e dettaglio della firma', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VerificationPanel(evaluations: evals, documentName: 'contratto.pdf'),
            ),
          ),
        ),
      );
      expect(find.text('1 firma e 1 marca temporale del documento, tutte valide'), findsOneWidget);
      expect(find.text('MARIO ROSSI'), findsOneWidget);
      expect(find.text('VALIDA'), findsNWidgets(2));
      // I dettagli non sono la prima informazione: compaiono aprendo la firma.
      expect(find.text('Mostra certificato'), findsNothing);
      await tester.tap(find.text('MARIO ROSSI'));
      await tester.pumpAndSettle();
      expect(find.text('Firma integra'), findsOneWidget);
      await tester.tap(find.text('Mostra certificato'));
      await tester.pumpAndSettle();
      expect(find.text('Certificato'), findsOneWidget);
      expect(find.text('RSSMRA80A01H501U'), findsOneWidget);
    });
  });
}
