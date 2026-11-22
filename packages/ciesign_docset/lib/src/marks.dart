import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_ades/ciesign_ades.dart';

/// Marcatura di un file interno (contenuto di un .p7m, di uno zip o allegato
/// di un PDF): quando è stato visualizzato e se con un'app esterna.
class FileMark {
  FileMark(this.viewedAt, {this.external = false});

  factory FileMark.fromJson(Map<String, Object?> j) =>
      FileMark(DateTime.parse(j['viewedAt'] as String), external: j['external'] as bool? ?? false);

  final DateTime viewedAt;

  /// Aperto con l'app predefinita del sistema e non nell'anteprima di CIE Sign.
  final bool external;

  Map<String, Object?> toJson() => {'viewedAt': viewedAt.toUtc().toIso8601String(), if (external) 'external': true};
}

/// Marcature di un documento. Sono legate al **contenuto** (impronta SHA-256),
/// non al percorso: lo stesso file riaperto da un'altra cartella, o domani,
/// mostra quando era stato visto, verificato o firmato.
class DocumentMarks {
  DocumentMarks(this.fingerprint, {this.name});

  factory DocumentMarks.fromJson(String fp, Map<String, Object?> j) {
    DateTime? d(String k) => j[k] == null ? null : DateTime.parse(j[k] as String);
    return DocumentMarks(fp, name: j['name'] as String?)
      ..viewedAt = d('viewedAt')
      ..verifiedAt = d('verifiedAt')
      ..verifiedReference = d('verifiedReference')
      ..verifiedOutcome = j['verifiedOutcome'] == null ? null : Outcome.values.byName(j['verifiedOutcome'] as String)
      ..verifiedSummary = j['verifiedSummary'] as String?
      ..signedAt = d('signedAt')
      ..signedOutput = j['signedOutput'] as String?
      ..files.addAll({
        for (final e in ((j['files'] as Map<String, Object?>?) ?? const {}).entries)
          e.key: FileMark.fromJson(e.value as Map<String, Object?>),
      });
  }

  final String fingerprint;
  String? name;

  /// Anteprima del documento aperta.
  DateTime? viewedAt;

  /// Ultima verifica: quando, a quale data di riferimento e con quale esito.
  DateTime? verifiedAt;
  DateTime? verifiedReference;
  Outcome? verifiedOutcome;
  String? verifiedSummary;

  /// Ultima firma fatta con CIE Sign e file prodotto.
  DateTime? signedAt;
  String? signedOutput;

  /// Marcature dei file interni, per impronta ([ContainedFile.fingerprint]).
  final Map<String, FileMark> files = {};

  DateTime get lastActivity => [viewedAt, verifiedAt, signedAt, ...files.values.map((f) => f.viewedAt)]
      .whereType<DateTime>()
      .fold(DateTime.fromMillisecondsSinceEpoch(0), (a, b) => b.isAfter(a) ? b : a);

  Map<String, Object?> toJson() {
    String? d(DateTime? t) => t?.toUtc().toIso8601String();
    return {
      if (name != null) 'name': name,
      if (viewedAt != null) 'viewedAt': d(viewedAt),
      if (verifiedAt != null) 'verifiedAt': d(verifiedAt),
      if (verifiedReference != null) 'verifiedReference': d(verifiedReference),
      if (verifiedOutcome != null) 'verifiedOutcome': verifiedOutcome!.name,
      if (verifiedSummary != null) 'verifiedSummary': verifiedSummary,
      if (signedAt != null) 'signedAt': d(signedAt),
      if (signedOutput != null) 'signedOutput': signedOutput,
      if (files.isNotEmpty) 'files': {for (final e in files.entries) e.key: e.value.toJson()},
    };
  }
}

/// Voce dei Recenti: un documento firmato o verificato.
enum ActivityKind { signed, verified }

class Activity {
  Activity({
    required this.kind,
    required this.at,
    required this.name,
    this.path,
    this.source,
    this.outcome,
    this.summary,
    this.format,
    this.holder,
    this.test = false,
  });

  factory Activity.fromJson(Map<String, Object?> j) => Activity(
    kind: ActivityKind.values.byName(j['kind'] as String),
    at: DateTime.parse(j['at'] as String),
    name: j['name'] as String,
    path: j['path'] as String?,
    source: j['source'] as String?,
    outcome: j['outcome'] == null ? null : Outcome.values.byName(j['outcome'] as String),
    summary: j['summary'] as String?,
    format: j['format'] as String?,
    holder: j['holder'] as String?,
    test: j['test'] as bool? ?? false,
  );

  final ActivityKind kind;
  final DateTime at;
  final String name;

  /// File da riaprire: il firmato per le firme, il documento per le verifiche.
  final String? path;

  /// Documento di partenza di una firma.
  final String? source;
  final Outcome? outcome;
  final String? summary;

  /// "PAdES" o "CAdES" per le firme.
  final String? format;
  final String? holder;

  /// Firma di prova, senza valore legale.
  final bool test;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    'name': name,
    if (path != null) 'path': path,
    if (source != null) 'source': source,
    if (outcome != null) 'outcome': outcome!.name,
    if (summary != null) 'summary': summary,
    if (format != null) 'format': format,
    if (holder != null) 'holder': holder,
    if (test) 'test': true,
  };
}

/// Archivio locale di CIE Sign, in un solo file JSON nella cartella dati
/// dell'app: marcature per documento, Recenti e fascicolo di lavoro aperto
/// (per riprendere dopo una chiusura o uno spegnimento). Contiene solo
/// impronte, nomi, percorsi ed esiti: mai il contenuto dei documenti.
class MarkStore {
  MarkStore._(this._file);

  static const maxDocuments = 5000;
  static const maxActivities = 500;

  /// Apre o crea l'archivio. Un file illeggibile non blocca l'app: si riparte vuoti.
  static Future<MarkStore> open(File file) async {
    final s = MarkStore._(file);
    try {
      if (await file.exists()) s._load(jsonDecode(await file.readAsString()) as Map<String, Object?>);
    } on Object {
      // Archivio danneggiato: si ricomincia.
    }
    return s;
  }

  final File _file;
  final _docs = <String, DocumentMarks>{};
  final _activities = <Activity>[];
  List<String> _workingSet = [];
  String? _workingSelected;
  DateTime? _workingReference;
  final _changes = StreamController<void>.broadcast();
  Timer? _saveTimer;

  /// Avvisa a ogni modifica (le app la collegano al proprio stato).
  Stream<void> get changes => _changes.stream;

  void _load(Map<String, Object?> j) {
    for (final e in ((j['documents'] as Map<String, Object?>?) ?? const {}).entries) {
      _docs[e.key] = DocumentMarks.fromJson(e.key, e.value as Map<String, Object?>);
    }
    for (final a in (j['activities'] as List<Object?>?) ?? const []) {
      _activities.add(Activity.fromJson(a as Map<String, Object?>));
    }
    final ws = j['workingSet'] as Map<String, Object?>?;
    if (ws != null) {
      _workingSet = [for (final p in ws['sources'] as List<Object?>) p as String];
      _workingSelected = ws['selected'] as String?;
      _workingReference = ws['reference'] == null ? null : DateTime.parse(ws['reference'] as String);
    }
  }

  DocumentMarks marksOf(String fingerprint) => _docs[fingerprint] ?? DocumentMarks(fingerprint);
  DocumentMarks? existing(String fingerprint) => _docs[fingerprint];

  DocumentMarks _edit(String fingerprint, String? name) {
    final m = _docs.putIfAbsent(fingerprint, () => DocumentMarks(fingerprint));
    if (name != null) m.name = name;
    return m;
  }

  void markViewed(String fingerprint, {String? name, DateTime? at}) {
    _edit(fingerprint, name).viewedAt = at ?? DateTime.now();
    _changed();
  }

  /// Marca un file interno come visualizzato ([fileFingerprint] è [ContainedFile.fingerprint]).
  void markFileViewed(String fingerprint, String fileFingerprint, {bool external = false, DateTime? at}) {
    _edit(fingerprint, null).files[fileFingerprint] = FileMark(at ?? DateTime.now(), external: external);
    _changed();
  }

  void markVerified(
    String fingerprint, {
    required String name,
    required Outcome? outcome,
    required String summary,
    DateTime? reference,
    String? path,
    DateTime? at,
  }) {
    final when = at ?? DateTime.now();
    _edit(fingerprint, name)
      ..verifiedAt = when
      ..verifiedOutcome = outcome
      ..verifiedSummary = summary
      ..verifiedReference = reference;
    _addActivity(Activity(kind: ActivityKind.verified, at: when, name: name, path: path, outcome: outcome, summary: summary));
  }

  void markSigned(
    String fingerprint, {
    required String name,
    required String output,
    String? source,
    String? format,
    String? holder,
    bool test = false,
    DateTime? at,
  }) {
    final when = at ?? DateTime.now();
    _edit(fingerprint, name)
      ..signedAt = when
      ..signedOutput = output;
    _addActivity(
      Activity(
        kind: ActivityKind.signed,
        at: when,
        name: output.split(RegExp(r'[\\/]')).last,
        path: output,
        source: source,
        format: format,
        holder: holder,
        test: test,
      ),
    );
  }

  void _addActivity(Activity a) {
    // Una sola voce per file e tipo: la più recente.
    _activities.removeWhere((x) => x.kind == a.kind && x.path != null && x.path == a.path);
    _activities.insert(0, a);
    if (_activities.length > maxActivities) _activities.removeRange(maxActivities, _activities.length);
    _changed();
  }

  /// Recenti, dal più nuovo; [kind] filtra per tipo.
  List<Activity> recents({ActivityKind? kind}) =>
      List.unmodifiable(kind == null ? _activities : _activities.where((a) => a.kind == kind));

  void removeActivity(Activity a) {
    _activities.remove(a);
    _changed();
  }

  void clearRecents() {
    _activities.clear();
    _changed();
  }

  /// Fascicolo di lavoro aperto: identificativi dei documenti (percorsi sul
  /// desktop), documento selezionato e data di riferimento della verifica.
  List<String> get workingSet => List.unmodifiable(_workingSet);
  String? get workingSelected => _workingSelected;
  DateTime? get workingReference => _workingReference;

  void saveWorkingSet(List<String> sources, {String? selected, DateTime? reference}) {
    _workingSet = [...sources];
    _workingSelected = selected;
    _workingReference = reference;
    _changed();
  }

  /// Importa i documenti firmati dal vecchio signed-history.json del desktop.
  void importActivities(Iterable<Activity> old) {
    for (final a in old) {
      if (!_activities.any((x) => x.kind == a.kind && x.path == a.path)) _activities.add(a);
    }
    _activities.sort((a, b) => b.at.compareTo(a.at));
    _changed();
  }

  void _changed() {
    _changes.add(null);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () => unawaited(save()));
  }

  /// Scrive subito l'archivio (le modifiche si salvano comunque da sole
  /// dopo un attimo). Scrittura atomica: file temporaneo e rinomina.
  Future<void> save() async {
    _saveTimer?.cancel();
    if (_docs.length > maxDocuments) {
      final sorted = _docs.values.toList()..sort((a, b) => a.lastActivity.compareTo(b.lastActivity));
      for (final m in sorted.take(_docs.length - maxDocuments)) {
        _docs.remove(m.fingerprint);
      }
    }
    final j = {
      'version': 1,
      'documents': {for (final e in _docs.entries) e.key: e.value.toJson()},
      'activities': [for (final a in _activities) a.toJson()],
      'workingSet': {
        'sources': _workingSet,
        if (_workingSelected != null) 'selected': _workingSelected,
        if (_workingReference != null) 'reference': _workingReference!.toUtc().toIso8601String(),
      },
    };
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(j), flush: true);
    await tmp.rename(_file.path);
  }

  Future<void> close() async {
    await save();
    await _changes.close();
  }
}
