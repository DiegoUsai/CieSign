import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'src/document_page.dart';
import 'src/link_service.dart';
import 'src/pairing_dialog.dart';
import 'src/sign_workflow.dart';

/// Accetta come argomento il percorso di un documento, così l'app si può
/// usare con "Apri con" di Windows e del Finder.
void main(List<String> args) => runApp(CieSignApp(initialPath: args.isEmpty ? null : args.first));

class CieSignApp extends StatelessWidget {
  const CieSignApp({super.key, this.startLink = true, this.initialPath});

  final String? initialPath;

  /// Nei test l'app parte senza server di rete.
  final bool startLink;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0066CC);
    return MaterialApp(
      title: 'CIE Sign',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      home: HomePage(startLink: startLink, initialPath: initialPath),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.startLink = true, this.initialPath});

  final bool startLink;
  final String? initialPath;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LinkService? _link;
  String? _linkError;
  OpenedDocument? _doc;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final p = widget.initialPath;
    if (p != null && File(p).existsSync()) _openPath(p);
    if (widget.startLink) {
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
        title: const Text('CIE Sign'),
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
              ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Container(
        width: 520,
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
            FilledButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.folder_open),
              label: const Text('Apri documento'),
            ),
          ],
        ),
      ),
    );
  }
}
