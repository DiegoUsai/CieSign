import 'dart:convert';
import 'dart:typed_data';

import 'pdf_objects.dart';

/// Analizzatore degli oggetti PDF a partire da una posizione nel file.
class PdfParser {
  PdfParser(this.data, [this.pos = 0]);

  final Uint8List data;
  int pos;

  /// Risolve la lunghezza di uno stream quando è un riferimento indiretto.
  int Function(PdfRef ref)? resolveLength;

  static bool isWhite(int c) => c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 || c == 0x0c || c == 0x00;
  static bool isDelim(int c) => '()<>[]{}/%'.codeUnits.contains(c);

  void skipWhite() {
    while (pos < data.length) {
      final c = data[pos];
      if (isWhite(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < data.length && data[pos] != 0x0a && data[pos] != 0x0d) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  String readToken() {
    skipWhite();
    final start = pos;
    while (pos < data.length && !isWhite(data[pos]) && !isDelim(data[pos])) {
      pos++;
    }
    return latin1.decode(Uint8List.sublistView(data, start, pos));
  }

  /// Legge "n g obj" e restituisce l'oggetto che segue.
  ({int number, int generation, PdfObject object}) readIndirect() {
    final n = int.parse(readToken());
    final g = int.parse(readToken());
    if (readToken() != 'obj') throw FormatException('Atteso "obj" alla posizione $pos');
    final obj = readObject();
    return (number: n, generation: g, object: obj);
  }

  PdfObject readObject() {
    skipWhite();
    if (pos >= data.length) throw const FormatException('Fine inattesa del PDF');
    final c = data[pos];
    switch (c) {
      case 0x2f: // /
        return _readName();
      case 0x28: // (
        return _readLiteralString();
      case 0x5b: // [
        pos++;
        final items = <PdfObject>[];
        while (true) {
          skipWhite();
          if (data[pos] == 0x5d) {
            pos++;
            return PdfArray(items);
          }
          items.add(readObject());
        }
      case 0x3c: // <
        if (data[pos + 1] == 0x3c) return _readDictOrStream();
        return _readHexString();
    }
    final tok = readToken();
    if (tok.isEmpty) throw FormatException('Carattere inatteso 0x${c.toRadixString(16)} alla posizione $pos');
    if (tok == 'true') return const PdfBool(true);
    if (tok == 'false') return const PdfBool(false);
    if (tok == 'null') return const PdfNull();
    final n = num.tryParse(tok.startsWith('.') ? '0$tok' : tok.replaceFirst(RegExp(r'^-\.'), '-0.'));
    if (n == null) throw FormatException('Token PDF non valido "$tok" alla posizione $pos');
    // Un intero può essere l'inizio di un riferimento "n g R".
    if (n is int && n >= 0) {
      final save = pos;
      final t2 = readToken();
      final g = int.tryParse(t2);
      if (g != null) {
        final t3 = readToken();
        if (t3 == 'R') return PdfRef(n, g);
      }
      pos = save;
    }
    return PdfNumber(n);
  }

  PdfName _readName() {
    pos++;
    final start = pos;
    while (pos < data.length && !isWhite(data[pos]) && !isDelim(data[pos])) {
      pos++;
    }
    final raw = latin1.decode(Uint8List.sublistView(data, start, pos));
    final decoded = raw.replaceAllMapped(
      RegExp(r'#([0-9A-Fa-f]{2})'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
    );
    return PdfName(decoded);
  }

  PdfString _readLiteralString() {
    pos++;
    final out = <int>[];
    var depth = 1;
    while (pos < data.length) {
      var c = data[pos++];
      if (c == 0x5c) {
        c = data[pos++];
        switch (c) {
          case 0x6e:
            out.add(0x0a);
          case 0x72:
            out.add(0x0d);
          case 0x74:
            out.add(0x09);
          case 0x62:
            out.add(0x08);
          case 0x66:
            out.add(0x0c);
          case 0x0d:
            if (pos < data.length && data[pos] == 0x0a) pos++;
          case 0x0a:
            break;
          default:
            if (c >= 0x30 && c <= 0x37) {
              var v = c - 0x30;
              for (var i = 0; i < 2 && pos < data.length && data[pos] >= 0x30 && data[pos] <= 0x37; i++) {
                v = v * 8 + data[pos++] - 0x30;
              }
              out.add(v & 0xff);
            } else {
              out.add(c);
            }
        }
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29 && --depth == 0) break;
      out.add(c);
    }
    return PdfString(Uint8List.fromList(out));
  }

  PdfString _readHexString() {
    pos++;
    final hex = StringBuffer();
    while (data[pos] != 0x3e) {
      final c = data[pos++];
      if (!isWhite(c)) hex.writeCharCode(c);
    }
    pos++;
    var s = hex.toString();
    if (s.length.isOdd) s += '0';
    return PdfString(
      Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]),
      hex: true,
    );
  }

  PdfObject _readDictOrStream() {
    pos += 2;
    final dict = PdfDict();
    while (true) {
      skipWhite();
      if (data[pos] == 0x3e && data[pos + 1] == 0x3e) {
        pos += 2;
        break;
      }
      final key = readObject();
      if (key is! PdfName) throw FormatException('Chiave di dizionario non valida alla posizione $pos');
      dict[key.value] = readObject();
    }
    final save = pos;
    if (readToken() != 'stream') {
      pos = save;
      return dict;
    }
    // Dopo "stream" segue CRLF o LF.
    if (data[pos] == 0x0d) pos++;
    if (data[pos] == 0x0a) pos++;
    final lenObj = dict['Length'];
    int? len;
    if (lenObj is PdfNumber) len = lenObj.intValue;
    if (lenObj is PdfRef && resolveLength != null) len = resolveLength!(lenObj);
    if (len == null || pos + len > data.length || !_endstreamAt(pos + len)) {
      len = _findEndstream(pos) - pos;
    }
    final streamData = Uint8List.sublistView(data, pos, pos + len);
    pos += len;
    readToken(); // endstream
    return PdfStream(dict, streamData);
  }

  bool _endstreamAt(int p) {
    final q = PdfParser(data, p)..skipWhite();
    return q.readToken() == 'endstream';
  }

  int _findEndstream(int from) {
    final marker = latin1.encode('endstream');
    outer:
    for (var i = from; i <= data.length - marker.length; i++) {
      for (var j = 0; j < marker.length; j++) {
        if (data[i + j] != marker[j]) continue outer;
      }
      var end = i;
      if (end > from && data[end - 1] == 0x0a) end--;
      if (end > from && data[end - 1] == 0x0d) end--;
      return end;
    }
    throw const FormatException('Stream PDF senza "endstream"');
  }
}
