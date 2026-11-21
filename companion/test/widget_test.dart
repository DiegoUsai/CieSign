import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cie_sign_companion/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ciesign/cie'),
      (call) async => call.method == 'nfcStatus' ? {'available': true, 'enabled': true} : null,
    );
  });

  testWidgets('il pulsante si abilita solo con un PIN di 8 cifre', (tester) async {
    await tester.pumpWidget(const CieSignCompanionApp());
    await tester.pumpAndSettle();

    FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.pump();
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '12345678');
    await tester.pump();
    expect(button().onPressed, isNotNull);
  });

  testWidgets('mostra l\'impronta SHA-256 del testo di prova', (tester) async {
    await tester.pumpWidget(const CieSignCompanionApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'abc');
    await tester.pump();
    expect(
      find.textContaining('BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'),
      findsOneWidget,
    );
  });
}
