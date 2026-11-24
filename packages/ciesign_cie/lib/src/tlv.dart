import 'dart:typed_data';

import 'bytes.dart';
import 'errors.dart';

/// Codifica e decodifica minima di strutture BER-TLV per i comandi IAS ECC della CIE.
class Tlv {
  Tlv(this.tag, this.value, this.children);

  final Uint8List tag;
  final Uint8List value;
  final List<Tlv> children;

  Tlv child(int index) {
    if (index >= children.length) {
      throw CieProtocolException('Struttura TLV inattesa: manca il figlio $index del tag ${Bytes.hex(tag)}');
    }
    return children[index];
  }

  Tlv childWithTag(List<int> wanted) {
    for (final c in children) {
      if (Bytes.equal(c.tag, wanted)) return c;
    }
    throw CieProtocolException('Struttura TLV inattesa: manca il tag ${Bytes.hex(wanted)}');
  }

  /// Codifica un oggetto TLV; il tag può occupare uno o due byte.
  static Uint8List encode(int tag, List<int> value) {
    final tagBytes = tag > 0xFF ? [(tag >> 8) & 0xFF, tag & 0xFF] : [tag];
    return Bytes.concat([tagBytes, encodeLength(value.length), value]);
  }

  static Uint8List encodeLength(int len) {
    if (len < 0x80) return Uint8List.fromList([len]);
    if (len <= 0xFF) return Uint8List.fromList([0x81, len]);
    if (len <= 0xFFFF) return Uint8List.fromList([0x82, len >> 8, len & 0xFF]);
    throw ArgumentError('Lunghezza TLV non supportata: $len');
  }

  /// Analizza il primo oggetto TLV di [data]. Con [reparse] analizza come TLV anche il
  /// contenuto di OCTET STRING e BIT STRING, come fa il middleware ufficiale.
  static Tlv parse(List<int> data, {bool reparse = false}) => _parseAt(data, 0, data.length, reparse).$1;

  static (Tlv, int) _parseAt(List<int> data, int start, int end, bool reparse) {
    var pos = start;
    int next() {
      if (pos >= end) throw CieProtocolException('TLV troncato');
      return data[pos++];
    }

    final tagStart = pos;
    final first = next();
    if (first & 0x1F == 0x1F) {
      while (next() & 0x80 == 0x80) {}
    }
    final tag = Uint8List.fromList(data.sublist(tagStart, pos));
    var len = next();
    if (len > 0x80) {
      final lenLen = len - 0x80;
      len = 0;
      for (var i = 0; i < lenLen; i++) {
        len = (len << 8) | next();
      }
    }
    if (pos + len > end) throw CieProtocolException('Lunghezza TLV oltre i limiti');
    final valueStart = pos, valueEnd = pos + len;
    final value = Uint8List.fromList(data.sublist(valueStart, valueEnd));
    final tagId = tag[0];
    final constructed = tagId & 0x20 != 0;
    final List<Tlv> children;
    if (constructed) {
      children = _parseChildren(data, valueStart, valueEnd, reparse);
    } else if (reparse && tag.length == 1 && tagId == 0x04) {
      children = _tryParseChildren(data, valueStart, valueEnd, reparse);
    } else if (reparse && tag.length == 1 && tagId == 0x03 && len > 1) {
      children = _tryParseChildren(data, valueStart + 1, valueEnd, reparse);
    } else {
      children = const [];
    }
    return (Tlv(tag, value, children), valueEnd);
  }

  static List<Tlv> _parseChildren(List<int> data, int start, int end, bool reparse) {
    final list = <Tlv>[];
    var pos = start;
    while (pos < end) {
      // Coppie 00 00 di riempimento: si saltano.
      if (pos + 1 < end && data[pos] == 0 && data[pos + 1] == 0) {
        pos += 2;
        continue;
      }
      final (child, next) = _parseAt(data, pos, end, reparse);
      list.add(child);
      pos = next;
    }
    return list;
  }

  static List<Tlv> _tryParseChildren(List<int> data, int start, int end, bool reparse) {
    try {
      return _parseChildren(data, start, end, reparse);
    } on CieProtocolException {
      return const [];
    }
  }
}
