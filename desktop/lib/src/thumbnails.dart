import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

/// Colonna delle miniature delle pagine, a sinistra dell'anteprima: si
/// scorre da sola e un clic porta alla pagina. La pagina corrente è evidenziata.
class PageThumbnails extends StatefulWidget {
  const PageThumbnails({
    super.key,
    required this.bytes,
    required this.sourceName,
    required this.currentPage,
    required this.onTap,
  });

  final Uint8List bytes;
  final String sourceName;
  final int currentPage;
  final void Function(int pageNumber) onTap;

  static const width = 128.0;

  @override
  State<PageThumbnails> createState() => _PageThumbnailsState();
}

class _PageThumbnailsState extends State<PageThumbnails> {
  final _scroll = ScrollController();
  static const _itemHeight = 176.0;

  @override
  void didUpdateWidget(PageThumbnails old) {
    super.didUpdateWidget(old);
    if (old.currentPage != widget.currentPage && _scroll.hasClients) {
      // Tiene visibile la miniatura della pagina corrente.
      final top = (widget.currentPage - 1) * _itemHeight;
      final view = _scroll.position.viewportDimension;
      final off = _scroll.offset;
      if (top < off || top + _itemHeight > off + view) {
        _scroll.animateTo(
          (top - view / 2 + _itemHeight / 2).clamp(0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: PageThumbnails.width,
      color: scheme.surfaceContainer,
      child: rx.PdfDocumentViewBuilder(
        documentRef: rx.PdfDocumentRefData(widget.bytes, sourceName: '${widget.sourceName}#miniature'),
        builder: (context, document) {
          if (document == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          final n = document.pages.length;
          return Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView.builder(
              key: const ValueKey('miniature'),
              controller: _scroll,
              itemCount: n,
              itemExtent: _itemHeight,
              itemBuilder: (context, i) {
                final current = i + 1 == widget.currentPage;
                return InkWell(
                  key: ValueKey('miniatura-${i + 1}'),
                  onTap: () => widget.onTap(i + 1),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 18, 4),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: current ? scheme.primary : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                            child: rx.PdfPageView(document: document, pageNumber: i + 1, maximumDpi: 48),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: current ? FontWeight.bold : null,
                            color: current ? scheme.primary : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
