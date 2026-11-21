import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'pdf_objects.dart';
import 'pdf_parser.dart';

/// Lettura di un PDF esistente: tabella dei riferimenti incrociati (**xref**),
/// anche in forma di stream compressi, oggetti compressi negli **object
/// stream** e albero delle pagine. Basta per aggiungere una firma con un
/// aggiornamento incrementale senza toccare i byte originali.
class PdfDocument {
  PdfDocument._(this.bytes);

  factory PdfDocument.parse(Uint8List bytes) {
    final doc = PdfDocument._(bytes);
    if (!_startsWithHeader(bytes)) throw const PdfFormatException('Il file non è un PDF');
    try {
      doc._loadXrefChain();
    } on Object {
      doc._entries.clear();
      doc._reconstruct();
    }
    if (doc.trailer['Encrypt'] != null) {
      throw const PdfFormatException('I PDF protetti da password o cifrati non sono ancora supportati');
    }
    return doc;
  }

  final Uint8List bytes;
  final Map<int, _XrefEntry> _entries = {};
  final Map<int, PdfObject> _cache = {};
  final Map<int, List<(int, int)>> _objStmIndex = {};
  late PdfDict trailer;

  /// Vero se l'ultima sezione xref del file è uno stream (PDF 1.5 o successivi).
  bool lastXrefIsStream = false;
  late int lastXrefOffset;

  int get size => (trailer['Size'] as PdfNumber).intValue;

  PdfRef get rootRef => trailer['Root'] as PdfRef;

  PdfDict get catalog => resolve(rootRef) as PdfDict;

  // ---------------------------------------------------------------- xref

  static bool _startsWithHeader(Uint8List b) {
    final head = latin1.decode(Uint8List.sublistView(b, 0, b.length < 1024 ? b.length : 1024));
    return head.contains('%PDF-');
  }

  int _findStartXref() {
    final from = bytes.length > 2048 ? bytes.length - 2048 : 0;
    final tail = latin1.decode(Uint8List.sublistView(bytes, from));
    final i = tail.lastIndexOf('startxref');
    if (i < 0) throw const PdfFormatException('startxref mancante');
    final m = RegExp(r'startxref\s+(\d+)').matchAsPrefix(tail, i);
    if (m == null) throw const PdfFormatException('startxref non valido');
    return int.parse(m[1]!);
  }

  void _loadXrefChain() {
    var offset = _findStartXref();
    lastXrefOffset = offset;
    final seen = <int>{};
    PdfDict? first;
    var isFirst = true;
    while (seen.add(offset)) {
      final p = PdfParser(bytes, offset)..skipWhite();
      final PdfDict t;
      if (_matches(p.pos, 'xref')) {
        t = _readXrefTable(p.pos + 4);
        final xs = t['XRefStm'];
        if (xs is PdfNumber) _readXrefStream(xs.intValue);
        if (isFirst) lastXrefIsStream = false;
      } else {
        t = _readXrefStream(offset);
        if (isFirst) lastXrefIsStream = true;
      }
      isFirst = false;
      first ??= t;
      final prev = t['Prev'];
      if (prev is! PdfNumber) break;
      offset = prev.intValue;
    }
    trailer = first!;
    if (trailer['Root'] is! PdfRef) throw const PdfFormatException('Catalogo del PDF non trovato');
  }

  bool _matches(int pos, String s) {
    if (pos + s.length > bytes.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (bytes[pos + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  PdfDict _readXrefTable(int pos) {
    final p = PdfParser(bytes, pos);
    while (true) {
      p.skipWhite();
      if (_matches(p.pos, 'trailer')) {
        p.pos += 7;
        return p.readObject() as PdfDict;
      }
      final start = int.parse(p.readToken());
      final count = int.parse(p.readToken());
      for (var i = 0; i < count; i++) {
        final off = int.parse(p.readToken());
        final gen = int.parse(p.readToken());
        final kind = p.readToken();
        final n = start + i;
        if (!_entries.containsKey(n)) {
          _entries[n] = kind == 'n' ? _XrefEntry.inFile(off, gen) : const _XrefEntry.free();
        }
      }
    }
  }

  PdfDict _readXrefStream(int offset) {
    final p = PdfParser(bytes, offset);
    final obj = p.readIndirect().object;
    if (obj is! PdfStream || (obj.dict['Type'] as PdfName?)?.value != 'XRef') {
      throw const PdfFormatException('Sezione xref non valida');
    }
    final d = obj.dict;
    final data = decodeStream(obj);
    final w = (d['W'] as PdfArray).items.map((e) => (e as PdfNumber).intValue).toList();
    final idx = d['Index'] is PdfArray
        ? (d['Index'] as PdfArray).items.map((e) => (e as PdfNumber).intValue).toList()
        : [0, (d['Size'] as PdfNumber).intValue];
    final rowLen = w.fold(0, (a, b) => a + b);
    var r = 0;
    for (var s = 0; s < idx.length; s += 2) {
      for (var i = 0; i < idx[s + 1]; i++, r++) {
        final base = r * rowLen;
        if (base + rowLen > data.length) break;
        int field(int k) {
          var v = 0;
          var o = base;
          for (var j = 0; j < k; j++) {
            o += w[j];
          }
          for (var j = 0; j < w[k]; j++) {
            v = (v << 8) | data[o + j];
          }
          return v;
        }

        final type = w[0] == 0 ? 1 : field(0);
        final n = idx[s] + i;
        if (_entries.containsKey(n)) continue;
        _entries[n] = switch (type) {
          1 => _XrefEntry.inFile(field(1), w[2] == 0 ? 0 : field(2)),
          2 => _XrefEntry.compressed(field(1), field(2)),
          _ => const _XrefEntry.free(),
        };
      }
    }
    return d;
  }

  /// Ricostruzione di emergenza quando la xref è danneggiata: si cercano nel
  /// file tutte le intestazioni "n g obj".
  void _reconstruct() {
    final text = latin1.decode(bytes);
    for (final m in RegExp(r'(?<![0-9])(\d+)\s+(\d+)\s+obj\b').allMatches(text)) {
      _entries[int.parse(m[1]!)] = _XrefEntry.inFile(m.start, int.parse(m[2]!));
    }
    PdfDict? t;
    for (final m in RegExp(r'trailer\s*<<').allMatches(text)) {
      t = PdfParser(bytes, m.start + 7).readObject() as PdfDict;
    }
    t ??= PdfDict();
    if (t['Root'] == null) {
      for (final n in _entries.keys) {
        final o = resolve(PdfRef(n, _entries[n]!.generation));
        if (o is PdfDict && (o['Type'] as PdfName?)?.value == 'Catalog') {
          t['Root'] = PdfRef(n, _entries[n]!.generation);
          break;
        }
      }
    }
    final maxN = _entries.keys.fold(0, (a, b) => a > b ? a : b);
    t['Size'] = PdfNumber(maxN + 1);
    t.entries.remove('Prev');
    trailer = t;
    lastXrefIsStream = false;
    lastXrefOffset = 0;
    if (trailer['Root'] == null) throw const PdfFormatException('PDF danneggiato: catalogo non trovato');
  }

  // ------------------------------------------------------------- oggetti

  PdfObject resolve(PdfObject? o) {
    if (o is! PdfRef) return o ?? const PdfNull();
    final cached = _cache[o.number];
    if (cached != null) return cached;
    final e = _entries[o.number];
    if (e == null || e.kind == 0) return const PdfNull();
    final PdfObject value;
    if (e.kind == 1) {
      final p = PdfParser(bytes, e.offset)..resolveLength = _resolveLength;
      value = p.readIndirect().object;
    } else {
      value = _fromObjectStream(e.offset, e.index);
    }
    _cache[o.number] = value;
    return value;
  }

  int _resolveLength(PdfRef r) => (resolve(r) as PdfNumber).intValue;

  PdfObject _fromObjectStream(int streamNumber, int index) {
    final stm = resolve(PdfRef(streamNumber, 0));
    if (stm is! PdfStream) return const PdfNull();
    final data = decodeStream(stm);
    final first = (stm.dict['First'] as PdfNumber).intValue;
    final table = _objStmIndex.putIfAbsent(streamNumber, () {
      final n = (stm.dict['N'] as PdfNumber).intValue;
      final p = PdfParser(data);
      return [for (var i = 0; i < n; i++) (int.parse(p.readToken()), int.parse(p.readToken()))];
    });
    if (index >= table.length) return const PdfNull();
    return PdfParser(data, first + table[index].$2).readObject();
  }

  /// Decodifica i filtri FlateDecode (con eventuale predittore PNG).
  static Uint8List decodeStream(PdfStream s) {
    final f = s.dict['Filter'];
    final filters = f is PdfName
        ? [f.value]
        : f is PdfArray
        ? f.items.map((e) => (e as PdfName).value).toList()
        : <String>[];
    var data = s.data;
    for (final name in filters) {
      if (name != 'FlateDecode') throw PdfFormatException('Filtro $name non supportato');
      data = Uint8List.fromList(zlib.decode(data));
    }
    final parms = s.dict['DecodeParms'];
    if (parms is PdfDict) {
      final pred = (parms['Predictor'] as PdfNumber?)?.intValue ?? 1;
      if (pred >= 10) data = _pngUnpredict(data, (parms['Columns'] as PdfNumber?)?.intValue ?? 1);
    }
    return data;
  }

  static Uint8List _pngUnpredict(Uint8List data, int columns) {
    final rows = data.length ~/ (columns + 1);
    final out = Uint8List(rows * columns);
    for (var r = 0; r < rows; r++) {
      final type = data[r * (columns + 1)];
      for (var c = 0; c < columns; c++) {
        final raw = data[r * (columns + 1) + 1 + c];
        final left = c > 0 ? out[r * columns + c - 1] : 0;
        final up = r > 0 ? out[(r - 1) * columns + c] : 0;
        final upLeft = r > 0 && c > 0 ? out[(r - 1) * columns + c - 1] : 0;
        out[r * columns + c] =
            switch (type) {
              0 => raw,
              1 => raw + left,
              2 => raw + up,
              3 => raw + ((left + up) >> 1),
              4 => raw + _paeth(left, up, upLeft),
              _ => throw const PdfFormatException('Predittore PNG non valido'),
            } &
            0xff;
      }
    }
    return out;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  // -------------------------------------------------------------- pagine

  late final List<PdfRef> pages = _collectPages();

  List<PdfRef> _collectPages() {
    final out = <PdfRef>[];
    final visited = <int>{};
    void walk(PdfObject node) {
      if (node is! PdfRef || !visited.add(node.number)) return;
      final d = resolve(node);
      if (d is! PdfDict) return;
      final type = (d['Type'] as PdfName?)?.value;
      final kids = resolve(d['Kids']);
      if (type == 'Pages' || (type == null && kids is PdfArray)) {
        if (kids is PdfArray) kids.items.forEach(walk);
      } else {
        out.add(node);
      }
    }

    walk(catalog['Pages'] ?? const PdfNull());
    if (out.isEmpty) throw const PdfFormatException('Il PDF non contiene pagine');
    return out;
  }

  /// Attributo di pagina, cercato anche tra i nodi genitori (ereditarietà).
  PdfObject? inheritedAttribute(PdfDict page, String key) {
    PdfDict? node = page;
    for (var depth = 0; node != null && depth < 64; depth++) {
      final v = node[key];
      if (v != null) return resolve(v);
      final parent = resolve(node['Parent']);
      node = parent is PdfDict ? parent : null;
    }
    return null;
  }

  /// Riquadro visibile della pagina in punti tipografici: CropBox se presente,
  /// altrimenti MediaBox.
  PdfRect pageBox(int index) {
    final page = resolve(pages[index]) as PdfDict;
    final box = inheritedAttribute(page, 'CropBox') ?? inheritedAttribute(page, 'MediaBox');
    if (box is! PdfArray || box.items.length != 4) return const PdfRect(0, 0, 595, 842);
    final v = box.items.map((e) => (resolve(e) as PdfNumber).value.toDouble()).toList();
    return PdfRect(v[0] < v[2] ? v[0] : v[2], v[1] < v[3] ? v[1] : v[3], (v[2] - v[0]).abs(), (v[3] - v[1]).abs());
  }

  int pageRotation(int index) {
    final page = resolve(pages[index]) as PdfDict;
    final r = inheritedAttribute(page, 'Rotate');
    return r is PdfNumber ? ((r.intValue % 360) + 360) % 360 : 0;
  }

  int generationOf(int number) => _entries[number]?.generation ?? 0;
}

class _XrefEntry {
  const _XrefEntry.inFile(this.offset, this.generation) : kind = 1, index = 0;
  const _XrefEntry.compressed(this.offset, this.index) : kind = 2, generation = 0;
  const _XrefEntry.free() : kind = 0, offset = 0, index = 0, generation = 0;

  /// 0 libero, 1 nel file, 2 dentro un object stream (offset = numero dello stream).
  final int kind;
  final int offset;
  final int generation;
  final int index;
}

class PdfRect {
  const PdfRect(this.x, this.y, this.width, this.height);
  final double x, y, width, height;

  @override
  String toString() => 'PdfRect($x, $y, $width, $height)';
}

class PdfFormatException implements Exception {
  const PdfFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
