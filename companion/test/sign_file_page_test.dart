import 'dart:io';
import 'dart:typed_data';

import 'package:cie_sign_companion/cie_bridge.dart';
import 'package:cie_sign_companion/local_sign.dart';
import 'package:cie_sign_companion/main.dart';
import 'package:cie_sign_companion/sign_file_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('un file non PDF si firma in CAdES e chiede il PIN', (tester) async {
    final doc = LocalDocument('nota.txt', Uint8List.fromList('ciao'.codeUnits));
    await tester.pumpWidget(CieSignCompanionApp(
      home: SignFilePage(bridge: CieBridge(), store: SignedStore(Directory.systemTemp), initial: doc),
    ));
    expect(find.text('nota.txt'), findsOneWidget);
    expect(find.textContaining('verrà firmato in CAdES'), findsOneWidget);
    expect(find.text('Firma visibile'), findsNothing);
    await tester.tap(find.text('Firma con la CIE'));
    await tester.pumpAndSettle();
    expect(find.text('PIN della CIE (8 cifre)'), findsOneWidget);
    final sign = find.widgetWithText(FilledButton, 'Firma');
    expect(tester.widget<FilledButton>(sign).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '12345678');
    await tester.pump();
    expect(tester.widget<FilledButton>(sign).onPressed, isNotNull);
  });
}
