import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'local_sign.dart';
import 'sign_file_page.dart';

/// Documenti recenti: per ora i file firmati sul telefono.
class RecentsPage extends StatefulWidget {
  const RecentsPage({super.key, required this.store});

  final SignedStore store;

  @override
  State<RecentsPage> createState() => _RecentsPageState();
}

class _RecentsPageState extends State<RecentsPage> {
  List<File>? _files;

  @override
  void initState() {
    super.initState();
    widget.store.list().then((l) {
      if (mounted) setState(() => _files = l);
    });
  }

  void _open(File f) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(f.uri.pathSegments.last, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              SignedFileActions(file: f),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(title: const Text('Recenti')),
      body: SafeArea(
        child: files == null
            ? const Center(child: CircularProgressIndicator())
            : files.isEmpty
                ? const Center(child: Text('Nessun documento firmato sul telefono'))
                : ListView(
                    children: [
                      for (final f in files)
                        ListTile(
                          leading: Icon(f.path.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf : Icons.description),
                          title: Text(f.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('Firmato il ${when(f.lastModifiedSync())}'),
                          onTap: () => _open(f),
                        ),
                    ],
                  ),
      ),
    );
  }
}

String when(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}
