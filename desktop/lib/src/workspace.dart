import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

/// Stato di lavoro dell'app desktop: il fascicolo dei documenti aperti, il
/// file mostrato nell'anteprima e l'archivio delle marcature. Avvolge i
/// pacchetti condivisi con l'app mobile in un [ChangeNotifier] per Flutter.
class Workspace extends ChangeNotifier {
  Workspace._(this.store, this.set) {
    _sub = set.changes.listen((_) => notifyListeners());
    _storeSub = store.changes.listen((_) => notifyListeners());
  }

  /// [dir] serve ai test; di norma è la cartella dati dell'app.
  /// Senza [network] la revoca non viene controllata.
  static Future<Workspace> open({Directory? dir, bool network = true}) async {
    final base = dir ?? await getApplicationSupportDirectory();
    final store = await MarkStore.open(File('${base.path}${Platform.pathSeparator}ciesign-archivio.json'));
    await _migrateSignedHistory(base, store);
    final checker = network ? RevocationChecker(HttpRevocationFetcher()) : null;
    return Workspace._(store, DocumentSet(store: store, checker: checker));
  }

  /// I documenti firmati delle versioni precedenti (signed-history.json)
  /// passano nei Recenti alla prima apertura.
  static Future<void> _migrateSignedHistory(Directory base, MarkStore store) async {
    final old = File('${base.path}${Platform.pathSeparator}signed-history.json');
    if (!old.existsSync()) return;
    try {
      final list = jsonDecode(await old.readAsString()) as List<dynamic>;
      store.importActivities([
        for (final e in list.cast<Map<String, dynamic>>())
          Activity(
            kind: ActivityKind.signed,
            at: DateTime.parse(e['signedAt'] as String),
            name: (e['path'] as String).split(RegExp(r'[\\/]')).last,
            path: e['path'] as String,
            source: e['source'] as String?,
            format: e['format'] as String?,
            holder: e['holder'] as String?,
            test: e['test'] as bool? ?? false,
          ),
      ]);
      await store.save();
      await old.rename('${old.path}.importato');
    } on Object {
      // Vecchio elenco illeggibile: si lascia dov'è.
    }
  }

  final MarkStore store;
  final DocumentSet set;
  late final StreamSubscription<void> _sub;
  late final StreamSubscription<void> _storeSub;

  /// File mostrato nell'anteprima: il documento o un file contenuto.
  ContainedFile? viewing;

  /// Avanzamento di "Verifica tutti": fatti e totale, nullo se fermo.
  (int, int)? progress;

  DocItem? get selected => set.selected;

  /// Documenti dell'ultima sessione, per offrirne la ripresa.
  List<String> get resumable => [for (final p in store.workingSet) if (File(p).existsSync()) p];

  /// Riapre il fascicolo dell'ultima sessione.
  Future<void> resume() async {
    final selectedId = store.workingSelected;
    final ref = store.workingReference;
    await addPaths(resumable, select: false);
    set.reference = ref;
    final idx = set.items.indexWhere((i) => i.source.id == selectedId);
    await select(idx < 0 ? 0 : idx);
  }

  /// Aggiunge file e cartelle (le cartelle con tutte le sottocartelle,
  /// esclusi i file nascosti) e seleziona il primo documento nuovo.
  Future<void> addPaths(List<String> paths, {bool select = true}) async {
    final files = <String>[];
    for (final p in paths) {
      if (FileSystemEntity.isDirectorySync(p)) {
        final found = Directory(p)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .map((f) => f.path)
            .where((f) => !f.split(RegExp(r'[\\/]')).any((s) => s.startsWith('.') || s.startsWith('~\$')))
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        files.addAll(found);
      } else if (File(p).existsSync()) {
        files.add(p);
      }
    }
    final added = set.add(files.map(FileSource.new));
    if (select && added.isNotEmpty) await this.select(set.items.indexOf(added.first));
    unawaited(set.fingerprintAll());
    notifyListeners();
  }

  Future<void> select(int index) async {
    viewing = null;
    notifyListeners();
    final it = await set.select(index);
    if (it == null || it != set.selected) return;
    final t = it.tree;
    if (t != null) view(it, _defaultView(t));
    notifyListeners();
  }

  /// Primo file da mostrare: il documento sotto le buste se ha
  /// un'anteprima, altrimenti il primo file leggibile con anteprima.
  static ContainedFile _defaultView(ContainedFile t) {
    final inner = t.innermost;
    if (inner.kind.hasPreview) return inner;
    return t.readableFiles.where((f) => f.kind.hasPreview).firstOrNull ?? inner;
  }

  /// Mostra [f] nell'anteprima e lo marca come visualizzato se l'app lo sa mostrare.
  void view(DocItem item, ContainedFile f) {
    viewing = f;
    if (f.kind.hasPreview) set.markFileViewed(item, f);
    notifyListeners();
  }

  /// Apre [f] con l'app predefinita del sistema e lo marca come visualizzato.
  Future<void> openExternal(DocItem item, ContainedFile f) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}${Platform.pathSeparator}ciesign${Platform.pathSeparator}${f.fingerprint.substring(0, 12)}');
    await dir.create(recursive: true);
    final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = File('${dir.path}${Platform.pathSeparator}$safe');
    await out.writeAsBytes(f.bytes, flush: true);
    await openWithSystem(out.path);
    set.markFileViewed(item, f, external: true);
  }

  Future<void> remove(DocItem item) async {
    final wasSelected = item == set.selected;
    set.remove(item);
    if (wasSelected && set.items.isNotEmpty) {
      await select(set.selectedIndex.clamp(0, set.items.length - 1));
    } else if (set.items.isEmpty) {
      viewing = null;
    }
    notifyListeners();
  }

  void clear() {
    set.clear();
    viewing = null;
    notifyListeners();
  }

  set reference(DateTime? r) {
    set.reference = r;
    notifyListeners();
  }

  DateTime? get reference => set.reference;

  Future<void> verifyAll() async {
    progress = (0, 0);
    notifyListeners();
    try {
      await set.verifyAll(
        onProgress: (d, t) {
          progress = (d, t);
          notifyListeners();
        },
      );
    } finally {
      progress = null;
      notifyListeners();
    }
  }

  /// Dopo una firma: registra la firma su originale e firmato e mette il
  /// file firmato al posto del documento nel fascicolo.
  Future<void> signed(
    DocItem item,
    String output, {
    required String fingerprintOut,
    required String format,
    required String holder,
    bool test = false,
  }) async {
    if (item.fingerprint != null) {
      store.markSigned(item.fingerprint!, name: item.name, output: output, source: item.source.id, format: format, holder: holder, test: test);
    }
    store.markSigned(fingerprintOut, name: output.split(RegExp(r'[\\/]')).last, output: output, source: item.source.id, format: format, holder: holder, test: test);
    final n = set.replace(item, FileSource(output));
    await select(set.items.indexOf(n));
  }

  @override
  void dispose() {
    _sub.cancel();
    _storeSub.cancel();
    unawaited(store.save());
    super.dispose();
  }
}

/// Apre un file con l'app predefinita del sistema operativo.
Future<void> openWithSystem(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', [path], mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
  }
}
