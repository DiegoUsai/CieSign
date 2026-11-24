import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import '../cie_card.dart';
import '../constants.dart';
import '../tlv.dart';

import 'keys.dart';

BigInt _b(String h) => BigInt.parse(h, radix: 16);

/// Simulatore della parte carta del protocollo IAS ECC (porta di SimulatedCie.kt), solo per i test.
/// Il certificato e le chiavi sono di prova e non appartengono a nessuna persona reale.
class SimulatedCie implements ApduTransport {
  SimulatedCie({this.pin = '12345678', this.remainingAttempts = 3, this.plainPinErrors = false, this.rejectSelectWithoutFci = false});

  final String pin;
  int remainingAttempts;
  final bool plainPinErrors;
  final bool rejectSelectWithoutFci;

  final Uint8List certificateDer = base64Decode(holderCertBase64);
  final _holderN = _b(holderN), _holderD = _b(holderD);
  final _caN = _b(caN);
  late final Uint8List caPrivateExponent = Bytes.toFixedLength(_b(caD), 256);
  final _dappN = _b(dappN), _dappD = _b(dappD);
  final _e = BigInt.from(65537);

  // Gruppo MODP a 1024 bit di RFC 2409 (gruppo 2), g = 2.
  final _dhP = _b('FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD'
      'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF');
  final _dhG = BigInt.two;
  final _dhQ = _b('F7E75FDC469067FFDC4E847C51F452DF00000000000000000000000000000001');
  late final _dhPrivate = Bytes.toBigInt(Bytes.random(31)) + BigInt.one;
  late final Uint8List _dhIccPublic = Bytes.toFixedLength(_dhG.modPow(_dhPrivate, _dhP), 128);
  var _dhIfdPublic = Uint8List(0);

  var _encKey = Uint8List(0), _macKey = Uint8List(0), _ssc = Uint8List(8);
  var _smActive = false;
  var _selectedFile = 0;
  var _challenge = Uint8List(0);
  var _ifdAuthenticated = false, _pinVerified = false, _signKeySelected = false;
  var _chainBuffer = Uint8List(0), _pending = Uint8List(0);
  int commandCount = 0;

  final _chr = Bytes.fromHex('495400000000000000000001');
  final _cha = Bytes.fromHex('A0000000308001');

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    commandCount++;
    if (apdu[1] == 0xC0) return _sendPending(apdu[4]);
    return (apdu[0] & 0x0C) == 0x0C ? _handleSm(apdu) : _handlePlain(apdu);
  }

  Uint8List _sw(int v) => Uint8List.fromList([v >> 8, v & 0xFF]);

  Uint8List _handlePlain(Uint8List apdu) {
    final cla = apdu[0], ins = apdu[1], p1 = apdu[2], p2 = apdu[3];
    final data = apdu.length > 5 ? apdu.sublist(5, 5 + apdu[4]) : Uint8List(0);
    if (cla & 0x10 != 0) {
      _chainBuffer = Bytes.concat([_chainBuffer, data]);
      return _sw(0x9000);
    }
    final full = Bytes.concat([_chainBuffer, data]);
    _chainBuffer = Uint8List(0);
    if (ins == 0xA4 && p1 == 0x04 && p2 == 0x0C && rejectSelectWithoutFci) return _sw(0x6A86);
    if (ins == 0xA4 && p1 == 0x04) {
      return Bytes.equal(full, CieConstants.iasAid) || Bytes.equal(full, CieConstants.cieAid) ? _sw(0x9000) : _sw(0x6A82);
    }
    if (ins == 0xA4 && p1 == 0x02) {
      _selectedFile = (full[0] << 8) | full[1];
      return _sw(0x9000);
    }
    if (ins == 0xB0) return _readBinary((p1 << 8) | p2, apdu.last == 0 ? 256 : apdu.last, plain: true);
    if (ins == 0xCB) return _getData(full);
    if (ins == 0x22 && p2 == 0xA6) {
      final parsed = Tlv.parse(Bytes.concat([[0x30], Tlv.encodeLength(full.length), full]));
      _dhIfdPublic = parsed.children.firstWhere((c) => c.tag[0] == 0x91).value;
      final secret = Bytes.toFixedLength(Bytes.toBigInt(_dhIfdPublic).modPow(_dhPrivate, _dhP), 128);
      _encKey = Bytes.sha256([secret, [0, 0, 0, 1]]).sublist(0, 16);
      _macKey = Bytes.sha256([secret, [0, 0, 0, 2]]).sublist(0, 16);
      _ssc = Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 1]);
      _smActive = true;
      return _sw(0x9000);
    }
    return _sw(0x6D00);
  }

  Uint8List _tag3(int tag, List<int> value) =>
      Bytes.concat([[tag >> 16, (tag >> 8) & 0xFF, tag & 0xFF], Tlv.encodeLength(value.length), value]);

  Uint8List _getData(Uint8List q) {
    final tag = q.last == 0 ? q[q.length - 2] : q.last;
    Uint8List body;
    if (Bytes.equal(q, [0x4D, 0x04, 0xA6, 0x02, 0x91, 0x00])) {
      body = Tlv.encode(0xA6, Tlv.encode(0x91, _dhIccPublic));
    } else if (q[4] == 0xBF && q[5] == 0xA1) {
      final value = switch (tag) {
        0x97 => Uint8List.fromList([2]),
        0x98 => Bytes.toFixedLength(_dhP, 128),
        0x99 => Bytes.toFixedLength(_dhQ, 32),
        _ => null,
      };
      if (value == null) return _sw(0x6A88);
      body = Tlv.encode(0x70, _tag3(0xBFA101, Tlv.encode(0xA3, Tlv.encode(tag, value))));
    } else if (q[4] == 0xBF && q[5] == 0xA0) {
      final key = Bytes.concat([
        Tlv.encode(0x5F20, _chr),
        Tlv.encode(0x5F4C, _cha),
        Tlv.encode(0x81, Bytes.toFixedLength(_caN, 256)),
        Tlv.encode(0x82, [1, 0, 1]),
      ]);
      body = Tlv.encode(0x70, _tag3(0xBFA004, Tlv.encode(0x7F49, key)));
    } else {
      return _sw(0x6A88);
    }
    return _respondWithGetResponse(body);
  }

  Uint8List _respondWithGetResponse(Uint8List body) {
    _pending = body;
    return _sw(0x6100 | (body.length > 0xFF ? 0 : body.length));
  }

  Uint8List _sendPending(int le) {
    final n = le == 0 ? (256 < _pending.length ? 256 : _pending.length) : (le < _pending.length ? le : _pending.length);
    final chunk = _pending.sublist(0, n);
    _pending = _pending.sublist(n);
    final status = _pending.isEmpty ? 0x9000 : 0x6100 | (_pending.length > 0xFF ? 0 : _pending.length);
    return Bytes.concat([chunk, _sw(status)]);
  }

  Uint8List _handleSm(Uint8List apdu) {
    if (!_smActive) throw StateError('Comando protetto prima dello scambio di chiavi');
    final body = apdu.sublist(5, 5 + apdu[4]);
    Bytes.increment(_ssc);
    var pos = 0;
    final dataObjects = BytesBuilder();
    var plain = Uint8List(0);
    int? le;
    var mac = Uint8List(0);
    while (pos < body.length) {
      final tag = body[pos];
      var len = body[pos + 1];
      var hdr = 2;
      if (len > 0x80) {
        final n = len - 0x80;
        len = 0;
        for (var i = 0; i < n; i++) {
          len = (len << 8) | body[pos + 2 + i];
        }
        hdr += n;
      }
      final whole = body.sublist(pos, pos + hdr + len);
      final value = body.sublist(pos + hdr, pos + hdr + len);
      switch (tag) {
        case 0x87:
          dataObjects.add(whole);
          plain = Bytes.isoUnpad(CieCrypto.tdesDecrypt(_encKey, value.sublist(1)));
        case 0x85:
          dataObjects.add(whole);
          plain = Bytes.isoUnpad(CieCrypto.tdesDecrypt(_encKey, value));
        case 0x97:
          dataObjects.add(whole);
          le = value[0];
        case 0x8E:
          mac = value;
        default:
          throw StateError('DO inatteso $tag');
      }
      pos += hdr + len;
    }
    final header = apdu.sublist(0, 4);
    final expectedMac = CieCrypto.retailMac(
        _macKey, Bytes.isoPad(Bytes.concat([Bytes.isoPad(Bytes.concat([_ssc, header])), dataObjects.toBytes()])));
    if (!Bytes.equal(expectedMac, mac)) throw StateError('MAC del comando non valido');
    if (apdu[0] & 0x10 != 0) {
      _chainBuffer = Bytes.concat([_chainBuffer, plain]);
      return _smResponse(Uint8List(0), 0x9000);
    }
    final full = Bytes.concat([_chainBuffer, plain]);
    _chainBuffer = Uint8List(0);
    return _execute(header, full, le);
  }

  Uint8List _execute(Uint8List header, Uint8List data, int? le) {
    final ins = header[1], p1 = header[2], p2 = header[3];
    switch (ins) {
      case 0x22:
        _signKeySelected = p1 == 0x41 && p2 == 0xA4 && Bytes.equal(data, Bytes.fromHex('800102840181'));
        return _smResponse(Uint8List(0), 0x9000);
      case 0x2A:
        return _smResponse(Uint8List(0), _verifyCvc(data) ? 0x9000 : 0x6300);
      case 0x84:
        _challenge = Bytes.random(le ?? 8);
        return _smResponse(_challenge, 0x9000);
      case 0x82:
        _ifdAuthenticated = _verifyExternalAuth(data);
        return _smResponse(Uint8List(0), _ifdAuthenticated ? 0x9000 : 0x6300);
      case 0x88:
        return _signKeySelected ? _sign(data) : _internalAuth(data);
      case 0x20:
        return _verifyPin(data);
      case 0xA4:
        _selectedFile = (data[0] << 8) | data[1];
        return _smResponse(Uint8List(0), 0x9000);
      case 0xB0:
        return _readBinary((p1 << 8) | p2, le == null || le == 0 ? 256 : le, plain: false);
      default:
        return _smResponse(Uint8List(0), 0x6D00);
    }
  }

  bool _verifyCvc(Uint8List cvc) {
    final root = Tlv.parse(cvc);
    final sig = root.childWithTag([0x5F, 0x37]).value;
    final remainder = root.childWithTag([0x5F, 0x38]).value;
    final rec = Bytes.toFixedLength(Bytes.toBigInt(sig).modPow(_e, _caN), 256);
    if (rec.first != 0x6A || rec.last != 0xBC) return false;
    final head = rec.sublist(1, rec.length - 33);
    final hash = rec.sublist(rec.length - 33, rec.length - 1);
    return Bytes.equal(Bytes.sha256([head, remainder]), hash);
  }

  Uint8List get _gBytes => Uint8List.fromList([2]);

  bool _verifyExternalAuth(Uint8List data) {
    final snIfd = data.sublist(0, 8);
    final sig = data.sublist(8);
    final n = Bytes.toBigInt(CieConstants.ifdModulus);
    final rec = Bytes.toFixedLength(Bytes.toBigInt(sig).modPow(Bytes.toBigInt(CieConstants.ifdPublicExponent), n), 256);
    if (rec.first != 0x6A || rec.last != 0xBC) return false;
    final prnd = rec.sublist(1, rec.length - 33);
    final hash = rec.sublist(rec.length - 33, rec.length - 1);
    final expected = Bytes.sha256([prnd, _dhIfdPublic, snIfd, _challenge, _dhIccPublic, _gBytes,
      Bytes.toFixedLength(_dhP, 128), Bytes.toFixedLength(_dhQ, 32)]);
    return Bytes.equal(expected, hash);
  }

  Uint8List _internalAuth(Uint8List rndIfd) {
    if (!_ifdAuthenticated) throw StateError('Autenticazione interna prima di quella esterna');
    final snIcc = Bytes.fromHex('0102030405060708');
    const k = 256;
    final prnd2 = Bytes.random(k - 34);
    final hash = Bytes.sha256([prnd2, _dhIccPublic, snIcc, rndIfd, _dhIfdPublic, _gBytes,
      Bytes.toFixedLength(_dhP, 128), Bytes.toFixedLength(_dhQ, 32)]);
    final block = Bytes.concat([[0x6A], prnd2, hash, [0xBC]]);
    final sig = Bytes.toFixedLength(Bytes.toBigInt(block).modPow(_dappD, _dappN), k);
    final response = _smResponse(Bytes.concat([snIcc, sig]), 0x9000);
    _ssc = Bytes.concat([Bytes.right(_challenge, 4), Bytes.right(rndIfd, 4)]);
    return response;
  }

  Uint8List _verifyPin(Uint8List data) {
    if (remainingAttempts == 0) return _pinError(0x6983);
    if (String.fromCharCodes(data) == pin) {
      remainingAttempts = 3;
      _pinVerified = true;
      return _smResponse(Uint8List(0), 0x9000);
    }
    remainingAttempts--;
    return _pinError(0x63C0 | remainingAttempts);
  }

  Uint8List _pinError(int status) => plainPinErrors ? _sw(status) : _smResponse(Uint8List(0), status);

  Uint8List _sign(Uint8List digestInfo) {
    _signKeySelected = false;
    if (!_pinVerified) return _smResponse(Uint8List(0), 0x6982);
    const k = 256;
    final em = Uint8List(k)
      ..[1] = 1
      ..fillRange(2, k - digestInfo.length - 1, 0xFF)
      ..setAll(k - digestInfo.length, digestInfo);
    return _smResponse(Bytes.toFixedLength(Bytes.toBigInt(em).modPow(_holderD, _holderN), k), 0x9000);
  }

  Uint8List _readBinary(int offset, int le, {required bool plain}) {
    Uint8List content;
    if (_selectedFile == 0x1003) {
      if (!plain && !_pinVerified) return _smResponse(Uint8List(0), 0x6982);
      content = Bytes.concat([certificateDer, Uint8List(64)]);
    } else if (_selectedFile == 0x1004) {
      content = Tlv.encode(0x30, Bytes.concat([
        Tlv.encode(0x02, Bytes.concat([[0], Bytes.toFixedLength(_dappN, 256)])),
        Tlv.encode(0x02, [1, 0, 1]),
      ]));
    } else {
      return plain ? _sw(0x6A82) : _smResponse(Uint8List(0), 0x6A82);
    }
    if (offset >= content.length) return plain ? _sw(0x6B00) : _smResponse(Uint8List(0), 0x6B00, outer: 0x6B00);
    final chunk = content.sublist(offset, offset + le < content.length ? offset + le : content.length);
    final status = chunk.length < le ? 0x6282 : 0x9000;
    return plain ? Bytes.concat([chunk, _sw(status)]) : _smResponse(chunk, status, outer: status);
  }

  Uint8List _smResponse(Uint8List data, int status, {int outer = 0x9000}) {
    Bytes.increment(_ssc);
    final enc = data.isNotEmpty
        ? Tlv.encode(0x87, Bytes.concat([[0x01], CieCrypto.tdesEncrypt(_encKey, Bytes.isoPad(data))]))
        : Uint8List(0);
    final st = Tlv.encode(0x99, [status >> 8, status & 0xFF]);
    final mac = CieCrypto.retailMac(_macKey, Bytes.isoPad(Bytes.concat([_ssc, enc, st])));
    final body = Bytes.concat([enc, st, Tlv.encode(0x8E, mac)]);
    if (body.length > 200 && outer == 0x9000) return _respondWithGetResponse(body);
    return Bytes.concat([body, _sw(outer)]);
  }

  BigInt get holderModulus => _holderN;
}
