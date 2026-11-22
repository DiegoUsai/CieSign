import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:crypto/crypto.dart';

import 'marks.dart';

/// Origine di un documento del fascicolo: un file sul disco (desktop) o un
/// contenuto ricevuto dal sistema (mobile).
abstract class DocumentSource {
  /// Identificativo stabile: il percorso sul desktop, l'URI sul mobile.
  String get id;
  String get name;
  Future<Uint8List> read();
}

class FileSource implements DocumentSource {
  FileSource(this.path);
  final String path;

  @override
  String get id => path;

  @override
  String get name => path.split(RegExp(r'[\\/]')).last;

  @override
  Future<Uint8List> read() => File(path).readAsBytes();
}

class MemorySource implements DocumentSource {
  MemorySource(this.id, this.name, this.bytes);

  @override
  final String id;
  @override
  final String name;
  final Uint8List bytes;

  @override
  Future<Uint8List> read() async => bytes;
}

enum DocStatus { pending, loading, ready, error }

/// Un documento del fascicolo, con il suo contenuto estratto e l'esito della
/// verifica alla data di riferimento del fascicolo.
class DocItem {
  DocItem(this.source);

  final DocumentSource source;
  DocStatus status = DocStatus.pending;
  String? error;

  /// Impronta SHA-256 (esadecimale) del documento: chiave delle marcature.
  String? fingerprint;

  /// Contenuto estratto; nullo finché non è caricato o dopo [DocumentSet.unload].
  ContainedFile? tree;

  /// Revoca di ciascuna firma di [ContainedFile.allSignatures], stesso ordine.
  List<RevocationReport>? revocations;
  bool checkingRevocation = false;

  /// Ultimo esito calcolato, che resta anche dopo [DocumentSet.unload].
  Outcome? outcome;
  String? summary;
  int signatureCount = 0;

  String get name => source.name;
  Uint8List? get bytes => tree?.bytes;

  /// Valutazione di tutte le firme (di tutti i livelli) alla data [at].
  List<SignatureEvaluation> evaluationsAt(DateTime? at) {
    final t = tree;
    if (t == null) return const [];
    final sigs = t.allSignatures;
    final levels = {for (final s in sigs) s.$1}.length;
    String? where(ContainedFile f) => levels < 2
        ? null
        : f.kind == ContentKind.p7m
        ? 'busta ${f.name}'
        : 'firme di ${f.name}';
    return [
      for (var i = 0; i < sigs.length; i++)
        SignatureEvaluation(
          sigs[i].$2,
          at: at,
          pades: sigs[i].$1.kind == ContentKind.pdf,
          where: where(sigs[i].$1),
          revocation: revocations != null && i < revocations!.length ? revocations![i] : const RevocationReport.notChecked(),
        ),
    ];
  }
}

/// Fascicolo: più documenti aperti insieme (per esempio tutti quelli di una
/// gara), da scorrere, verificare e firmare uno per volta, con le marcature
/// salvate nel [MarkStore] e il lavoro ripreso alla riapertura dell'app.
class DocumentSet {
  DocumentSet({required this.store, this.checker, this.keepLoaded = 6});

  final MarkStore store;

  /// Controllo di revoca; nullo per non usare la rete.
  final RevocationChecker? checker;

  /// Quanti documenti tenere in memoria con il contenuto estratto.
  final int keepLoaded;

  final List<DocItem> items = [];
  DateTime? _reference;
  int _selected = -1;
  final _recent = <DocItem>[];
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  /// Data di riferimento della verifica; nulla significa "adesso".
  DateTime? get reference => _reference;
  set reference(DateTime? r) {
    _reference = r;
    for (final i in items.where((i) => i.tree != null)) {
      _recordVerification(i);
    }
    _persist();
  }

  DocItem? get selected => _selected >= 0 && _selected < items.length ? items[_selected] : null;
  int get selectedIndex => _selected;

  /// Aggiunge documenti (ignorando quelli già presenti) e seleziona il primo nuovo.
  List<DocItem> add(Iterable<DocumentSource> sources) {
    final added = <DocItem>[];
    for (final s in sources) {
      if (items.any((i) => i.source.id == s.id)) continue;
      final it = DocItem(s);
      items.add(it);
      added.add(it);
    }
    if (added.isNotEmpty && selected == null) _selected = items.indexOf(added.first);
    _persist();
    return added;
  }

  void remove(DocItem item) {
    final idx = items.indexOf(item);
    if (idx < 0) return;
    items.removeAt(idx);
    _recent.remove(item);
    if (_selected >= items.length) _selected = items.length - 1;
    if (idx < _selected) _selected--;
    _persist();
  }

  void clear() {
    items.clear();
    _recent.clear();
    _selected = -1;
    _persist();
  }

  /// Sostituisce l'origine di un documento (per esempio dopo la firma, con il
  /// file firmato) mantenendone la posizione.
  DocItem replace(DocItem item, DocumentSource source) {
    final idx = items.indexOf(item);
    final n = DocItem(source);
    if (idx >= 0) items[idx] = n;
    _recent.remove(item);
    _persist();
    return n;
  }

  Future<DocItem?> select(int index) async {
    if (index < 0 || index >= items.length) return null;
    _selected = index;
    _persist();
    final it = items[index];
    await load(it);
    return it;
  }

  /// Legge, sbusta e verifica il documento; poi controlla la revoca in
  /// background e aggiorna l'esito. La marcatura "verificato" si registra a
  /// verifica completata.
  Future<void> load(DocItem item, {bool revocation = true}) async {
    if (item.status == DocStatus.loading) return;
    if (item.tree != null) {
      _touch(item);
      return;
    }
    item.status = DocStatus.loading;
    item.error = null;
    _notify();
    try {
      final bytes = await item.source.read();
      item.fingerprint = sha256.convert(bytes).toString();
      item.tree = Unwrapper.open(item.source.name, bytes);
      item.status = DocStatus.ready;
      _touch(item);
      _recordVerification(item, revocationPending: revocation && checker != null);
    } on Object catch (e) {
      item.status = DocStatus.error;
      item.error = '$e';
      _notify();
      return;
    }
    if (revocation && checker != null && item.tree!.allSignatures.isNotEmpty) {
      item.checkingRevocation = true;
      _notify();
      try {
        item.revocations = await checkRevocations([for (final s in item.tree!.allSignatures) s.$2], checker!);
      } finally {
        item.checkingRevocation = false;
      }
      _recordVerification(item);
    }
  }

  /// Calcola l'impronta dei documenti che non ce l'hanno ancora, così
  /// l'elenco mostra subito le marcature (visto ieri, firmato oggi...) anche
  /// dei documenti non ancora aperti. Non estrae il contenuto.
  Future<void> fingerprintAll() async {
    for (final it in [...items]) {
      if (it.fingerprint != null || it.status == DocStatus.error) continue;
      try {
        it.fingerprint = sha256.convert(await it.source.read()).toString();
        _notify();
      } on Object catch (e) {
        it.status = DocStatus.error;
        it.error = '$e';
        _notify();
      }
    }
  }

  /// Verifica in sequenza tutti i documenti non ancora verificati, liberando
  /// la memoria di quelli non selezionati. [onProgress] riceve fatti e totale.
  Future<void> verifyAll({void Function(int done, int total)? onProgress}) async {
    final todo = items.where((i) => i.outcome == null && i.status != DocStatus.error).toList();
    for (var k = 0; k < todo.length; k++) {
      final it = todo[k];
      if (!items.contains(it)) continue;
      await load(it);
      if (it != selected && _recent.length > keepLoaded) unload(it);
      onProgress?.call(k + 1, todo.length);
    }
  }

  /// Libera il contenuto estratto; esito e marcature restano.
  void unload(DocItem item) {
    item.tree = null;
    item.status = DocStatus.pending;
    _recent.remove(item);
  }

  void _touch(DocItem item) {
    _recent
      ..remove(item)
      ..add(item);
    while (_recent.length > keepLoaded) {
      final victim = _recent.where((x) => x != item && x != selected).firstOrNull;
      if (victim == null) break;
      unload(victim);
    }
  }

  void _recordVerification(DocItem item, {bool revocationPending = false}) {
    final evals = item.evaluationsAt(_reference);
    item.signatureCount = evals.length;
    item.outcome = evals.isEmpty ? null : worstOutcome(evals);
    item.summary = overallText(evals);
    if (!revocationPending && item.fingerprint != null) {
      store.markVerified(
        item.fingerprint!,
        name: item.name,
        outcome: item.outcome,
        summary: item.summary!,
        reference: _reference,
        path: item.source.id,
      );
    }
    _notify();
  }

  /// Marca il documento come visualizzato (anteprima mostrata).
  void markViewed(DocItem item) {
    if (item.fingerprint == null) return;
    store.markViewed(item.fingerprint!, name: item.name);
  }

  /// Marca un file interno come visualizzato, nell'app o con un'app esterna.
  void markFileViewed(DocItem item, ContainedFile file, {bool external = false}) {
    if (item.fingerprint == null) return;
    store.markFileViewed(item.fingerprint!, file.fingerprint, external: external);
    if (file == item.tree?.innermost || file == item.tree) store.markViewed(item.fingerprint!, name: item.name);
  }

  DocumentMarks? marksOf(DocItem item) => item.fingerprint == null ? null : store.existing(item.fingerprint!);

  /// File da leggere non ancora visualizzati, per l'avviso prima della firma
  /// (avviso senza blocco).
  List<ContainedFile> unviewedFiles(DocItem item) {
    final t = item.tree;
    if (t == null) return const [];
    final m = marksOf(item);
    return [
      for (final f in t.readableFiles)
        if (m == null || !m.files.containsKey(f.fingerprint)) f,
    ];
  }

  void _persist() {
    store.saveWorkingSet(
      [for (final i in items) i.source.id],
      selected: selected?.source.id,
      reference: _reference,
    );
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
