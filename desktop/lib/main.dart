import 'dart:async';
import 'dart:io';

import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'src/document_list.dart';
import 'src/document_page.dart';
import 'src/link_service.dart';
import 'src/pairing_dialog.dart';
import 'src/recents.dart';
import 'src/reference_date.dart';
import 'src/verification_panel.dart';
import 'src/workspace.dart';

/// Accetta come argomenti uno o più percorsi di documenti, così l'app si può
/// usare con "Apri con" di Windows e del Finder.
/// L'argomento --sviluppo attiva la modalità sviluppatore, con la firma di prova.
void main(List<String> args) {
  final dev = args.contains('--sviluppo');
  final files = args.where((a) => !a.startsWith('--')).toList();
  runApp(CieSignApp(initialPaths: files, developerMode: dev));
}

class CieSignApp extends StatelessWidget {
  const CieSignApp({
    super.key,
    this.startLink = true,
    this.initialPaths = const [],
    this.developerMode = false,
    this.workspace,
  });

  final List<String> initialPaths;
  final bool developerMode;

  /// Nei test l'app parte senza server di rete.
  final bool startLink;

  /// Nei test si passa un fascicolo in una cartella temporanea.
  final Workspace? workspace;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0066CC);
    return MaterialApp(
      title: 'CIE Sign',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
      home: HomePage(
        startLink: startLink,
        initialPaths: initialPaths,
        developerMode: developerMode,
        workspace: workspace,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.startLink = true,
    this.initialPaths = const [],
    this.developerMode = false,
    this.workspace,
  });

  final bool startLink;
  final bool developerMode;
  final List<String> initialPaths;
  final Workspace? workspace;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LinkService? _link;
  String? _linkError;
  Workspace? _ws;
  bool _dragging = false;
  late bool _dev = widget.developerMode;

  @override
  void initState() {
    super.initState();
    final given = widget.workspace;
    if (given != null) {
      _attach(given);
    } else if (widget.startLink) {
      Workspace.open().then(_attach);
    } else {
      Directory.systemTemp.createTemp('ciesign').then((d) => Workspace.open(dir: d, network: false)).then(_attach);
    }
    if (widget.startLink) {
      LinkService.open().then((l) {
        if (!mounted) return;
        l.addListener(() => setState(() {}));
        setState(() => _link = l);
      }, onError: (Object e) => setState(() => _linkError = '$e'));
    }
  }

  void _attach(Workspace ws) {
    if (!mounted) return;
    ws.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _ws = ws);
    if (widget.initialPaths.isNotEmpty) unawaited(ws.addPaths(widget.initialPaths));
  }

  @override
  void dispose() {
    _link?.dispose();
    _ws?.dispose();
    super.dispose();
  }

  Future<void> _addFiles() async {
    final files = await openFiles();
    if (files.isNotEmpty) await _ws?.addPaths([for (final f in files) f.path]);
  }

  Future<void> _addFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Aggiungi');
    if (dir != null) await _ws?.addPaths([dir]);
  }

  Future<void> _pair() async {
    final link = _link;
    if (link == null) return;
    final ok = await PairingDialog.show(context, link);
    if (!mounted || ok == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Smartphone abbinato.' : 'Abbinamento annullato.')));
  }

  Future<void> _pickReference() async {
    final ws = _ws;
    if (ws == null) return;
    final d = await pickReferenceDate(context, ws.reference);
    if (d == null) return;
    ws.reference = d.year == 0 ? null : d;
  }

  /// Rapporto PDF del documento selezionato o di tutto il fascicolo.
  Future<void> _report({required bool all}) async {
    final ws = _ws;
    if (ws == null) return;
    final items = all ? ws.set.items : [?ws.selected];
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Preparazione del rapporto…')));
    final docs = <ReportDocument>[];
    for (final it in items) {
      await ws.set.load(it);
      final tree = it.tree;
      if (tree == null) continue;
      docs.add(ReportDocument(name: it.name, tree: tree, evaluations: it.evaluationsAt(ws.reference), marks: ws.set.marksOf(it)));
    }
    if (docs.isEmpty) return;
    final pdf = await VerificationReportPdf.build(docs, reference: ws.reference, appVersion: '0.1.0');
    final first = items.first.source.id;
    final name = all ? 'rapporto-verifica-${docs.length}-documenti.pdf' : 'rapporto-verifica-${items.first.name}.pdf';
    final loc = await getSaveLocation(suggestedName: name, initialDirectory: File(first).parent.path);
    if (loc == null) return;
    await File(loc.path).writeAsBytes(pdf, flush: true);
    messenger.showSnackBar(SnackBar(content: Text('Rapporto salvato in ${loc.path}')));
  }

  @override
  Widget build(BuildContext context) {
    final ws = _ws;
    final hasDocs = ws != null && ws.set.items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CIE Sign'),
        actions: [
          _phoneChip(),
          TextButton.icon(
            onPressed: _link == null ? null : _pair,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Abbina smartphone'),
          ),
          IconButton(
            tooltip: 'Recenti',
            onPressed: ws == null ? null : () => showRecents(context, ws.store, (p) => ws.addPaths([p])),
            icon: const Icon(Icons.history),
          ),
          PopupMenuButton<String>(
            tooltip: 'Altre opzioni',
            onSelected: (v) {
              if (v == 'dev') setState(() => _dev = !_dev);
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(value: 'dev', checked: _dev, child: const Text('Modalità sviluppatore')),
            ],
          ),
          const SizedBox(width: 8),
        ],
        bottom: ws == null ? null : PreferredSize(preferredSize: const Size.fromHeight(52), child: _toolbar(ws)),
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          if (d.files.isNotEmpty) _ws?.addPaths([for (final f in d.files) f.path]);
        },
        child: ws == null
            ? const Center(child: CircularProgressIndicator())
            : !hasDocs
            ? _emptyState(context, ws)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 290, child: DocumentList(ws: ws)),
                  const VerticalDivider(width: 1),
                  Expanded(child: _selected(ws)),
                ],
              ),
      ),
    );
  }

  Widget _selected(Workspace ws) {
    final it = ws.selected;
    if (it == null) return const Center(child: Text('Scegli un documento dall\'elenco.'));
    if (it.status == DocStatus.error) {
      return Center(child: Text('Impossibile aprire ${it.name}: ${it.error}'));
    }
    if (it.tree == null) return const Center(child: CircularProgressIndicator());
    return DocumentPage(
      key: ValueKey('${it.source.id}#${it.fingerprint}'),
      ws: ws,
      item: it,
      link: _link,
      developerMode: _dev,
      onPair: _link == null ? null : _pair,
    );
  }

  /// Barra degli strumenti, come la barra a pulsanti di Aruba Sign.
  Widget _toolbar(Workspace ws) {
    final hasDocs = ws.set.items.isNotEmpty;
    final ref = ws.reference;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('aggiungi-documenti'),
              onPressed: _addFiles,
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Aggiungi documenti'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Aggiungi cartella'),
            ),
            const SizedBox(width: 16),
            InputChip(
              key: const ValueKey('verifica-alla-data'),
              avatar: const Icon(Icons.event_outlined, size: 18),
              label: Text(ref == null ? 'Verifica: adesso' : 'Verifica al ${formatDate(ref)}'),
              selected: ref != null,
              onPressed: _pickReference,
              onDeleted: ref == null ? null : () => ws.reference = null,
              deleteButtonTooltipMessage: 'Torna ad adesso',
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: !hasDocs || ws.progress != null ? null : ws.verifyAll,
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(ws.progress == null ? 'Verifica tutti' : 'Verifica ${ws.progress!.$1} di ${ws.progress!.$2}…'),
            ),
            const SizedBox(width: 8),
            MenuAnchor(
              builder: (context, c, _) => OutlinedButton.icon(
                onPressed: !hasDocs ? null : () => c.isOpen ? c.close() : c.open(),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Rapporto PDF'),
              ),
              menuChildren: [
                MenuItemButton(
                  onPressed: ws.selected == null ? null : () => _report(all: false),
                  child: const Text('Del documento selezionato'),
                ),
                MenuItemButton(onPressed: () => _report(all: true), child: Text('Di tutti i documenti (${ws.set.items.length})')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _phoneChip() {
    final session = _link?.activeSession;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Chip(
        avatar: Icon(
          session != null ? Icons.smartphone : Icons.phonelink_off,
          size: 18,
          color: session != null ? Colors.green.shade700 : null,
        ),
        label: Text(
          _linkError != null
              ? 'Rete non disponibile'
              : session != null
              ? session.peerName
              : (_link?.pairedDevices.isEmpty ?? true)
              ? 'Nessuno smartphone abbinato'
              : 'Smartphone non collegato',
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context, Workspace ws) {
    final t = Theme.of(context).textTheme;
    final resumable = ws.resumable;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 640,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            border: Border.all(color: _dragging ? Theme.of(context).colorScheme.primary : Colors.grey, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.upload_file, size: 64),
              const SizedBox(height: 16),
              Text('Trascina qui documenti o cartelle', style: t.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Puoi aprirne molti insieme, per esempio tutti i documenti di una gara: li scorri, li verifichi '
                'e li firmi uno alla volta. PDF, .p7m (anche annidati o con uno zip dentro) e qualsiasi altro file.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(onPressed: _addFiles, icon: const Icon(Icons.folder_open), label: const Text('Apri documenti')),
                  OutlinedButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Apri una cartella'),
                  ),
                  if (resumable.isNotEmpty)
                    OutlinedButton.icon(
                      key: const ValueKey('riprendi'),
                      onPressed: ws.resume,
                      icon: const Icon(Icons.restore),
                      label: Text(
                        resumable.length == 1 ? 'Riprendi il lavoro (1 documento)' : 'Riprendi il lavoro (${resumable.length} documenti)',
                      ),
                    ),
                ],
              ),
              if (ws.store.recents().isNotEmpty) ...[
                const SizedBox(height: 24),
                const Divider(),
                Align(alignment: Alignment.centerLeft, child: Text('Recenti', style: t.titleSmall)),
                const SizedBox(height: 8),
                RecentsList(store: ws.store, onOpen: (p) => ws.addPaths([p]), limit: 5, shrinkWrap: true),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
