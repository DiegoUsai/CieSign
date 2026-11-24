import 'dart:convert';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:ciesign_link/ciesign_link.dart' show SignFormat;
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;
import 'package:share_plus/share_plus.dart';

import 'cie_bridge.dart';
import 'local_sign.dart';
import 'sign_file_page.dart';
import 'workspace.dart';

Color outcomeColor(Outcome? o, ThemeData theme) => switch (o) {
  Outcome.valid => Colors.green.shade700,
  Outcome.warning => Colors.orange.shade800,
  Outcome.invalid => theme.colorScheme.error,
  null => theme.colorScheme.outline,
};

IconData outcomeIcon(Outcome? o) => switch (o) {
  Outcome.valid => Icons.verified,
  Outcome.warning => Icons.error_outline,
  Outcome.invalid => Icons.cancel,
  null => Icons.description_outlined,
};

/// Riga delle marcature di un documento: "Visto adesso · Verificato ieri alle 10:12 · Firmato oggi alle 9:30".
String marksLine(DocumentMarks? m) {
  if (m == null) return 'Non ancora visto';
  final viewed = [m.viewedAt, ...m.files.values.map((f) => f.viewedAt)].whereType<DateTime>().fold<DateTime?>(
    null,
    (a, b) => a == null || b.isAfter(a) ? b : a,
  );
  return [
    viewed == null ? 'Non ancora visto' : 'Visto ${relativeTime(viewed)}',
    if (m.verifiedAt != null) 'Verificato ${relativeTime(m.verifiedAt!)}',
    if (m.signedAt != null) 'Firmato ${relativeTime(m.signedAt!)}',
  ].join(' · ');
}

/// Scelta della data di verifica, condivisa da documento e fascicolo.
Future<void> pickReference(BuildContext context, MobileWorkspace ws) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: ws.reference ?? now,
    firstDate: DateTime(2000),
    lastDate: now,
    helpText: 'Verifica le firme a questa data',
  );
  if (d != null) ws.reference = DateTime(d.year, d.month, d.day, 23, 59, 59);
}

/// Pagina di un documento: anteprima, esito delle firme in alto, dettagli a
/// richiesta, file contenuti nelle buste con la marcatura "visto", e firma.
class DocumentPage extends StatefulWidget {
  const DocumentPage({super.key, required this.ws, required this.bridge, required this.signedStore, this.onCertificate});

  final MobileWorkspace ws;
  final CieBridge bridge;
  final SignedStore signedStore;
  final void Function(Uint8List)? onCertificate;

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  ContainedFile? _viewing;
  DocItem? _for;
  bool _details = false;

  MobileWorkspace get ws => widget.ws;

  ContainedFile? _current(DocItem item) {
    final t = item.tree;
    if (t == null) return null;
    if (_for != item || _viewing == null) {
      _for = item;
      _viewing = MobileWorkspace.defaultView(t);
      _details = false;
      final v = _viewing!;
      WidgetsBinding.instance.addPostFrameCallback((_) => ws.viewed(item, v));
    }
    return _viewing;
  }

  void _show(DocItem item, ContainedFile f) {
    if (f.kind.hasPreview) {
      setState(() => _viewing = f);
      ws.viewed(item, f);
    } else {
      _openExternal(item, f);
    }
  }

  Future<void> _openExternal(DocItem item, ContainedFile f) async {
    final err = await ws.openExternal(item, f);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _share(DocItem item) async {
    final path = item.source.id;
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  Future<void> _report(DocItem item) async {
    final f = await ws.report(only: item);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'Rapporto di verifica di ${item.name}'));
  }

  Future<void> _sign(DocItem item) async {
    final bytes = item.bytes;
    if (bytes == null) return;
    final unviewed = ws.set.unviewedFiles(item);
    final total = item.tree?.readableFiles.length ?? 0;
    if (unviewed.isNotEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Ci sono file non visualizzati'),
          content: Text(
            '${unviewed.length == 1 ? '1 file' : '${unviewed.length} file'} su $total non '
            '${unviewed.length == 1 ? 'è stato aperto' : 'sono stati aperti'}:\n'
            '${unviewed.take(5).map((f) => '• ${f.name}').join('\n')}${unviewed.length > 5 ? '\n…' : ''}\n\n'
            'Prima di firmare è bene leggere tutto. Vuoi firmare comunque?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Rivedi')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Firma comunque')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SignFilePage(
          bridge: widget.bridge,
          store: widget.signedStore,
          onCertificate: widget.onCertificate,
          initial: LocalDocument(item.name, bytes),
          onSigned: (file, out, holder, format) =>
              ws.signed(item, file, out, format: format == SignFormat.pades ? 'PAdES' : 'CAdES', holder: holder),
        ),
      ),
    );
    if (mounted) setState(() => _viewing = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final item = ws.selected;
        final theme = Theme.of(context);
        if (item == null) return const Scaffold(body: Center(child: Text('Nessun documento')));
        final count = ws.set.items.length;
        final index = ws.set.selectedIndex;
        return Scaffold(
          appBar: AppBar(
            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: 'Verifica a una data',
                onPressed: () => pickReference(context, ws),
                icon: const Icon(Icons.event),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'report') _report(item);
                  if (v == 'share') _share(item);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'report', child: Text('Rapporto di verifica (PDF)')),
                  PopupMenuItem(value: 'share', child: Text('Condividi il documento')),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: switch (item.status) {
              DocStatus.error => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('File non leggibile: ${item.error}'))),
              DocStatus.ready when item.tree != null => _body(item, theme),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  if (count > 1) ...[
                    IconButton(
                      tooltip: 'Documento precedente',
                      onPressed: index > 0 ? () => ws.select(index - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${index + 1} di $count'),
                    IconButton(
                      tooltip: 'Documento successivo',
                      onPressed: index < count - 1 ? () => ws.select(index + 1) : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: item.tree == null ? null : () => _sign(item),
                      icon: const Icon(Icons.draw_outlined),
                      label: Text(item.tree?.kind == ContentKind.p7m ? 'Aggiungi la firma' : 'Firma'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(DocItem item, ThemeData theme) {
    final tree = item.tree!;
    final viewing = _current(item);
    final evals = item.evaluationsAt(ws.reference);
    final files = tree.readableFiles;
    final marks = ws.set.marksOf(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _banner(item, evals, theme),
        if (_details) Flexible(child: _signatureList(evals, theme)),
        if (files.length > 1 || tree.isContainer) _filesStrip(item, files, viewing, marks, theme),
        if (!_details && viewing != null) Expanded(child: _preview(item, viewing, theme)),
      ],
    );
  }

  Widget _banner(DocItem item, List<SignatureEvaluation> evals, ThemeData theme) {
    final worst = evals.isEmpty ? null : worstOutcome(evals);
    final color = outcomeColor(worst, theme);
    final firstProblem = evals.where((e) => e.outcome != Outcome.valid).firstOrNull;
    return Material(
      color: color.withValues(alpha: 0.12),
      child: InkWell(
        onTap: evals.isEmpty ? null : () => setState(() => _details = !_details),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(outcomeIcon(worst), color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(overallText(evals), style: theme.textTheme.titleSmall?.copyWith(color: color)),
                    if (firstProblem?.reason != null) Text(firstProblem!.reason!, style: theme.textTheme.bodySmall),
                    if (ws.reference != null)
                      Text('Verifica al ${formatDay(ws.reference!)}', style: theme.textTheme.bodySmall),
                    if (item.checkingRevocation)
                      Text('Controllo della revoca dei certificati…', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (ws.reference != null)
                IconButton(
                  tooltip: 'Torna alla verifica a oggi',
                  onPressed: () => ws.reference = null,
                  icon: const Icon(Icons.close),
                ),
              if (evals.isNotEmpty) Icon(_details ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
    );
  }

  Widget _signatureList(List<SignatureEvaluation> evals, ThemeData theme) {
    return ListView(
      shrinkWrap: true,
      children: [
        for (final e in evals)
          ListTile(
            leading: Icon(outcomeIcon(e.outcome), color: outcomeColor(e.outcome, theme)),
            title: Text(e.headline),
            subtitle: Text([e.verdict, ?e.reason, ?e.where].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => SignatureDetails(e),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(verificationLimits, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  Widget _filesStrip(DocItem item, List<ContainedFile> files, ContainedFile? viewing, DocumentMarks? marks, ThemeData theme) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final f in files)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                selected: f == viewing,
                avatar: Icon(
                  marks?.files[f.fingerprint] != null ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18,
                  color: marks?.files[f.fingerprint] != null ? Colors.green.shade700 : null,
                ),
                label: Text(
                  marks?.files[f.fingerprint] == null
                      ? f.name
                      : '${f.name} · ${relativeTime(marks!.files[f.fingerprint]!.viewedAt)}',
                ),
                tooltip: f.kind.hasPreview ? 'Mostra' : "Apri con un'altra app",
                onSelected: (_) => _show(item, f),
              ),
            ),
        ],
      ),
    );
  }

  Widget _preview(DocItem item, ContainedFile f, ThemeData theme) {
    switch (f.kind) {
      case ContentKind.pdf:
        return ColoredBox(
          color: Colors.grey.shade300,
          child: rx.PdfViewer.data(
            f.bytes,
            sourceName: '${f.fingerprint}.pdf',
            params: rx.PdfViewerParams(backgroundColor: Colors.grey.shade300),
          ),
        );
      case ContentKind.image:
        return InteractiveViewer(child: Center(child: Image.memory(f.bytes)));
      case ContentKind.text || ContentKind.xml:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(utf8.decode(f.bytes, allowMalformed: true), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        );
      default:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 64),
                const SizedBox(height: 12),
                Text(f.note ?? 'Anteprima non disponibile per ${f.name}.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: () => _openExternal(item, f),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text("Apri con un'altra app"),
                ),
              ],
            ),
          ),
        );
    }
  }
}

/// Dettaglio di una firma: proprietà della firma e, a richiesta, il certificato.
class SignatureDetails extends StatefulWidget {
  const SignatureDetails(this.e, {super.key});

  final SignatureEvaluation e;

  @override
  State<SignatureDetails> createState() => _SignatureDetailsState();
}

class _SignatureDetailsState extends State<SignatureDetails> {
  bool _cert = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.e;
    final lines = _cert ? e.certificateLines : e.signatureLines;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Icon(outcomeIcon(e.outcome), color: outcomeColor(e.outcome, theme)),
              const SizedBox(width: 8),
              Expanded(child: Text(e.headline, style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 4),
            Text([e.verdict, ?e.reason].join(': '), style: TextStyle(color: outcomeColor(e.outcome, theme))),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Proprietà firma')),
                ButtonSegment(value: true, label: Text('Certificato')),
              ],
              selected: {_cert},
              onSelectionChanged: (s) => setState(() => _cert = s.first),
            ),
            const SizedBox(height: 12),
            for (final (label, value) in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
                    SelectableText(value),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Elenco dei documenti del fascicolo con esito e marcature.
class DossierPage extends StatelessWidget {
  const DossierPage({super.key, required this.ws, required this.openDocument});

  final MobileWorkspace ws;
  final Future<void> Function(int index) openDocument;

  Future<void> _report(BuildContext context) async {
    final f = await ws.report();
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'Rapporto di verifica'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final items = ws.set.items;
        final progress = ws.progress;
        return Scaffold(
          appBar: AppBar(
            title: Text('Fascicolo · ${items.length} documenti'),
            actions: [
              IconButton(tooltip: 'Verifica a una data', onPressed: () => pickReference(context, ws), icon: const Icon(Icons.event)),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'all') ws.verifyAll();
                  if (v == 'report') _report(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'all', child: Text('Verifica tutti')),
                  PopupMenuItem(value: 'report', child: Text('Rapporto di verifica (PDF)')),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (progress != null) LinearProgressIndicator(value: progress.$2 == 0 ? null : progress.$1 / progress.$2),
                if (ws.reference != null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.event),
                    title: Text('Verifica al ${formatDay(ws.reference!)}'),
                    trailing: IconButton(tooltip: 'Torna a oggi', onPressed: () => ws.reference = null, icon: const Icon(Icons.close)),
                  ),
                Expanded(
                  child: ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final it = items[i];
                      final marks = ws.set.marksOf(it);
                      final o = it.tree != null ? (it.evaluationsAt(ws.reference).isEmpty ? null : worstOutcome(it.evaluationsAt(ws.reference))) : it.outcome;
                      return Dismissible(
                        key: ValueKey(it.source.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: theme.colorScheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete_outline),
                        ),
                        onDismissed: (_) => ws.set.remove(it),
                        child: ListTile(
                          leading: it.status == DocStatus.loading
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(outcomeIcon(o), color: outcomeColor(o, theme)),
                          title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text([?it.summary, marksLine(marks)].join('\n')),
                          isThreeLine: it.summary != null,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => openDocument(i),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

