import 'dart:io';

import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:material_ui/material_ui.dart';

import 'document_page.dart';
import 'sign_file_page.dart';
import 'workspace.dart';

/// Recenti: documenti firmati e verificati, con filtro per tipo (come sul PC).
class RecentsPage extends StatefulWidget {
  const RecentsPage({super.key, required this.ws, required this.openFile});

  final MobileWorkspace ws;
  final Future<void> Function(String path) openFile;

  @override
  State<RecentsPage> createState() => _RecentsPageState();
}

class _RecentsPageState extends State<RecentsPage> {
  ActivityKind? _kind;

  void _tap(Activity a) {
    final path = a.path;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Il file non è più sul telefono')));
      return;
    }
    if (a.kind == ActivityKind.verified) {
      widget.openFile(path);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(a.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.openFile(path);
                },
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Apri e verifica'),
              ),
              const SizedBox(height: 8),
              SignedFileActions(file: File(path)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.ws,
      builder: (context, _) {
        final list = widget.ws.store.recents(kind: _kind);
        return Scaffold(
          appBar: AppBar(title: const Text('Recenti')),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final (k, label) in [(null, 'Tutti'), (ActivityKind.signed, 'Firmati'), (ActivityKind.verified, 'Verificati')])
                        ChoiceChip(label: Text(label), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('Nessun documento recente'))
                      : ListView(
                          children: [
                            for (final a in list)
                              ListTile(
                                leading: a.kind == ActivityKind.signed
                                    ? Icon(Icons.draw, color: theme.colorScheme.primary)
                                    : Icon(outcomeIcon(a.outcome), color: outcomeColor(a.outcome, theme)),
                                title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  a.kind == ActivityKind.signed
                                      ? 'Firmato ${relativeTime(a.at)}${a.format == null ? '' : ' · ${a.format}'}'
                                      : 'Verificato ${relativeTime(a.at)}${a.summary == null ? '' : ' · ${a.summary}'}',
                                ),
                                onTap: () => _tap(a),
                              ),
                          ],
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
