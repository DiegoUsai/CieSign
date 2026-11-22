import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';
import 'oids.dart';
import 'pdf/pdf_document.dart';
import 'pdf/pdf_objects.dart';
import 'verify.dart';

/// Tipo di un file, riconosciuto dai primi byte e, in mancanza, dall'estensione.
enum ContentKind {
  pdf,
  p7m,
  zip,
  image,
  xml,
  text,
  other;

  /// Vero se l'app lo può mostrare da sé (PDF, immagini, testo e XML); gli
  /// altri si aprono con l'app predefinita del sistema operativo.
  bool get hasPreview => this == pdf || this == image || this == text || this == xml;
}

/// Un file di un documento aperto: il documento stesso o un file contenuto
/// in una busta .p7m, in uno zip o allegato a un PDF. Forma un albero: la
/// radice è il file caricato, i [children] sono i file estratti.
class ContainedFile {
  ContainedFile({
    required this.path,
    required this.name,
    required this.bytes,
    required this.kind,
    this.origin = ContainedOrigin.document,
    this.signatures = const [],
    this.signatureError,
    this.children = const [],
    this.note,
  });

  /// Percorso dentro il documento ("gara.zip.p7m/gara.zip/offerta.pdf"), da mostrare.
  final String path;

  /// Impronta SHA-256 del file: chiave della marcatura "visualizzato", che così
  /// vale anche se il documento viene rinominato o lo stesso file compare altrove.
  late final String fingerprint = sha256.convert(bytes).toString();
  final String name;
  final Uint8List bytes;
  final ContentKind kind;
  final ContainedOrigin origin;

  /// Firme di questo livello: le firme CAdES della busta per un .p7m, le
  /// firme PAdES per un PDF.
  final List<SignatureReport> signatures;

  /// Messaggio se le firme non si sono potute leggere.
  final String? signatureError;

  final List<ContainedFile> children;

  /// Avviso per l'utente (per esempio zip cifrato o troppo grande).
  final String? note;

  /// Vero per i contenitori senza contenuto proprio da leggere (busta p7m e zip).
  bool get isContainer => kind == ContentKind.p7m || kind == ContentKind.zip;

  /// File da leggere prima di firmare, in ordine: tutti i file che non sono
  /// solo contenitori (un PDF con allegati compare e poi compaiono gli allegati).
  List<ContainedFile> get readableFiles => [
    if (!isContainer) this,
    for (final c in children) ...c.readableFiles,
  ];

  /// Tutti i nodi dell'albero, in profondità.
  Iterable<ContainedFile> get all sync* {
    yield this;
    for (final c in children) {
      yield* c.all;
    }
  }

  /// Il documento "vero" sotto le buste p7m annidate (per anteprima e firma
  /// visibile): il primo file che non è una busta.
  ContainedFile get innermost {
    var f = this;
    while (f.kind == ContentKind.p7m && f.children.length == 1) {
      f = f.children.single;
    }
    return f;
  }

  /// Firme di tutti i livelli, dalla busta esterna verso l'interno.
  List<(ContainedFile, SignatureReport)> get allSignatures => [
    for (final f in all)
      for (final s in f.signatures) (f, s),
  ];
}

enum ContainedOrigin {
  /// Il file caricato dall'utente.
  document,

  /// Estratto da una busta .p7m.
  p7m,

  /// Estratto da un archivio zip.
  zip,

  /// Allegato incorporato in un PDF.
  pdfAttachment,
}

/// Apre un documento e ne estrae ricorsivamente il contenuto: buste .p7m
/// (anche annidate e in Base64), archivi zip e allegati dei PDF. Limiti di
/// profondità e dimensione proteggono da file costruiti per bloccare l'app.
class Unwrapper {
  Unwrapper({this.maxDepth = 6, this.maxTotalBytes = 512 * 1024 * 1024, this.maxEntries = 2000, this.verifyPdf = true});

  final int maxDepth;
  final int maxTotalBytes;
  final int maxEntries;

  /// Verifica anche le firme PAdES dei PDF trovati.
  final bool verifyPdf;

  var _total = 0;
  var _entries = 0;

  static ContainedFile open(String name, Uint8List bytes) => Unwrapper()._open(name, name, bytes, ContainedOrigin.document, 0);

  ContainedFile _open(String path, String name, Uint8List bytes, ContainedOrigin origin, int depth) {
    _entries++;
    final kind = detectKind(name, bytes);
    if (depth >= maxDepth && (kind == ContentKind.p7m || kind == ContentKind.zip)) {
      return ContainedFile(path: path, name: name, bytes: bytes, kind: kind, origin: origin, note: 'Troppi livelli annidati: contenuto non estratto');
    }
    switch (kind) {
      case ContentKind.p7m:
        return _p7m(path, name, bytes, origin, depth);
      case ContentKind.zip:
        return _zip(path, name, bytes, origin, depth);
      case ContentKind.pdf:
        return _pdf(path, name, bytes, origin, depth);
      default:
        return ContainedFile(path: path, name: name, bytes: bytes, kind: kind, origin: origin);
    }
  }

  ContainedFile _p7m(String path, String name, Uint8List raw, ContainedOrigin origin, int depth) {
    final der = p7mDer(raw) ?? raw;
    try {
      final cades = CadesFile.open(der);
      final inner = cades.content!;
      final innerName = name.toLowerCase().endsWith('.p7m') ? _stripOne(name) : CadesFile.unwrappedName(name);
      final child = _open('$path/$innerName', innerName, inner, ContainedOrigin.p7m, depth + 1);
      return ContainedFile(path: path, name: name, bytes: raw, kind: ContentKind.p7m, origin: origin, signatures: cades.reports, children: [child]);
    } on Object catch (e) {
      return ContainedFile(
        path: path,
        name: name,
        bytes: raw,
        kind: ContentKind.p7m,
        origin: origin,
        signatureError: 'Busta non leggibile: $e',
      );
    }
  }

  /// Toglie un solo ".p7m" finale: le buste annidate si sbustano un livello per volta.
  static String _stripOne(String n) => n.substring(0, n.length - 4);

  ContainedFile _zip(String path, String name, Uint8List bytes, ContainedOrigin origin, int depth) {
    final children = <ContainedFile>[];
    String? note;
    try {
      for (final e in ZipReader.entries(bytes)) {
        if (e.isDirectory) continue;
        if (_entries >= maxEntries) {
          note = 'Archivio con troppi file: elenco troncato';
          break;
        }
        if (e.encrypted) {
          note = 'Alcuni file dell\'archivio sono protetti da password e non sono stati estratti';
          continue;
        }
        if (_total + e.uncompressedSize > maxTotalBytes) {
          note = 'Archivio troppo grande: elenco troncato';
          break;
        }
        final data = e.read();
        _total += data.length;
        final short = e.name.split('/').last;
        children.add(_open('$path/${e.name}', short.isEmpty ? e.name : short, data, ContainedOrigin.zip, depth + 1));
      }
    } on Object catch (e) {
      note = 'Archivio non leggibile: $e';
    }
    return ContainedFile(path: path, name: name, bytes: bytes, kind: ContentKind.zip, origin: origin, children: children, note: note);
  }

  ContainedFile _pdf(String path, String name, Uint8List bytes, ContainedOrigin origin, int depth) {
    var sigs = <SignatureReport>[];
    String? sigError;
    final children = <ContainedFile>[];
    if (verifyPdf) {
      try {
        sigs = PadesVerifier.verify(bytes);
      } on Object catch (e) {
        sigError = 'Firme del PDF non leggibili: $e';
      }
    }
    try {
      for (final (n, data) in pdfAttachments(bytes)) {
        if (_total + data.length > maxTotalBytes || _entries >= maxEntries) break;
        _total += data.length;
        children.add(_open('$path/allegati/$n', n, data, ContainedOrigin.pdfAttachment, depth + 1));
      }
    } on Object {
      // Allegati illeggibili: il PDF resta visibile.
    }
    return ContainedFile(
      path: path,
      name: name,
      bytes: bytes,
      kind: ContentKind.pdf,
      origin: origin,
      signatures: sigs,
      signatureError: sigError,
      children: children,
    );
  }

  /// Riconosce il tipo dai primi byte; l'estensione serve per testo e XML.
  static ContentKind detectKind(String name, Uint8List b) {
    bool at(int off, List<int> sig) {
      if (b.length < off + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[off + i] != sig[i]) return false;
      }
      return true;
    }

    final lower = name.toLowerCase();
    if (_findPdfHeader(b)) return ContentKind.pdf;
    if (at(0, const [0x50, 0x4b, 0x03, 0x04]) || at(0, const [0x50, 0x4b, 0x05, 0x06])) {
      // Anche .docx, .xlsx, .odt sono zip: si aprono con l'app di sistema.
      return RegExp(r'\.(docx|xlsx|pptx|odt|ods|odp|epub|jar|apk)$').hasMatch(lower) ? ContentKind.other : ContentKind.zip;
    }
    if (at(0, const [0xff, 0xd8, 0xff]) || at(0, const [0x89, 0x50, 0x4e, 0x47]) || at(0, const [0x47, 0x49, 0x46, 0x38])) {
      return ContentKind.image;
    }
    if ((b.isNotEmpty && b[0] == 0x30) || lower.endsWith('.p7m') || lower.endsWith('.p7s')) {
      if (p7mDer(b) != null) return ContentKind.p7m;
    }
    if (lower.endsWith('.xml') || at(0, '<?xml'.codeUnits)) return ContentKind.xml;
    if (RegExp(r'\.(txt|csv|json|md)$').hasMatch(lower)) return ContentKind.text;
    return ContentKind.other;
  }

  static bool _findPdfHeader(Uint8List b) {
    final n = b.length < 1024 ? b.length : 1024;
    return latin1.decode(Uint8List.sublistView(b, 0, n)).contains('%PDF-');
  }

  /// DER di una busta CMS SignedData, anche se salvata in Base64 o PEM
  /// (capita con alcune PEC e programmi di firma). Nullo se non è una busta.
  static Uint8List? p7mDer(Uint8List b) {
    if (_isSignedData(b)) return b;
    if (b.length > 16 * 1024 * 1024 * 4 / 3) return null;
    try {
      var text = latin1.decode(b).trim();
      final pem = RegExp(r'-----BEGIN [A-Z0-9 ]+-----([\s\S]*?)-----END').firstMatch(text);
      if (pem != null) text = pem[1]!;
      text = text.replaceAll(RegExp(r'\s'), '');
      if (!RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(text)) return null;
      final der = base64.decode(text);
      return _isSignedData(der) ? der : null;
    } on Object {
      return null;
    }
  }

  static bool _isSignedData(Uint8List b) {
    if (b.length < 16 || b[0] != 0x30) return false;
    try {
      final root = DerNode.parse(b);
      return root.length >= 2 && root[0].tag == DerTag.oid && root[0].asOid == Oids.signedData;
    } on Object {
      return false;
    }
  }

  /// Allegati incorporati di un PDF: l'albero /EmbeddedFiles del catalogo e
  /// le annotazioni FileAttachment delle pagine.
  static List<(String, Uint8List)> pdfAttachments(Uint8List pdf) {
    final doc = PdfDocument.parse(pdf);
    final out = <(String, Uint8List)>[];
    final seen = <String>{};

    void addSpec(PdfObject? spec, String fallback) {
      final fs = doc.resolve(spec);
      if (fs is! PdfDict) return;
      final ef = doc.resolve(fs['EF']);
      if (ef is! PdfDict) return;
      final s = doc.resolve(ef['UF'] ?? ef['F']);
      if (s is! PdfStream) return;
      final nameObj = doc.resolve(fs['UF'] ?? fs['F']);
      var n = nameObj is PdfString ? nameObj.text : fallback;
      n = n.split(RegExp(r'[\\/]')).last;
      if (n.isEmpty) n = fallback;
      var unique = n;
      for (var i = 2; seen.contains(unique); i++) {
        unique = '($i) $n';
      }
      seen.add(unique);
      out.add((unique, PdfDocument.decodeStream(s)));
    }

    void walkNames(PdfObject? node, int depth) {
      final d = doc.resolve(node);
      if (d is! PdfDict || depth > 10) return;
      final names = doc.resolve(d['Names']);
      if (names is PdfArray) {
        for (var i = 0; i + 1 < names.items.length; i += 2) {
          final k = doc.resolve(names.items[i]);
          addSpec(names.items[i + 1], k is PdfString ? k.text : 'allegato');
        }
      }
      final kids = doc.resolve(d['Kids']);
      if (kids is PdfArray) {
        for (final k in kids.items) {
          walkNames(k, depth + 1);
        }
      }
    }

    final names = doc.resolve(doc.catalog['Names']);
    if (names is PdfDict) walkNames(names['EmbeddedFiles'], 0);

    for (final p in doc.pages) {
      final page = doc.resolve(p);
      if (page is! PdfDict) continue;
      final annots = doc.resolve(page['Annots']);
      if (annots is! PdfArray) continue;
      for (final a in annots.items) {
        final ad = doc.resolve(a);
        if (ad is PdfDict && (ad['Subtype'] as PdfName?)?.value == 'FileAttachment') {
          addSpec(ad['FS'], 'allegato');
        }
      }
    }
    return out;
  }
}

/// Lettore zip minimo (metodi "stored" e "deflate", senza zip64): basta per gli
/// archivi delle gare e non aggiunge dipendenze.
class ZipReader {
  static List<ZipEntry> entries(Uint8List b) {
    final bd = ByteData.sublistView(b);
    var eocd = -1;
    final from = b.length - 22;
    final to = from - 65535 < 0 ? 0 : from - 65535;
    for (var i = from; i >= to; i--) {
      if (bd.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('fine dell\'archivio non trovata');
    final count = bd.getUint16(eocd + 10, Endian.little);
    var p = bd.getUint32(eocd + 16, Endian.little);
    final out = <ZipEntry>[];
    for (var i = 0; i < count; i++) {
      if (bd.getUint32(p, Endian.little) != 0x02014b50) throw const FormatException('indice dell\'archivio danneggiato');
      final flags = bd.getUint16(p + 8, Endian.little);
      final method = bd.getUint16(p + 10, Endian.little);
      final csize = bd.getUint32(p + 20, Endian.little);
      final usize = bd.getUint32(p + 24, Endian.little);
      final nlen = bd.getUint16(p + 28, Endian.little);
      final xlen = bd.getUint16(p + 30, Endian.little);
      final clen = bd.getUint16(p + 32, Endian.little);
      final local = bd.getUint32(p + 42, Endian.little);
      final nameBytes = Uint8List.sublistView(b, p + 46, p + 46 + nlen);
      final name = flags & 0x800 != 0 ? utf8.decode(nameBytes, allowMalformed: true) : _cp437(nameBytes);
      out.add(ZipEntry._(b, name, method, csize, usize, local, encrypted: flags & 1 != 0));
      p += 46 + nlen + xlen + clen;
    }
    return out;
  }

  /// I nomi senza il flag UTF-8 sono in CP437; per i caratteri ASCII coincide.
  static String _cp437(Uint8List b) => b.every((c) => c < 0x80) ? ascii.decode(b) : latin1.decode(b);
}

class ZipEntry {
  ZipEntry._(this._zip, this.name, this.method, this.compressedSize, this.uncompressedSize, this._localOffset, {required this.encrypted});

  final Uint8List _zip;
  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int _localOffset;
  final bool encrypted;

  bool get isDirectory => name.endsWith('/');

  Uint8List read() {
    final bd = ByteData.sublistView(_zip);
    if (bd.getUint32(_localOffset, Endian.little) != 0x04034b50) throw const FormatException('voce dell\'archivio danneggiata');
    final nlen = bd.getUint16(_localOffset + 26, Endian.little);
    final xlen = bd.getUint16(_localOffset + 28, Endian.little);
    final start = _localOffset + 30 + nlen + xlen;
    final data = Uint8List.sublistView(_zip, start, start + compressedSize);
    return switch (method) {
      0 => Uint8List.fromList(data),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      _ => throw FormatException('metodo di compressione $method non supportato'),
    };
  }
}
