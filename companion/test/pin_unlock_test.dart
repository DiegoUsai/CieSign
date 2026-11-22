import 'package:cie_sign_companion/cie_bridge.dart';
import 'package:cie_sign_companion/main.dart';
import 'package:cie_sign_companion/pin_unlock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Pagina minima che usa [PinUnlockMixin] come le pagine di firma.
class _Harness extends StatefulWidget {
  const _Harness(this.bridge);

  final CieBridge bridge;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with PinUnlockMixin {
  String? message;

  @override
  CieBridge get pinBridge => widget.bridge;

  Future<void> _start() async {
    try {
      await widget.bridge.start(pin: takePin());
      message = await rememberPinIfWanted() ?? 'ok';
    } on CieError catch (e) {
      message = vaultErrorText(e) ?? e.message;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(children: [
      pinInput(context, busy: false),
      FilledButton(onPressed: pinReady ? _start : null, child: const Text('Firma')),
      Text(message ?? ''),
    ]),
  );
}

Map<String, Object?> _result() => {
  'certificate': Uint8List(1),
  'subject': 'CN=Prova',
  'issuer': 'CN=CA',
  'serial': '01',
  'notBefore': '01/01/2026 00:00',
  'notAfter': '01/01/2036 00:00',
  'certSha256': Uint8List(32),
  'digest': null,
  'signature': null,
  'signatureValid': null,
  'durationMs': 10,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ciesign/cie');
  late List<MethodCall> calls;
  late Map<String, Object?> status;
  Object? Function(MethodCall)? onStart;

  setUp(() {
    calls = [];
    status = {'availability': 'ready', 'enabled': true, 'saved': false, 'deviceCredential': true};
    onStart = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'vaultStatus':
          return status;
        case 'vaultSave':
          status = {...status, 'saved': true};
          return status;
        case 'start':
          return onStart?.call(call) ?? _result();
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('stato della custodia del PIN', () {
    final s = VaultStatus.fromMap({'availability': 'ready', 'enabled': true, 'saved': true});
    expect(s.canUnlock, isTrue);
    expect(s.canSave, isFalse);
    expect(VaultStatus.fromMap({'availability': 'not_enrolled', 'enabled': true}).canSave, isFalse);
    expect(VaultStatus.fromMap({'availability': 'ready', 'enabled': false}).canSave, isFalse);
    expect(const VaultStatus.unavailable().canUnlock, isFalse);
  });

  testWidgets('con la funzione attiva il PIN digitato si salva dopo la firma riuscita', (tester) async {
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    expect(find.textContaining('ricordare il PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '12345678');
    await tester.pump();
    await tester.tap(find.text('Firma'));
    await tester.pumpAndSettle();
    final start = calls.firstWhere((c) => c.method == 'start');
    expect((start.arguments as Map)['pin'], '12345678');
    final save = calls.firstWhere((c) => c.method == 'vaultSave');
    expect((save.arguments as Map)['pin'], '12345678');
    expect(find.textContaining('PIN salvato: alle prossime'), findsOneWidget);
  });

  testWidgets('con la funzione spenta il PIN non si salva', (tester) async {
    status = {'availability': 'ready', 'enabled': false, 'saved': false};
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    expect(find.textContaining('ricordare il PIN'), findsNothing);
    await tester.enterText(find.byType(TextField), '12345678');
    await tester.pump();
    await tester.tap(find.text('Firma'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'vaultSave'), isEmpty);
  });

  testWidgets('con il PIN salvato si firma senza digitarlo e il PIN non passa da Flutter', (tester) async {
    status = {...status, 'saved': true};
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('PIN salvato sul telefono'), findsOneWidget);
    await tester.tap(find.text('Firma'));
    await tester.pumpAndSettle();
    final args = calls.firstWhere((c) => c.method == 'start').arguments as Map;
    expect(args['savedPin'], isTrue);
    expect(args.containsKey('pin'), isFalse);
    expect(calls.where((c) => c.method == 'vaultSave'), isEmpty);
  });

  testWidgets('si può sempre tornare al PIN digitato', (tester) async {
    status = {...status, 'saved': true};
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inserisci il PIN a mano'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Firma')).onPressed, isNull);
    expect(find.text('Usa il PIN salvato'), findsOneWidget);
  });

  testWidgets('un PIN salvato rifiutato dalla carta fa tornare al PIN digitato', (tester) async {
    status = {...status, 'saved': true};
    onStart = (_) => throw PlatformException(code: 'WRONG_PIN', message: 'PIN errato', details: 2);
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Firma'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ha rifiutato il PIN salvato'), findsOneWidget);
    expect(find.textContaining('Tentativi rimasti: 2'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Usa il PIN salvato'), findsNothing);
  });

  testWidgets('se cambiano le impronte il PIN salvato è cancellato', (tester) async {
    status = {...status, 'saved': true};
    onStart = (_) => throw PlatformException(code: 'VAULT_INVALIDATED', message: 'cambiate');
    await tester.pumpWidget(CieSignCompanionApp(home: _Harness(CieBridge())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Firma'));
    await tester.pumpAndSettle();
    expect(find.textContaining('sono cambiati'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('le impostazioni chiedono conferma prima di attivare', (tester) async {
    status = {'availability': 'ready', 'enabled': false, 'saved': false};
    await tester.pumpWidget(CieSignCompanionApp(home: PinUnlockSettingsPage(bridge: CieBridge())));
    await tester.pumpAndSettle();
    expect(find.text('Disattivato'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Ricordare il PIN della CIE?'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'vaultSetEnabled'), isEmpty);
  });
}
