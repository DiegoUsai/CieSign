import 'dart:typed_data';

import 'bytes.dart';
import 'errors.dart';
import 'tlv.dart';

/// Risposta di un comando APDU: dati e status word.
class ApduResponse {
  ApduResponse(this.data, this.sw);

  final Uint8List data;
  final int sw;

  bool get isOk => sw == 0x9000;

  static ApduResponse parse(List<int> raw) {
    if (raw.length < 2) throw CieProtocolException('Risposta APDU troppo corta');
    return ApduResponse(Uint8List.fromList(raw.sublist(0, raw.length - 2)), (raw[raw.length - 2] << 8) | raw[raw.length - 1]);
  }
}

/// Secure messaging ISO/IEC 7816-4 con 3DES e Retail MAC, nella variante usata dalla CIE.
class SecureMessaging {
  SecureMessaging(this._encKey, this._macKey, List<int> initialSsc) : _ssc = Uint8List.fromList(initialSsc);

  final Uint8List _encKey;
  final Uint8List _macKey;
  final Uint8List _ssc;

  /// Dimensione massima dei dati in chiaro per comando, come nel middleware ufficiale.
  static const maxChunk = 0xE7;

  Uint8List get sendSequenceCounter => Uint8List.fromList(_ssc);

  /// Protegge un comando: [header] è CLA INS P1 P2, [data] il campo dati in chiaro.
  Uint8List wrap(List<int> header, List<int> data, int? le) {
    if (header.length != 4) throw ArgumentError('Intestazione di 4 byte');
    if (data.length > maxChunk) throw ArgumentError('Campo dati troppo lungo per un singolo comando protetto');
    Bytes.increment(_ssc);
    final smHeader = Uint8List.fromList(header)..[0] = header[0] | 0x0C;
    final dataObjects = BytesBuilder();
    if (data.isNotEmpty) {
      final encrypted = CieCrypto.tdesEncrypt(_encKey, Bytes.isoPad(data));
      final odd = header[1] & 0x01 == 1;
      dataObjects.add(odd ? Tlv.encode(0x85, encrypted) : Tlv.encode(0x87, [0x01, ...encrypted]));
    }
    if (le != null) dataObjects.add(Tlv.encode(0x97, [le & 0xFF]));
    final dos = dataObjects.toBytes();
    final macInput = Bytes.isoPad(Bytes.concat([Bytes.isoPad(Bytes.concat([_ssc, smHeader])), dos]));
    final mac = CieCrypto.retailMac(_macKey, macInput);
    final body = Bytes.concat([dos, Tlv.encode(0x8E, mac)]);
    return Bytes.concat([smHeader, [body.length], body, [0x00]]);
  }

  /// Verifica il MAC e decifra il corpo di una risposta protetta.
  ApduResponse unwrap(List<int> body) {
    Bytes.increment(_ssc);
    var encObject = Uint8List(0);
    Uint8List? encData;
    var statusObject = Uint8List(0);
    var sw = -1;
    var macVerified = false;
    var pos = 0;
    while (pos < body.length) {
      final tag = body[pos];
      final lenPos = pos + 1;
      if (lenPos >= body.length) throw SecureMessagingException('Risposta protetta troncata');
      var len = body[lenPos];
      var lenBytes = 1;
      if (len > 0x80) {
        final n = len - 0x80;
        len = 0;
        for (var i = 1; i <= n; i++) {
          len = (len << 8) | body[lenPos + i];
        }
        lenBytes += n;
      }
      final valueStart = lenPos + lenBytes, valueEnd = valueStart + len;
      if (valueEnd > body.length) throw SecureMessagingException('Lunghezza errata nella risposta protetta');
      final whole = Uint8List.fromList(body.sublist(pos, valueEnd));
      final value = Uint8List.fromList(body.sublist(valueStart, valueEnd));
      switch (tag) {
        case 0x87:
          if (value.isEmpty || value[0] != 0x01) throw SecureMessagingException('Indicatore di padding inatteso nel DO 87');
          encObject = whole;
          encData = value.sublist(1);
        case 0x85:
          encObject = whole;
          encData = value;
        case 0x99:
          if (len != 2) throw SecureMessagingException('DO 99 di lunghezza errata');
          statusObject = whole;
          sw = (value[0] << 8) | value[1];
        case 0x8E:
          if (len != 8) throw SecureMessagingException('MAC di lunghezza errata');
          final expected = CieCrypto.retailMac(_macKey, Bytes.isoPad(Bytes.concat([_ssc, encObject, statusObject])));
          if (!Bytes.equal(expected, value)) throw SecureMessagingException('MAC della risposta non valido');
          macVerified = true;
        default:
          throw SecureMessagingException('Tag ${tag.toRadixString(16).toUpperCase()} inatteso nella risposta protetta');
      }
      pos = valueEnd;
    }
    if (!macVerified) throw SecureMessagingException('Risposta protetta senza MAC');
    if (sw < 0) throw SecureMessagingException('Risposta protetta senza status word');
    final plain = encData == null ? Uint8List(0) : Bytes.isoUnpad(CieCrypto.tdesDecrypt(_encKey, encData));
    return ApduResponse(plain, sw);
  }

  /// Nuova istanza con le stesse chiavi e un contatore diverso.
  SecureMessaging withCounter(List<int> newSsc) => SecureMessaging(_encKey, _macKey, newSsc);
}
