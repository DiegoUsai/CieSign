import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:firmami_brand/firmami_brand.dart';
import 'package:material_ui/material_ui.dart';

import 'src/document_page.dart';
import 'src/link_service.dart';
import 'src/pairing_dialog.dart';
import 'src/sign_workflow.dart';
import 'src/signed_history.dart';

/// Accetta come argomento il percorso di un documento, così l'app si può
/// usare con "Apri con" di Windows e del Finder.
/// L'argomento --sviluppo attiva la modalità sviluppatore, con la firma di prova.
void main(List<String> args) {
  final dev = args.contains('--sviluppo');
  final files = args.where((a) => !a.startsWith('--')).toList();
  runApp(CieSignApp(initialPath: files.isEmpty ? null : files.first, developerMode: dev));
}

class CieSignApp extends StatelessWidget {
  const CieSignApp({super.key, this.startLink = true, this.initialPath, this.developerMode = false});

  final String? initialPath;
  final bool developerMode;

  /// Nei test l'app parte senza server di rete.
  final bool startLink;

  @override
  Widget build(BuildContext context) {
    const seed = FirmamiColors.red;
    return MaterialApp(
      title: FirmamiColors.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      // Lo splash animato parte solo nell'app vera, non nei test.
      home: SplashGate(
        enabled: startLink,
        child: HomePage(startLink: startLink, initialPath: initialPath, developerMode: developerMode),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.startLink = true, this.initialPath, this.developerMode = false});

  final bool startLink;
  final bool developerMode;
  final String? initialPath;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LinkService? _link;
  String? _linkError;
  OpenedDocument? _doc;
  bool _dragging = false;
  SignedHistory? _history;
  late bool _dev = widget.developerMode;

  @override
  void initState() {
    super.initState();
    final p = widget.initialPath;
    if (p != null && File(p).existsSync()) _openPath(p);
    if (widget.startLink) {
      SignedHistory.open().then((h) {
        if (mounted) setState(() => _history = h);
      });
      LinkService.open().then((l) {
        if (!mounted) return;
        l.addListener(() => setState(() {}));
        setState(() => _link = l);
      }, onError: (Object e) => setState(() => _linkError = '$e'));
    }
  }

  @override
  void dispose() {
    _link?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await openFile();
    if (f != null) await _openPath(f.path);
  }

  /// Apre un file firmato: l'esito della verifica compare nel pannello a destra.
  Future<void> _pickSigned() async {
    const group = XTypeGroup(label: 'File firmati', extensions: ['pdf', 'p7m', 'p7s']);
    final f = await openFile(acceptedTypeGroups: [group]);
    if (f != null) await _openPath(f.path);
  }

  void _openEntry(SignedEntry e) => _openPath(e.path);

  Future<void> _openPath(String path) async {
    final bytes = await File(path).readAsBytes();
    setState(() => _doc = OpenedDocument(path, bytes));
  }

  Future<void> _pair() async {
    final link = _link;
    if (link == null) return;
    final ok = await PairingDialog.show(context, link);
    if (!mounted || ok == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? 'Smartphone abbinato.' : 'Abbinamento annullato.')));
  }

  @override
  Widget build(BuildContext context) {
    final session = _link?.activeSession;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmami'),
        actions: [
          Padding(
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
          ),
          TextButton.icon(
            onPressed: _link == null ? null : _pair,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Abbina smartphone'),
          ),
          IconButton(tooltip: 'Apri documento', onPressed: _pick, icon: const Icon(Icons.folder_open)),
          IconButton(
            tooltip: 'Documenti firmati',
            onPressed: _history == null ? null : () => showSignedHistory(context, _history!, _openEntry),
            icon: const Icon(Icons.history),
          ),
          PopupMenuButton<String>(
            tooltip: 'Altre opzioni',
            onSelected: (v) {
              if (v == 'dev') setState(() => _dev = !_dev);
              if (v == 'internet') _link?.setInternetEnabled(!_link!.internetEnabled);
            },
            itemBuilder: (context) => [
              if (_link?.remoteAvailable ?? false)
                CheckedPopupMenuItem(
                  value: 'internet',
                  checked: _link!.internetEnabled,
                  child: const Text('Il telefono non è sulla stessa rete'),
                ),
              CheckedPopupMenuItem(value: 'dev', checked: _dev, child: const Text('Modalità sviluppatore')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          if (d.files.isNotEmpty) _openPath(d.files.first.path);
        },
        child: _doc == null
            ? _emptyState(context)
            : DocumentPage(
                key: ValueKey(_doc!.path + _doc!.bytes.length.toString()),
                doc: _doc!,
                link: _link,
                onOpen: (d) => setState(() => _doc = d),
                history: _history,
                developerMode: _dev,
                onPair: _link == null ? null : _pair,
              ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 560,
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
              Text('Trascina qui un documento', style: t.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'PDF da firmare in PAdES, qualsiasi file da firmare in CAdES, '
                'oppure un file firmato (.pdf o .p7m) da verificare.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Apri documento'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickSigned,
                    icon: const Icon(Icons.verified_outlined),
                    label: const Text('Verifica un file firmato'),
                  ),
                ],
              ),
              if (_history != null && _history!.entries.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Divider(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Firmati di recente', style: t.titleSmall),
                ),
                SignedHistoryList(history: _history!, onOpen: _openEntry, limit: 5, shrinkWrap: true),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
