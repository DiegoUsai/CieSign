import 'package:firmami_brand/firmami_brand.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: const MediaQueryData(size: Size(400, 800)), child: child),
    );

void main() {
  testWidgets('lo splash finisce e lascia la pagina senza ricrearla', (tester) async {
    var inits = 0;
    await tester.pumpWidget(_host(SplashGate(child: _Counter(onInit: () => inits++))));
    expect(find.byType(FirmamiSplash), findsOneWidget);
    await tester.pump(splashDuration);
    await tester.pumpAndSettle();
    expect(find.byType(FirmamiSplash), findsNothing);
    expect(find.text('pagina'), findsOneWidget);
    expect(inits, 1);
  });

  testWidgets('disattivato parte direttamente dalla pagina', (tester) async {
    await tester.pumpWidget(_host(SplashGate(enabled: false, child: _Counter(onInit: () {}))));
    expect(find.byType(FirmamiSplash), findsNothing);
  });

  testWidgets('con riduci movimento mostra subito il fotogramma finale', (tester) async {
    var done = false;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800), disableAnimations: true),
        child: FirmamiSplash(onFinished: () => done = true),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 800));
    expect(done, isTrue);
  });

  testWidgets('il logo si disegna', (tester) async {
    await tester.pumpWidget(_host(const Center(child: FirmamiLogo(size: 64))));
    expect(find.byType(FirmamiLogo), findsOneWidget);
  });
}

class _Counter extends StatefulWidget {
  const _Counter({required this.onInit});
  final VoidCallback onInit;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const Text('pagina');
}
