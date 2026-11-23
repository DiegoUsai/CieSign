import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'colors.dart';
import 'logo.dart';

/// Durata totale dello splash animato.
const splashDuration = Duration(milliseconds: 1800);

/// Splash screen animato: il telefono-penna tocca la carta, partono le onde
/// NFC, il pennino traccia una firma e compaiono nome e frase.
///
/// La scena è disegnata in un riquadro di 300 × 533 adattato allo spazio
/// disponibile, sopra una sfumatura rossa che riempie tutto lo schermo.
/// Con "riduci movimento" attivo nel sistema mostra subito l'ultimo fotogramma.
class FirmamiSplash extends StatefulWidget {
  const FirmamiSplash({super.key, this.onFinished, this.fontFamily});

  /// Carattere di nome e frase; nullo usa quello di sistema.
  final String? fontFamily;

  /// Chiamata quando l'animazione è finita.
  final VoidCallback? onFinished;

  @override
  State<FirmamiSplash> createState() => _FirmamiSplashState();
}

class _FirmamiSplashState extends State<FirmamiSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: splashDuration);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = 1;
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted) widget.onFinished?.call();
      });
    } else {
      _c.forward().whenComplete(() {
        if (mounted) widget.onFinished?.call();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${FirmamiColors.appName}. ${FirmamiColors.tagline}',
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.4, -0.8),
            radius: 1.3,
            colors: [FirmamiColors.coral, FirmamiColors.red, FirmamiColors.redDeep],
            stops: [0, 0.45, 1],
          ),
        ),
        child: SizedBox.expand(
          child: FittedBox(
            child: SizedBox(
              width: 300,
              height: 533,
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => CustomPaint(painter: SplashPainter(_c.value, fontFamily: widget.fontFamily)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Disegna un fotogramma dello splash; [t] va da 0 a 1 sull'intera durata.
class SplashPainter extends CustomPainter {
  SplashPainter(this.t, {this.fontFamily});
  final double t;
  final String? fontFamily;

  static const _white = Color(0xFFFFFFFF);
  static const _contact = Offset(120, 300);

  double get _ms => t * splashDuration.inMilliseconds;

  /// Avanzamento da 0 a 1 di una fase che inizia a [start] ms e dura [length] ms.
  double _phase(double start, double length) => ((_ms - start) / length).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    _card(canvas);
    for (final delay in const [500.0, 620.0, 740.0]) {
      _ring(canvas, _phase(delay, 700));
    }
    _signature(canvas);
    _pen(canvas);
    _text(canvas, FirmamiColors.appName, 462, 38, FontWeight.w800, 1, _phase(1350, 450));
    _text(canvas, FirmamiColors.tagline, 492, 14, FontWeight.w400, 0.85, _phase(1500, 450));
  }

  /// Carta d'identità generica: volutamente non somiglia alla CIE.
  void _card(Canvas canvas) {
    final soft = Paint()..color = _white.withValues(alpha: 0.35);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(60, 300, 180, 112), const Radius.circular(14)),
      Paint()
        ..color = _white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(78, 322, 38, 46), const Radius.circular(6)), soft);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(128, 326, 90, 8), const Radius.circular(4)), soft);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(128, 344, 64, 8), const Radius.circular(4)), soft);
  }

  void _ring(Canvas canvas, double p) {
    if (p <= 0 || p >= 1) return;
    final alpha = p < 0.1 ? p / 0.1 * 0.9 : 0.9 * (1 - (p - 0.1) / 0.9);
    final r = 6 + 64 * Curves.easeOut.transform(p);
    canvas.drawCircle(
      _contact,
      r,
      Paint()
        ..color = _white.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  /// Firma che parte dal punto di contatto, in coordinate della scena.
  static final Path _signaturePath = Path()
    ..moveTo(120, 300)
    ..cubicTo(134, 278, 146, 308, 158, 294)
    ..cubicTo(170, 280, 174, 268, 184, 284)
    ..cubicTo(194, 300, 180, 306, 192, 302)
    ..cubicTo(204, 298, 210, 282, 226, 288);

  static final ui.PathMetric _metric = _signaturePath.computeMetrics().first;

  double get _writing => Curves.easeInOut.transform(_phase(850, 700));

  void _signature(Canvas canvas) {
    final p = _writing;
    if (p <= 0) return;
    canvas.drawPath(
      _metric.extractPath(0, _metric.length * p),
      Paint()
        ..color = _white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _pen(Canvas canvas) {
    // Entrata dall'alto (0-450 ms), tocco con piccolo rimbalzo (450-760 ms),
    // poi la punta segue la firma mentre viene tracciata.
    final enter = Curves.easeOutCubic.transform(_phase(0, 450));
    var dx = 60 * (1 - enter);
    var dy = -260 * (1 - enter);
    final tap = _phase(450, 310);
    if (tap > 0 && tap < 1) dy += 8 * math.sin(tap * math.pi);
    final writing = _writing;
    if (writing > 0) {
      final at = _metric.getTangentForOffset(_metric.length * writing)!.position;
      dx += at.dx - _contact.dx;
      dy += at.dy - _contact.dy;
    }
    final opacity = _phase(0, 300);
    if (opacity <= 0) return;

    canvas.saveLayer(null, Paint()..color = _white.withValues(alpha: opacity));
    canvas.translate(dx, dy);
    // La punta del pennino tocca la carta nel punto di contatto.
    canvas.translate(_contact.dx, _contact.dy);
    canvas.rotate(PhonePen.angle);
    canvas.translate(-PhonePen.tip.dx, -PhonePen.tip.dy);
    PhonePen.paint(canvas, _white, FirmamiColors.red);
    canvas.restore();
  }

  void _text(Canvas canvas, String text, double y, double size, FontWeight weight, double alpha, double p) {
    if (p <= 0) return;
    final eased = Curves.easeOut.transform(p);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: _white.withValues(alpha: alpha * eased),
          fontSize: size,
          fontWeight: weight,
          fontFamily: fontFamily,
          letterSpacing: size > 20 ? -0.5 : 0,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 300);
    tp.paint(canvas, Offset(150 - tp.width / 2, y - tp.height + 8 * (1 - eased)));
  }

  @override
  bool shouldRepaint(SplashPainter old) => old.t != t;
}

/// Mostra lo splash sopra [child] e poi lo dissolve. [child] viene costruito
/// subito, così l'app si prepara (rete, archivio) mentre gira l'animazione.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// Falso nei test, per partire direttamente dalla pagina.
  final bool enabled;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  late bool _showing = widget.enabled;
  late bool _gone = !widget.enabled;

  @override
  Widget build(BuildContext context) {
    // La pagina resta sempre il primo figlio dello Stack, così il suo stato
    // non si perde quando lo splash se ne va.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_gone)
          const SizedBox.shrink()
        else
          IgnorePointer(
            ignoring: !_showing,
            child: AnimatedOpacity(
              opacity: _showing ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              onEnd: () => setState(() => _gone = true),
              child: FirmamiSplash(onFinished: () => setState(() => _showing = false)),
            ),
          ),
      ],
    );
  }
}
