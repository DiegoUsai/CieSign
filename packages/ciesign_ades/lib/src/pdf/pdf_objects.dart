import 'dart:convert';
import 'dart:typed_data';

/// Modello minimo degli oggetti **PDF** (ISO 32000-1, capitolo 7.3), con la
/// scrittura in forma testuale usata dagli aggiornamenti incrementali.
abstract class PdfObject {
  const PdfObject();

  void writeTo(BytesBuilder out);

  Uint8List toBytes() {
    final b = BytesBuilder(copy: false);
    writeTo(b);
    return b.toBytes();
  }
}

class PdfNull extends PdfObject {
  const PdfNull();
  @override
  void writeTo(BytesBuilder out) => out.add(latin1.encode('null'));
}

class PdfBool extends PdfObject {
  const PdfBool(this.value);
  final bool value;
  @override
  void writeTo(BytesBuilder out) => out.add(latin1.encode(value ? 'true' : 'false'));
}

class PdfNumber extends PdfObject {
  const PdfNumber(this.value);
  final num value;

  int get intValue => value.toInt();

  @override
  void writeTo(BytesBuilder out) => out.add(latin1.encode(format(value)));

  static String format(num v) {
    if (v is int || v == v.roundToDouble()) return v.toInt().toString();
    var s = v.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }
}

class PdfName extends PdfObject {
  const PdfName(this.value);
  final String value;

  @override
  void writeTo(BytesBuilder out) {
    final sb = StringBuffer('/');
    for (final c in latin1.encode(value)) {
      final regular = c > 0x20 && c < 0x7f && !'()<>[]{}/%#'.codeUnits.contains(c);
      sb.write(regular ? String.fromCharCode(c) : '#${c.toRadixString(16).padLeft(2, '0')}');
    }
    out.add(latin1.encode(sb.toString()));
  }

  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '/$value';
}

class PdfString extends PdfObject {
  const PdfString(this.bytes, {this.hex = false});

  /// Stringa di testo: Latin-1 se possibile, altrimenti UTF-16BE con BOM.
  factory PdfString.text(String s) {
    if (s.codeUnits.every((c) => c < 0x100)) return PdfString(Uint8List.fromList(latin1.encode(s)));
    final b = <int>[0xfe, 0xff];
    for (final c in s.codeUnits) {
      b
        ..add(c >> 8)
        ..add(c & 0xff);
    }
    return PdfString(Uint8List.fromList(b));
  }

  final Uint8List bytes;
  final bool hex;

  @override
  void writeTo(BytesBuilder out) {
    if (hex) {
      out.addByte(0x3c);
      for (final b in bytes) {
        out.add(latin1.encode(b.toRadixString(16).padLeft(2, '0')));
      }
      out.addByte(0x3e);
      return;
    }
    out.addByte(0x28);
    for (final b in bytes) {
      if (b == 0x28 || b == 0x29 || b == 0x5c) {
        out
          ..addByte(0x5c)
          ..addByte(b);
      } else if (b == 0x0d) {
        out.add(latin1.encode(r'\r'));
      } else if (b == 0x0a) {
        out.add(latin1.encode(r'\n'));
      } else {
        out.addByte(b);
      }
    }
    out.addByte(0x29);
  }

  String get text {
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return String.fromCharCodes([for (var i = 2; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]]);
    }
    return latin1.decode(bytes);
  }
}

class PdfArray extends PdfObject {
  PdfArray([List<PdfObject>? items]) : items = items ?? [];
  final List<PdfObject> items;

  @override
  void writeTo(BytesBuilder out) {
    out.addByte(0x5b);
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.addByte(0x20);
      items[i].writeTo(out);
    }
    out.addByte(0x5d);
  }
}

class PdfDict extends PdfObject {
  PdfDict([Map<String, PdfObject>? entries]) : entries = entries ?? {};
  final Map<String, PdfObject> entries;

  PdfObject? operator [](String key) => entries[key];
  void operator []=(String key, PdfObject value) => entries[key] = value;

  PdfDict copy() => PdfDict(Map.of(entries));

  @override
  void writeTo(BytesBuilder out) {
    out.add(latin1.encode('<<'));
    entries.forEach((k, v) {
      PdfName(k).writeTo(out);
      out.addByte(0x20);
      v.writeTo(out);
    });
    out.add(latin1.encode('>>'));
  }
}

class PdfStream extends PdfObject {
  PdfStream(this.dict, this.data);
  final PdfDict dict;
  final Uint8List data;

  @override
  void writeTo(BytesBuilder out) {
    final d = dict.copy()..['Length'] = PdfNumber(data.length);
    d.writeTo(out);
    out.add(latin1.encode('\nstream\n'));
    out.add(data);
    out.add(latin1.encode('\nendstream'));
  }
}

class PdfRef extends PdfObject {
  const PdfRef(this.number, this.generation);
  final int number;
  final int generation;

  @override
  void writeTo(BytesBuilder out) => out.add(latin1.encode('$number $generation R'));

  @override
  bool operator ==(Object other) => other is PdfRef && other.number == number && other.generation == generation;
  @override
  int get hashCode => number * 31 + generation;
  @override
  String toString() => '$number $generation R';
}
