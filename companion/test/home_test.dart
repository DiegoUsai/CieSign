import 'package:cie_sign_companion/cie_bridge.dart';
import 'package:cie_sign_companion/main.dart';
import 'package:cie_sign_companion/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('la home ha una sola azione principale e le icone in alto', (tester) async {
    await tester.pumpWidget(const CieSignCompanionApp());
    await tester.pump();
    expect(find.text('Apri un documento'), findsOneWidget);
    expect(find.byTooltip('Recenti'), findsOneWidget);
    expect(find.byTooltip('Impostazioni'), findsOneWidget);
    expect(find.text('Sblocco del PIN'), findsNothing);
  });

  testWidgets('le impostazioni raccolgono PC, sblocco del PIN e prova della carta', (tester) async {
    await tester.pumpWidget(CieSignCompanionApp(
      home: SettingsPage(bridge: CieBridge(), link: null, onScan: () {}, openPrototype: () {}, buildId: 'test'),
    ));
    expect(find.text('Collegamento al PC'), findsOneWidget);
    expect(find.text('Sblocco del PIN'), findsOneWidget);
    expect(find.text('Prova la carta'), findsOneWidget);
    expect(find.text('Build test'), findsOneWidget);
  });
}
