import 'dart:math' as math;

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Misure del riquadro della firma visibile, in punti PDF.
class SignatureBoxGeometry {
  static const defaultWidth = 200.0, defaultHeight = 64.0;
  static const minWidth = 90.0, minHeight = 30.0;

  /// Riquadro centrato sul punto [center] (coordinate della pagina con y verso
  /// il basso, in punti), della misura indicata e tenuto dentro la pagina.
  static VisibleSignature centeredAt(
    Offset center, {
    required int pageIndex,
    required Size page,
    double width = defaultWidth,
    double height = defaultHeight,
  }) {
    final w = math.min(width, page.width), h = math.min(height, page.height);
    final left = (center.dx - w / 2).clamp(0.0, page.width - w);
    final top = (center.dy - h / 2).clamp(0.0, page.height - h);
    return fromTopLeft(Rect.fromLTWH(left, top, w, h), pageIndex: pageIndex, page: page);
  }

  /// Rettangolo con y verso il basso, comodo per l'interfaccia.
  static Rect toTopLeft(VisibleSignature b, Size page) =>
      Rect.fromLTWH(b.x, page.height - b.y - b.height, b.width, b.height);

  /// Da rettangolo con y verso il basso a coordinate PDF (origine in basso a sinistra).
  static VisibleSignature fromTopLeft(Rect r, {required int pageIndex, required Size page}) =>
      VisibleSignature(pageIndex: pageIndex, x: r.left, y: page.height - r.bottom, width: r.width, height: r.height);

  /// Sposta il riquadro di [delta] punti senza farlo uscire dalla pagina.
  static Rect move(Rect r, Offset delta, Size page) {
    final left = (r.left + delta.dx).clamp(0.0, page.width - r.width);
    final top = (r.top + delta.dy).clamp(0.0, page.height - r.height);
    return Rect.fromLTWH(left, top, r.width, r.height);
  }

  /// Trascina l'angolo [corner] di [delta] punti: il lato opposto resta fermo,
  /// la misura non scende sotto il minimo e il riquadro resta nella pagina.
  static Rect resize(Rect r, Alignment corner, Offset delta, Size page) {
    var left = r.left, top = r.top, right = r.right, bottom = r.bottom;
    if (corner.x < 0) {
      left = (left + delta.dx).clamp(0.0, right - minWidth);
    } else {
      right = (right + delta.dx).clamp(left + minWidth, page.width);
    }
    if (corner.y < 0) {
      top = (top + delta.dy).clamp(0.0, bottom - minHeight);
    } else {
      bottom = (bottom + delta.dy).clamp(top + minHeight, page.height);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Corpo del testo in punti, calcolato come nel flusso di aspetto generato
  /// da PadesPreparation, così l'anteprima corrisponde al PDF firmato.
  static double fontSize(double w, double h, List<String> lines) {
    const pad = 4.0;
    var size = (h - 2 * pad) / (lines.length * 1.25);
    final longest = lines.fold(0, (a, l) => l.length > a ? l.length : a);
    if (longest > 0) size = [size, (w - 2 * pad) / (longest * 0.55), 11.0].reduce(math.min);
    return math.max(size, 1);
  }
}

/// Riquadro della firma sopra la pagina: si trascina per spostarlo e si
/// ridimensiona dagli angoli. Lavora in punti PDF; [scale] converte in pixel.
class SignatureBoxEditor extends StatelessWidget {
  const SignatureBoxEditor({
    super.key,
    required this.rect,
    required this.scale,
    required this.lines,
    required this.onChanged,
    this.onPointerSignal,
  });

  /// Riquadro in punti, con y verso il basso.
  final Rect rect;
  final double scale;
  final List<String> lines;

  /// Nuovo riquadro dopo uno spostamento ([corner] nullo) o un ridimensionamento.
  final void Function(Offset deltaPoints, Alignment? corner) onChanged;

  /// La rotellina sopra il riquadro continua a far scorrere il documento.
  final void Function(PointerSignalEvent)? onPointerSignal;

  static const _handle = 12.0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final font = SignatureBoxGeometry.fontSize(rect.width, rect.height, lines) * scale;
    Widget handle(Alignment a, MouseCursor cursor) => Align(
      alignment: a,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          key: ValueKey('maniglia-${a.x}-${a.y}'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onChanged(d.delta / scale, a),
          child: Container(
            width: _handle,
            height: _handle,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: primary, width: 1.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );

    return Listener(
      onPointerSignal: onPointerSignal,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                key: const ValueKey('riquadro-firma'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onChanged(d.delta / scale, null),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0x220066CC),
                    border: Border.all(color: const Color(0xFF0066CC), width: 1.5),
                  ),
                  padding: EdgeInsets.all(4 * scale),
                  alignment: Alignment.topLeft,
                  child: ClipRect(
                    child: Text(
                      lines.join('\n'),
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontFamily: 'Helvetica',
                        fontFamilyFallback: const ['Arial', 'Liberation Sans'],
                        fontSize: font,
                        color: Colors.grey.shade900,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final (a, c) in const [
            (Alignment.topLeft, SystemMouseCursors.resizeUpLeft),
            (Alignment.topRight, SystemMouseCursors.resizeUpRight),
            (Alignment.bottomLeft, SystemMouseCursors.resizeDownLeft),
            (Alignment.bottomRight, SystemMouseCursors.resizeDownRight),
          ])
            Positioned(
              left: -_handle / 2,
              top: -_handle / 2,
              right: -_handle / 2,
              bottom: -_handle / 2,
              child: handle(a, c),
            ),
        ],
      ),
    );
  }
}
