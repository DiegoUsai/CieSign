import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

/// Un documento firmato con l'app.
class SignedEntry {
  SignedEntry({
    required this.path,
    required this.signedAt,
    required this.format,
    required this.holder,
    this.source,
    this.test = false,
  });

  factory SignedEntry.fromJson(Map<String, dynamic> j) => SignedEntry(
    path: j['path'] as String,
    signedAt: DateTime.parse(j['signedAt'] as String),
    format: j['format'] as String,
    holder: j['holder'] as String,
    source: j['source'] as String?,
    test: j['test'] as bool? ?? false,
  );

  /// Percorso del file firmato salvato.
  final String path;
  final DateTime signedAt;

  /// "PAdES" oppure "CAdES".
  final String format;

  /// Titolare del certificato che ha firmato.
  final String holder;

  /// Documento di partenza.
  final String? source;

  /// Firma di prova, senza valore legale.
  final bool test;

  String get name => path.split(RegExp(r'[\\/]')).last;

  Map<String, dynamic> toJson() => {
    'path': path,
    'signedAt': signedAt.toUtc().toIso8601String(),
    'format': format,
    'holder': holder,
    if (source != null) 'source': source,
    if (test) 'test': true,
  };
}

/// Elenco dei documenti firmati, dal più recente, salvato in un file JSON
/// nella cartella dati dell'app. Contiene solo percorsi e metadati: i file
/// restano dove l'utente li ha salvati.
class SignedHistory extends ChangeNotifier {
  SignedHistory._(this._file, this._entries);

  static const maxEntries = 200;

  /// [file] serve ai test; di norma è signed-history.json nella cartella dati.
  static Future<SignedHistory> open({File? file}) async {
    final f =
        file ?? File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}signed-history.json');
    var entries = <SignedEntry>[];
    try {
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List<dynamic>;
        entries = [for (final e in list) SignedEntry.fromJson(e as Map<String, dynamic>)];
      }
    } on Object {
      // File illeggibile: si riparte da un elenco vuoto senza bloccare l'app.
    }
    return SignedHistory._(f, entries);
  }

  final File _file;
  final List<SignedEntry> _entries;

  List<SignedEntry> get entries => List.unmodifiable(_entries);

  Future<void> add(SignedEntry e) async {
    _entries
      ..removeWhere((x) => x.path == e.path)
      ..insert(0, e);
    if (_entries.length > maxEntries) _entries.removeRange(maxEntries, _entries.length);
    await _save();
  }

  Future<void> remove(SignedEntry e) async {
    _entries.removeWhere((x) => x.path == e.path);
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode([for (final e in _entries) e.toJson()]));
    } on Object {
      // L'elenco resta in memoria anche se il salvataggio non riesce.
    }
  }
}

/// Elenco dei documenti firmati, usato nella schermata iniziale e nel dialogo.
class SignedHistoryList extends StatelessWidget {
  const SignedHistoryList({
    super.key,
    required this.history,
    required this.onOpen,
    this.limit,
    this.shrinkWrap = false,
  });

  final SignedHistory history;
  final void Function(SignedEntry) onOpen;
  final int? limit;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final all = history.entries;
        final items = limit == null ? all : all.take(limit!).toList();
        if (items.isEmpty) {
          return const Padding(padding: EdgeInsets.all(16), child: Text('Nessun documento firmato finora.'));
        }
        return ListView.builder(
          shrinkWrap: shrinkWrap,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final e = items[i];
            final exists = File(e.path).existsSync();
            String two(int v) => v.toString().padLeft(2, '0');
            final d = e.signedAt.toLocal();
            final when = '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
            return ListTile(
              leading: Icon(e.format == 'PAdES' ? Icons.picture_as_pdf_outlined : Icons.lock_outline),
              title: Text(e.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  '$when, ${e.format}, ${e.holder}${e.test ? ' (firma di prova)' : ''}',
                  if (!exists) 'File non più presente in ${File(e.path).parent.path}' else File(e.path).parent.path,
                ].join('\n'),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
              isThreeLine: true,
              enabled: exists,
              onTap: exists ? () => onOpen(e) : null,
              trailing: IconButton(
                tooltip: 'Togli dall\'elenco',
                icon: const Icon(Icons.close),
                onPressed: () => history.remove(e),
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> showSignedHistory(BuildContext context, SignedHistory history, void Function(SignedEntry) onOpen) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Documenti firmati'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: SignedHistoryList(
          history: history,
          onOpen: (e) {
            Navigator.pop(context);
            onOpen(e);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: history.entries.isEmpty ? null : () => history.clear(),
          child: const Text('Svuota l\'elenco'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
      ],
    ),
  );
}
