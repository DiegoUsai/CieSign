import 'dart:io';

import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:material_ui/material_ui.dart';

import 'document_list.dart';
import 'verification_panel.dart';

/// Recenti: documenti firmati e verificati, con filtro per tipo.
class RecentsList extends StatefulWidget {
  const RecentsList({super.key, required this.store, required this.onOpen, this.limit, this.shrinkWrap = false});

  final MarkStore store;
  final void Function(String path) onOpen;
  final int? limit;
  final bool shrinkWrap;

  @override
  State<RecentsList> createState() => _RecentsListState();
}

class _RecentsListState extends State<RecentsList> {
  ActivityKind? _filter;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: widget.store.changes,
      builder: (context, _) {
        final all = widget.store.recents(kind: _filter);
        final items = widget.limit == null ? all : all.take(widget.limit!).toList();
        return Column(
          mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<ActivityKind?>(
              segments: const [
                ButtonSegment(value: null, label: Text('Tutti')),
                ButtonSegment(value: ActivityKind.signed, label: Text('Firmati'), icon: Icon(Icons.draw_outlined)),
                ButtonSegment(value: ActivityKind.verified, label: Text('Verificati'), icon: Icon(Icons.fact_check_outlined)),
              ],
              selected: {_filter},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Nessun documento finora.'))
            else
              Flexible(
                fit: widget.shrinkWrap ? FlexFit.loose : FlexFit.tight,
                child: ListView.builder(
                  shrinkWrap: widget.shrinkWrap,
                  itemCount: items.length,
                  itemBuilder: (context, i) => _tile(context, items[i]),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, Activity a) {
    final path = a.path;
    final exists = path != null && File(path).existsSync();
    final signed = a.kind == ActivityKind.signed;
    return ListTile(
      leading: Icon(
        signed ? Icons.draw_outlined : outcomeIcon(a.outcome),
        color: signed ? null : outcomeColor(a.outcome),
      ),
      title: Text(a.name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkChip(icon: signed ? Icons.draw_outlined : Icons.fact_check_outlined, label: signed ? 'Firmato' : 'Verificato', at: a.at),
          Text(
            [
              if (signed) '${a.format ?? ''}, ${a.holder ?? ''}${a.test ? ' (firma di prova)' : ''}' else ?a.summary,
              if (path != null) exists ? File(path).parent.path : 'File non più presente in ${File(path).parent.path}',
            ].join('\n'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      isThreeLine: true,
      enabled: exists,
      onTap: exists ? () => widget.onOpen(path) : null,
      trailing: IconButton(
        tooltip: 'Togli dall\'elenco',
        icon: const Icon(Icons.close),
        onPressed: () => widget.store.removeActivity(a),
      ),
    );
  }
}

Future<void> showRecents(BuildContext context, MarkStore store, void Function(String path) onOpen) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Recenti'),
      content: SizedBox(
        width: 680,
        height: 520,
        child: RecentsList(
          store: store,
          onOpen: (p) {
            Navigator.pop(context);
            onOpen(p);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: store.recents().isEmpty ? null : store.clearRecents, child: const Text('Svuota l\'elenco')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
      ],
    ),
  );
}
