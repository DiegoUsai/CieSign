import 'dart:async';
import 'dart:io';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Stato di lavoro dell'app mobile: il fascicolo dei documenti aperti e
/// l'archivio delle marcature (visto, verificato, firmato) e dei Recenti.
/// Usa gli stessi pacchetti dell'app desktop (ciesign_docset, ciesign_ades),
/// così le due app si comportano allo stesso modo.
class MobileWorkspace extends ChangeNotifier {
  MobileWorkspace._(this.store, this.set, this._dir) {
    _sub = set.changes.listen((_) => notifyListeners());
    _storeSub = store.changes.listen((_) => notifyListeners());
  }

  /// [dir] serve ai test; di norma è la cartella dati dell'app. Senza
  /// [network] la revoca dei certificati non viene controllata.
  static Future<MobileWorkspace> open({Directory? dir, bool network = true}) async {
    final base = dir ?? await getApplicationSupportDirectory();
    final store = await MarkStore.open(File('${base.path}/firmami-archivio.json'));
    final checker = network ? RevocationChecker(HttpRevocationFetcher()) : null;
    return MobileWorkspace._(store, DocumentSet(store: store, checker: checker), base);
  }

  final MarkStore store;
  final DocumentSet set;
  final Directory _dir;
  late final StreamSubscription<void> _sub;
  late final StreamSubscription<void> _storeSub;

  /// Avanzamento di "Verifica tutti": fatti e totale, nullo se fermo.
  (int, int)? progress;

  DocItem? get selected => set.selected;

  /// Documenti dell'ultima sessione ancora presenti, per offrirne la ripresa.
  List<String> get resumable => [for (final p in store.workingSet) if (File(p).existsSync()) p];

  Future<void> resume() async {
    final selectedId = store.workingSelected;
    final ref = store.workingReference;
    set.clear();
    set.add(resumable.map(FileSource.new));
    set.reference = ref;
    final idx = set.items.indexWhere((i) => i.source.id == selectedId);
    unawaited(set.fingerprintAll());
    if (set.items.isNotEmpty) await set.select(idx < 0 ? 0 : idx);
    notifyListeners();
  }

  /// Copia i file scelti nella cartella dell'app (quelli del selettore di sistema
  /// possono sparire) e li mette nel fascicolo, al posto di quello precedente.
  Future<void> openFiles(List<({String name, Future<List<int>> Function() read})> files) async {
    final folder = Directory('${_dir.path}/fascicolo');
    await folder.create(recursive: true);
    final paths = <String>[];
    for (final f in files) {
      final bytes = await f.read();
      final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      var out = File('${folder.path}/$safe');
      // Stesso nome ma contenuto diverso: si aggiunge un numero.
      for (var n = 2; out.existsSync() && out.lengthSync() != bytes.length; n++) {
        final dot = safe.lastIndexOf('.');
        out = File('${folder.path}/${dot > 0 ? '${safe.substring(0, dot)} ($n)${safe.substring(dot)}' : '$safe ($n)'}');
      }
      await out.writeAsBytes(bytes, flush: true);
      paths.add(out.path);
    }
    set.clear();
    set.add(paths.map(FileSource.new));
    unawaited(set.fingerprintAll());
    if (set.items.isNotEmpty) await set.select(0);
    notifyListeners();
  }

  Future<void> select(int index) async {
    await set.select(index);
    notifyListeners();
  }

  /// Primo file da mostrare: il documento sotto le buste se ha un'anteprima,
  /// altrimenti il primo file leggibile con anteprima.
  static ContainedFile defaultView(ContainedFile t) {
    final inner = t.innermost;
    if (inner.kind.hasPreview) return inner;
    return t.readableFiles.where((f) => f.kind.hasPreview).firstOrNull ?? inner;
  }

  /// Segna [f] come visualizzato nell'app.
  void viewed(DocItem item, ContainedFile f) {
    if (f.kind.hasPreview) set.markFileViewed(item, f);
  }

  /// Apre [f] con un'altra app del telefono ("Apri con") e lo segna come visualizzato.
  Future<String?> openExternal(DocItem item, ContainedFile f) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/firmami/${f.fingerprint.substring(0, 12)}');
    await dir.create(recursive: true);
    final out = File('${dir.path}/${f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
    await out.writeAsBytes(f.bytes, flush: true);
    final r = await OpenFilex.open(out.path);
    if (r.type == ResultType.done) {
      set.markFileViewed(item, f, external: true);
      return null;
    }
    return r.type == ResultType.noAppToOpen ? 'Nessuna app del telefono sa aprire questo file.' : r.message;
  }

  set reference(DateTime? r) {
    set.reference = r;
    notifyListeners();
  }

  DateTime? get reference => set.reference;

  Future<void> verifyAll() async {
    progress = (0, set.items.length);
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

  /// Dopo una firma: registra la firma su originale e firmato e mette il file
  /// firmato al posto del documento nel fascicolo.
  Future<void> signed(DocItem item, File output, List<int> bytes, {required String format, required String holder}) async {
    if (item.fingerprint != null) {
      store.markSigned(item.fingerprint!, name: item.name, output: output.path, source: item.source.id, format: format, holder: holder);
    }
    store.markSigned(
      sha256.convert(bytes).toString(),
      name: output.uri.pathSegments.last,
      output: output.path,
      source: item.source.id,
      format: format,
      holder: holder,
    );
    final n = set.replace(item, FileSource(output.path));
    await set.select(set.items.indexOf(n));
    await store.save();
    notifyListeners();
  }

  /// Rapporto di verifica in PDF dei documenti del fascicolo (tutti o solo [only]).
  Future<File> report({DocItem? only}) async {
    final docs = <ReportDocument>[];
    for (final it in only == null ? [...set.items] : [only]) {
      await set.load(it);
      final t = it.tree;
      if (t == null) continue;
      docs.add(ReportDocument(name: it.name, tree: t, evaluations: it.evaluationsAt(reference), marks: set.marksOf(it)));
    }
    final pdf = await VerificationReportPdf.build(docs, reference: reference);
    final tmp = await getTemporaryDirectory();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final out = File('${tmp.path}/Rapporto di verifica ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}.pdf');
    await out.writeAsBytes(pdf, flush: true);
    return out;
  }

  @override
  void dispose() {
    _sub.cancel();
    _storeSub.cancel();
    unawaited(store.save());
    super.dispose();
  }
}
