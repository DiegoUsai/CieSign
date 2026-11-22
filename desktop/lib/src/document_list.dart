import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:material_ui/material_ui.dart';

import 'verification_panel.dart';
import 'workspace.dart';

/// Marcatura con il momento in cui è avvenuta: "Visto adesso", "Verificato
/// ieri alle 18:03". Il colore dice se è di questa sessione, di oggi o di prima.
class MarkChip extends StatelessWidget {
  const MarkChip({super.key, required this.icon, required this.label, required this.at, this.color});

  final IconData icon;
  final String label;
  final DateTime at;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fresh = freshnessOf(at);
    final c =
        color ??
        switch (fresh) {
          Freshness.now => scheme.primary,
          Freshness.today => scheme.onSurfaceVariant,
          Freshness.earlier => scheme.outline,
        };
    return Tooltip(
      message: '$label ${formatDate(at)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              '$label ${relativeTime(at)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: c, fontWeight: fresh == Freshness.now ? FontWeight.w600 : null),
            ),
          ),
        ],
      ),
    );
  }
}

/// Elenco dei documenti del fascicolo, a sinistra: si scorre tra i documenti
/// e per ciascuno si vede esito e marcature (visto, verificato, firmato).
class DocumentList extends StatelessWidget {
  const DocumentList({super.key, required this.ws});

  final Workspace ws;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final items = ws.set.items;
    final verified = items.where((i) => ws.set.marksOf(i)?.verifiedAt != null).length;
    final signed = items.where((i) => ws.set.marksOf(i)?.signedAt != null).length;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Documenti (${items.length})', style: t.titleSmall)),
                TextButton(
                  key: const ValueKey('svuota'),
                  onPressed: items.isEmpty ? null : ws.clear,
                  child: const Text('Svuota'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text('$verified verificati, $signed firmati', style: t.bodySmall),
          ),
          if (ws.progress != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LinearProgressIndicator(
                value: ws.progress!.$2 == 0 ? null : ws.progress!.$1 / ws.progress!.$2,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _row(context, items[i], i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, DocItem it, int i) {
    final t = Theme.of(context).textTheme;
    final m = ws.set.marksOf(it);
    final selected = i == ws.set.selectedIndex;
    final outcome = it.outcome ?? m?.verifiedOutcome;
    final loading = it.status == DocStatus.loading || it.checkingRevocation;
    final summary = it.summary ?? m?.verifiedSummary;
    final viewedAt = [
      m?.viewedAt,
      ...?m?.files.values.map((f) => f.viewedAt),
    ].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    return Material(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        key: ValueKey('documento-$i'),
        onTap: () => ws.select(i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : it.status == DocStatus.error
                    ? Icon(Icons.error_outline, size: 20, color: Colors.red.shade700)
                    : outcome == null && summary == null
                    ? Icon(_kindIcon(it.name), size: 20)
                    : Icon(outcomeIcon(outcome), size: 20, color: outcomeColor(outcome)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      it.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(fontWeight: selected ? FontWeight.w600 : null),
                    ),
                    if (it.status == DocStatus.error)
                      Text(it.error ?? 'Non leggibile', style: t.bodySmall?.copyWith(color: Colors.red.shade700), maxLines: 2)
                    else if (summary != null)
                      Text(summary, style: t.bodySmall?.copyWith(color: outcomeColor(outcome)), maxLines: 2),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        if (viewedAt != null) MarkChip(icon: Icons.visibility_outlined, label: 'Visto', at: viewedAt),
                        if (m?.verifiedAt != null)
                          MarkChip(icon: Icons.fact_check_outlined, label: 'Verificato', at: m!.verifiedAt!),
                        if (m?.signedAt != null) MarkChip(icon: Icons.draw_outlined, label: 'Firmato', at: m!.signedAt!),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Togli dall\'elenco',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => ws.remove(it),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _kindIcon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.p7m') || n.endsWith('.p7s')) return Icons.lock_outline;
    if (n.endsWith('.zip')) return Icons.folder_zip_outlined;
    return Icons.description_outlined;
  }
}

/// Icona di un file contenuto, secondo il tipo.
IconData kindIcon(ContentKind k) => switch (k) {
  ContentKind.pdf => Icons.picture_as_pdf_outlined,
  ContentKind.p7m => Icons.lock_outline,
  ContentKind.zip => Icons.folder_zip_outlined,
  ContentKind.image => Icons.image_outlined,
  ContentKind.xml => Icons.code,
  ContentKind.text => Icons.notes,
  ContentKind.other => Icons.insert_drive_file_outlined,
};
