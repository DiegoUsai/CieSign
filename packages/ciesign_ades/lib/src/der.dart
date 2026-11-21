import 'dart:convert';
import 'dart:typed_data';

/// Codifica e decodifica **DER** (ASN.1) ridotta a ciò che serve a CMS e X.509.

class DerTag {
  static const boolean = 0x01;
  static const integer = 0x02;
  static const bitString = 0x03;
  static const octetString = 0x04;
  static const nullTag = 0x05;
  static const oid = 0x06;
  static const utf8String = 0x0c;
  static const printableString = 0x13;
  static const ia5String = 0x16;
  static const utcTime = 0x17;
  static const generalizedTime = 0x18;
  static const sequence = 0x30;
  static const set = 0x31;

  /// Tag contestuale costruito, per esempio [0] EXPLICIT o IMPLICIT su SEQUENCE.
  static int context(int n, {bool constructed = true}) => (constructed ? 0xa0 : 0x80) | n;
}

/// Un nodo DER già decodificato: tag, contenuto e byte originali (utili per
/// firmare o confrontare esattamente ciò che è stato letto).
class DerNode {
  DerNode(this.tag, this.raw, this.contentOffset, this.contentLength);

  final int tag;

  /// Byte dell'intero TLV.
  final Uint8List raw;
  final int contentOffset;
  final int contentLength;

  Uint8List get content => Uint8List.sublistView(raw, contentOffset, contentOffset + contentLength);

  bool get isConstructed => tag & 0x20 != 0;

  /// Valore di un OCTET STRING, anche se spezzato in segmenti (forma BER costruita).
  Uint8List get octetValue {
    if (!isConstructed) return content;
    final b = BytesBuilder(copy: false);
    for (final c in children) {
      b.add(c.octetValue);
    }
    return b.toBytes();
  }

  List<DerNode>? _children;

  List<DerNode> get children {
    if (_children != null) return _children!;
    if (!isConstructed) throw FormatException('Il nodo DER 0x${tag.toRadixString(16)} non è costruito');
    return _children = DerNode.parseAll(content);
  }

  DerNode operator [](int i) => children[i];

  int get length => children.length;

  BigInt get asBigInt {
    _expect(DerTag.integer);
    var v = BigInt.zero;
    for (final b in content) {
      v = (v << 8) | BigInt.from(b);
    }
    if (content.isNotEmpty && content[0] & 0x80 != 0) v -= BigInt.one << (content.length * 8);
    return v;
  }

  int get asInt => asBigInt.toInt();

  String get asOid {
    _expect(DerTag.oid);
    final c = content;
    final parts = <int>[];
    var v = 0;
    for (final b in c) {
      v = (v << 7) | (b & 0x7f);
      if (b & 0x80 == 0) {
        parts.add(v);
        v = 0;
      }
    }
    final first = parts.first;
    final a = first < 80 ? first ~/ 40 : 2;
    return [a, first - a * 40, ...parts.skip(1)].join('.');
  }

  String get asString {
    switch (tag) {
      case DerTag.utf8String:
        return utf8.decode(content, allowMalformed: true);
      case 0x1e: // BMPString
        final c = content;
        final codes = <int>[for (var i = 0; i + 1 < c.length; i += 2) (c[i] << 8) | c[i + 1]];
        return String.fromCharCodes(codes);
      default:
        return latin1.decode(content);
    }
  }

  DateTime get asTime {
    final s = latin1.decode(content);
    if (tag == DerTag.utcTime) {
      final yy = int.parse(s.substring(0, 2));
      return DateTime.utc(
        yy < 50 ? 2000 + yy : 1900 + yy,
        int.parse(s.substring(2, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(8, 10)),
        s.length > 11 ? int.parse(s.substring(10, 12)) : 0,
      );
    }
    if (tag == DerTag.generalizedTime) {
      return DateTime.utc(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(8, 10)),
        int.parse(s.substring(10, 12)),
        int.parse(s.substring(12, 14)),
      );
    }
    throw FormatException('Il nodo DER 0x${tag.toRadixString(16)} non è una data');
  }

  void _expect(int t) {
    if (tag != t) {
      throw FormatException('Atteso il tag DER 0x${t.toRadixString(16)}, trovato 0x${tag.toRadixString(16)}');
    }
  }

  /// Decodifica un singolo TLV all'inizio di [bytes].
  static DerNode parse(Uint8List bytes, [int offset = 0]) {
    final r = _readHeader(bytes, offset);
    if (r.length < 0) {
      // Lunghezza indefinita (BER), usata da alcuni programmi per i .p7m:
      // i figli proseguono fino alla coppia di byte 00 00.
      var p = r.contentOffset;
      while (true) {
        if (p + 2 > bytes.length) throw const FormatException('Struttura BER troncata');
        if (bytes[p] == 0 && bytes[p + 1] == 0) break;
        p += parse(bytes, p).raw.length;
      }
      return DerNode(r.tag, Uint8List.sublistView(bytes, offset, p + 2), r.contentOffset - offset, p - r.contentOffset);
    }
    final end = r.contentOffset + r.length;
    if (end > bytes.length) throw const FormatException('Struttura DER troncata');
    return DerNode(r.tag, Uint8List.sublistView(bytes, offset, end), r.contentOffset - offset, r.length);
  }

  static List<DerNode> parseAll(Uint8List bytes) {
    final out = <DerNode>[];
    var off = 0;
    while (off < bytes.length) {
      final n = parse(bytes, off);
      out.add(n);
      off += n.raw.length;
    }
    return out;
  }

  static ({int tag, int length, int contentOffset}) _readHeader(Uint8List b, int off) {
    if (off + 2 > b.length) throw const FormatException('Struttura DER troncata');
    final tag = b[off];
    if (tag & 0x1f == 0x1f) throw const FormatException('Tag DER a più byte non supportati');
    var len = b[off + 1];
    var p = off + 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0) {
        if (tag & 0x20 == 0) throw const FormatException('Lunghezza indefinita su un tipo primitivo');
        return (tag: tag, length: -1, contentOffset: p);
      }
      if (n > 4) throw const FormatException('Lunghezza DER eccessiva');
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | b[p++];
      }
    }
    return (tag: tag, length: len, contentOffset: p);
  }
}

/// Costruttori di TLV DER.
class Der {
  static Uint8List tlv(int tag, List<int> content) {
    final out = BytesBuilder(copy: false);
    out.addByte(tag);
    final n = content.length;
    if (n < 0x80) {
      out.addByte(n);
    } else {
      final lenBytes = <int>[];
      var v = n;
      while (v > 0) {
        lenBytes.insert(0, v & 0xff);
        v >>= 8;
      }
      out.addByte(0x80 | lenBytes.length);
      out.add(lenBytes);
    }
    out.add(content);
    return out.toBytes();
  }

  static Uint8List seq(List<List<int>> items) => tlv(DerTag.sequence, _cat(items));

  /// SET OF con ordinamento DER delle codifiche, come richiesto da X.690 11.6.
  static Uint8List setOf(List<List<int>> items) {
    final sorted = [...items]..sort(_compareBytes);
    return tlv(DerTag.set, _cat(sorted));
  }

  static Uint8List explicit(int n, List<int> inner) => tlv(DerTag.context(n), inner);

  static Uint8List octets(List<int> v) => tlv(DerTag.octetString, v);

  static Uint8List nul() => Uint8List.fromList([DerTag.nullTag, 0]);

  static Uint8List integer(BigInt v) {
    if (v.isNegative) throw ArgumentError('Interi negativi non supportati');
    final bytes = <int>[];
    var x = v;
    while (x > BigInt.zero) {
      bytes.insert(0, (x & BigInt.from(0xff)).toInt());
      x >>= 8;
    }
    if (bytes.isEmpty || bytes[0] & 0x80 != 0) bytes.insert(0, 0);
    return tlv(DerTag.integer, bytes);
  }

  static Uint8List smallInt(int v) => integer(BigInt.from(v));

  static Uint8List oid(String dotted) {
    final p = dotted.split('.').map(int.parse).toList();
    final out = <int>[..._base128(p[0] * 40 + p[1])];
    for (final v in p.skip(2)) {
      out.addAll(_base128(v));
    }
    return tlv(DerTag.oid, out);
  }

  static Uint8List utcTime(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final s = '${two(u.year % 100)}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    return tlv(DerTag.utcTime, latin1.encode(s));
  }

  static Uint8List algorithm(String oidValue, {bool withNull = false}) => seq([oid(oidValue), if (withNull) nul()]);

  static List<int> _base128(int v) {
    final out = <int>[v & 0x7f];
    v >>= 7;
    while (v > 0) {
      out.insert(0, 0x80 | (v & 0x7f));
      v >>= 7;
    }
    return out;
  }

  static Uint8List _cat(List<List<int>> items) {
    final b = BytesBuilder(copy: false);
    for (final i in items) {
      b.add(i);
    }
    return b.toBytes();
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
