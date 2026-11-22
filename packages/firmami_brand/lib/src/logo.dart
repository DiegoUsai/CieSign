import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'colors.dart';

/// Disegno del telefono a forma di penna, in coordinate 120 × 120.
///
/// Il corpo del telefono si assottiglia in un pennino; lo schermo sta al
/// posto dell'impugnatura. La figura è inclinata di 35 gradi, come una
/// penna in mano, con la punta in basso a sinistra (circa 37, 93).
abstract final class PhonePen {
  static const angle = 35 * math.pi / 180;

  /// Punta del pennino prima della rotazione.
  static const tip = Offset(60, 102);

  static Path body() => Path()
    ..moveTo(52, 8)
    ..lineTo(68, 8)
    ..arcToPoint(const Offset(77, 17), radius: const Radius.circular(9))
    ..lineTo(77, 67)
    ..lineTo(60, 102)
    ..lineTo(43, 67)
    ..lineTo(43, 17)
    ..arcToPoint(const Offset(52, 8), radius: const Radius.circular(9))
    ..close();

  /// Disegna il telefono-penna non ruotato: [ink] è il colore del corpo,
  /// [cut] quello di schermo, foro e taglio del pennino.
  static void paint(Canvas canvas, Color ink, Color cut) {
    canvas.drawPath(body(), Paint()..color = ink);
    final c = Paint()..color = cut;
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(49, 16, 22, 40), const Radius.circular(4)),
      c,
    );
    canvas.drawCircle(const Offset(60, 76), 3.2, c);
    canvas.drawLine(
      const Offset(60, 80),
      const Offset(60, 98),
      Paint()
        ..color = cut
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Firma corta che esce dal pennino nella variante A del logo.
  static Path signature() => Path()
    ..moveTo(38, 92)
    ..cubicTo(46, 82, 52, 96, 60, 89)
    ..cubicTo(68, 82, 70, 77, 76, 85)
    ..cubicTo(82, 93, 84, 89, 92, 81);
}

/// Logo di Firmami, variante A: telefono-penna bianco su quadrato rosso
/// con la firma. Con [plain] il quadrato non si disegna.
class FirmamiLogo extends StatelessWidget {
  const FirmamiLogo({super.key, this.size = 96, this.plain = false});

  final double size;
  final bool plain;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Logo di ${FirmamiColors.appName}',
        child: CustomPaint(size: Size.square(size), painter: _LogoPainter(plain)),
      );
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.plain);
  final bool plain;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 120;
    canvas.scale(s);
    const white = Color(0xFFFFFFFF);
    if (!plain) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 120, 120), const Radius.circular(28)),
        Paint()..color = FirmamiColors.red,
      );
    }
    final ink = plain ? FirmamiColors.red : white;
    final cut = plain ? white : FirmamiColors.red;
    canvas.save();
    canvas.translate(60, 60);
    canvas.rotate(PhonePen.angle);
    canvas.translate(-60, -60);
    PhonePen.paint(canvas, ink, cut);
    canvas.restore();
    canvas.drawPath(
      PhonePen.signature(),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.plain != plain;
}
