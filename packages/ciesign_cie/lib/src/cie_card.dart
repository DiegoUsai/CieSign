import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'errors.dart';
import 'secure_messaging.dart';
import 'tlv.dart';

/// Canale verso la carta: su Android IsoDep, su iOS NFCISO7816Tag. È l'unica parte nativa.
abstract interface class ApduTransport {
  Future<Uint8List> transceive(Uint8List apdu);
}

/// Trasporto costruito da una funzione, comodo per i canali di piattaforma e i test.
class FunctionTransport implements ApduTransport {
  FunctionTransport(this._f);
  final Future<Uint8List> Function(Uint8List) _f;
  @override
  Future<Uint8List> transceive(Uint8List apdu) => _f(apdu);
}

String _h4(int sw) => sw.toRadixString(16).toUpperCase().padLeft(4, '0');

/// Dialogo con l'applicazione IAS ECC della CIE 3.0.
///
/// Porta in Dart di cie-core (Kotlin), a sua volta basato sul middleware e sull'SDK ufficiali
/// del Ministero dell'Interno e dell'IPZS (BSD-3-Clause, vedi THIRD_PARTY_NOTICES.md).
class CieCard {
  CieCard(this._transport, {void Function(String)? log, Uint8List? caPrivateExponent})
      : _log = log ?? ((_) {}),
        _caPrivateExponent = caPrivateExponent ?? CieConstants.caPrivateExponent;

  final ApduTransport _transport;
  final void Function(String) _log;
  final Uint8List _caPrivateExponent;

  var _dhG = Uint8List(0), _dhP = Uint8List(0), _dhQ = Uint8List(0);
  var _dhPrivate = Uint8List(0), _dhPublic = Uint8List(0), _dhIccPublic = Uint8List(0);
  var _caModulus = Uint8List(0), _caPubExp = Uint8List(0), _caCar = Uint8List(0), _caAid = Uint8List(0);
  var _dappModulus = Uint8List(0), _dappPubExp = Uint8List(0);
  SecureMessaging? _sm;

  static final _selectAid = [0x00, 0xA4, 0x04, 0x0C];
  static final _selectAidFci = [0x00, 0xA4, 0x04, 0x00];
  static final _getData = [0x00, 0xCB, 0x3F, 0xFF];

  /// Stabilisce il canale sicuro con la carta. Va chiamato prima di ogni altra operazione.
  Future<void> openSecureChannel() async {
    _log("Selezione dell'applicazione IAS");
    var ias = await _sendPlain(_selectAid, CieConstants.iasAid);
    if (!ias.isOk) {
      _log('Selezione IAS con P2=0C: SW=${_h4(ias.sw)}, riprovo con P2=00');
      ias = await _sendPlain(_selectAidFci, CieConstants.iasAid, le: 0x00);
      if (!ias.isOk) _log('Selezione IAS con P2=00: SW=${_h4(ias.sw)}');
    }
    final cie = await _sendPlain(_selectAid, CieConstants.cieAid);
    if (!cie.isOk) _log('Selezione AID CIE: SW=${_h4(cie.sw)}');

    _log('Lettura dei parametri Diffie-Hellman');
    try {
      _dhG = await _readDhParam(0x97);
    } on CardStatusException catch (e) {
      throw NotACieException('selezione IAS SW=${_h4(ias.sw)}, selezione CIE SW=${_h4(cie.sw)}, parametri DH SW=${_h4(e.sw)}');
    }
    _dhP = await _readDhParam(0x98);
    _dhQ = await _readDhParam(0x99);

    _log('Lettura della chiave pubblica della carta');
    await _readDappPublicKey();
    await _readExtAuthKeyParams();

    _log('Scambio di chiavi');
    await _dhKeyExchange();

    _log('Autenticazione reciproca con la carta');
    await _deviceAuthentication();
    _log('Canale sicuro attivo');
  }

  /// Verifica il PIN di 8 cifre.
  Future<void> verifyPin(String pin) async {
    if (!RegExp(r'^[0-9]{8}$').hasMatch(pin)) throw InvalidPinFormatException();
    final pinBytes = Uint8List.fromList(pin.codeUnits);
    try {
      final resp = await _sendSm([0x00, 0x20, 0x00, CieConstants.pinId], pinBytes, null);
      _checkPinStatus(resp.sw);
    } on CardStatusException catch (e) {
      _checkPinStatus(e.sw);
    } finally {
      pinBytes.fillRange(0, pinBytes.length, 0);
    }
  }

  /// Legge il certificato X.509 del titolare (file 1003) in DER.
  Future<Uint8List> readCertificate() async {
    _log('Lettura del certificato');
    final raw = await _readFileSm(CieConstants.certFileId);
    if (raw.isEmpty) throw CieProtocolException('Certificato vuoto');
    return trimDer(raw);
  }

  /// Firma con la chiave del titolare una struttura DigestInfo PKCS#1 (PIN già verificato).
  Future<Uint8List> signDigestInfo(List<int> digestInfo) async {
    _log("Firma dell'impronta");
    final mse = Bytes.concat([Tlv.encode(0x80, [0x02]), Tlv.encode(0x84, [CieConstants.signKeyId])]);
    _expectOk('impostazione della chiave di firma', await _sendSm([0x00, 0x22, 0x41, 0xA4], mse, null));
    final resp = _expectOk('firma', await _sendSm([0x00, 0x88, 0x00, 0x00], digestInfo, null));
    if (resp.data.isEmpty) throw CieProtocolException('La carta non ha restituito la firma');
    return resp.data;
  }

  // Fasi di apertura del canale

  Future<Uint8List> _readDhParam(int tag) async {
    final query = [0x4D, 0x0A, 0x70, 0x08, 0xBF, 0xA1, 0x01, 0x04, 0xA3, 0x02, tag, 0x00];
    final resp = _expectOk('lettura parametro DH', await _sendPlain(_getData, query));
    return Tlv.parse(resp.data).child(0).child(0).child(0).value;
  }

  Future<void> _readDappPublicKey() async {
    final tlv = Tlv.parse(await _readFilePlain(CieConstants.dappKeyFileId));
    _dappModulus = Bytes.stripLeadingZeros(tlv.child(0).value);
    _dappPubExp = Bytes.stripLeadingZeros(tlv.child(1).value);
  }

  Future<void> _readExtAuthKeyParams() async {
    final query = [0x4D, 0x09, 0x70, 0x07, 0xBF, 0xA0, 0x04, 0x03, 0x7F, 0x49, 0x80];
    final resp = _expectOk('lettura parametri di autenticazione', await _sendPlain(_getData, query));
    // I campi si cercano per tag e non per posizione: sulle carte reali il modulo non è il primo.
    final key = Tlv.parse(resp.data, reparse: true).child(0).child(0);
    _log('Struttura della chiave della CA: ${key.children.map((c) => '${Bytes.hex(c.tag)}(${c.value.length})').join(', ')}');
    _caModulus = Bytes.stripLeadingZeros(key.childWithTag([0x81]).value);
    _caPubExp = Bytes.stripLeadingZeros(key.childWithTag([0x82]).value);
    final cha = key.childWithTag([0x5F, 0x4C]).value;
    final chr = key.childWithTag([0x5F, 0x20]).value;
    _caCar = chr.sublist(4);
    _caAid = cha.sublist(0, 6);
  }

  Future<void> _dhKeyExchange() async {
    final q = Bytes.toBigInt(_dhQ);
    BigInt x;
    do {
      x = Bytes.toBigInt(Bytes.random(_dhQ.length));
    } while (x == BigInt.zero || x >= q);
    _dhPrivate = Bytes.toFixedLength(x, _dhQ.length);
    _dhPublic = CieCrypto.modPow(_dhG, _dhPrivate, _dhP);

    final mse = Bytes.concat([Tlv.encode(0x80, [0x9B]), Tlv.encode(0x83, [0x81]), Tlv.encode(0x91, _dhPublic)]);
    _expectOk('invio della chiave DH', await _sendPlain([0x00, 0x22, 0x41, 0xA6], mse));
    final resp = _expectOk(
      'lettura della chiave DH della carta',
      await _sendPlain(_getData, [0x4D, 0x04, 0xA6, 0x02, 0x91, 0x00]),
    );
    _dhIccPublic = Tlv.parse(resp.data, reparse: true).child(0).value;
    final secret = CieCrypto.modPow(_dhIccPublic, _dhPrivate, _dhP);
    final encKey = Bytes.sha256([secret, [0, 0, 0, 1]]).sublist(0, 16);
    final macKey = Bytes.sha256([secret, [0, 0, 0, 2]]).sublist(0, 16);
    _sm = SecureMessaging(encKey, macKey, [0, 0, 0, 0, 0, 0, 0, 1]);
  }

  Future<void> _deviceAuthentication() async {
    const shaSize = 32;
    final snIfd = [0x20, 0, 0, 0, 0, 0, 0, 0x01];
    final chr = Bytes.concat([[0, 0, 0, 0], snIfd]);
    final cha = Bytes.concat([_caAid, [0x01]]);
    final oid = [0x2A, 0x81, 0x22, 0xF4, 0x2A, 0x02, 0x04, 0x01, 0x04];
    final module = CieConstants.ifdModulus;
    final endEntityCert = Bytes.concat([[0x8A], _caCar, chr, cha, oid, module, CieConstants.ifdPublicExponent]);

    // Certificato verificabile dalla carta (CVC), firmato con lo schema ISO 9796-2.
    final headLen = _caModulus.length - shaSize - 2;
    final toSignCert = Bytes.concat([[0x6A], endEntityCert.sublist(0, headLen), Bytes.sha256([endEntityCert]), [0xBC]]);
    final certSignature = CieCrypto.modPow(toSignCert, _caPrivateExponent, _caModulus);
    if (!Bytes.equal(CieCrypto.modPow(certSignature, _caPubExp, _caModulus), toSignCert)) {
      throw CieProtocolException(
          'La chiave della CA letta dalla carta non corrisponde a quella attesa (modulo di ${_caModulus.length} byte)');
    }
    final remainder = endEntityCert.sublist(headLen);
    final cvc = Tlv.encode(
        0x7F21, Bytes.concat([Tlv.encode(0x5F37, certSignature), Tlv.encode(0x5F38, remainder), Tlv.encode(0x42, _caCar)]));

    _expectOk(
        'selezione della chiave di verifica',
        await _sendSm([0x00, 0x22, 0x81, 0xB6],
            Bytes.concat([Tlv.encode(0x80, [0x41]), Tlv.encode(0x83, [CieConstants.extAuthKeyId])]), null));
    _expectOk('verifica del certificato', await _sendSm([0x00, 0x2A, 0x00, 0xAE], cvc, null));
    _expectOk('impostazione del CHR', await _sendSm([0x00, 0x22, 0x81, 0xA4], Tlv.encode(0x83, chr), null));

    // Autenticazione esterna: il dispositivo dimostra di possedere la chiave IFD.
    final challenge = _expectOk('richiesta del challenge', await _sendSm([0x00, 0x84, 0x00, 0x00], const [], 8)).data;
    final padSize = module.length - shaSize - 2;
    final prnd = Bytes.random(padSize);
    final hash = Bytes.sha256([prnd, _dhPublic, snIfd, challenge, _dhIccPublic, _dhG, _dhP, _dhQ]);
    final toSignAuth = Bytes.concat([[0x6A], prnd, hash, [0xBC]]);
    final authSignature = CieCrypto.modPow(toSignAuth, CieConstants.ifdPrivateExponent, module);
    _expectOk('autenticazione esterna', await _sendSm([0x00, 0x82, 0x00, 0x00], Bytes.concat([snIfd, authSignature]), null));

    // Autenticazione interna: la carta dimostra di essere autentica.
    _expectOk(
        "impostazione dell'autenticazione interna",
        await _sendSm([0x00, 0x22, 0x41, 0xA4], Bytes.concat([Tlv.encode(0x84, [0x82]), Tlv.encode(0x80, [0x9B])]), null));
    final rndIfd = Bytes.random(8);
    final ia = _expectOk('autenticazione interna', await _sendSm([0x00, 0x88, 0x00, 0x00], rndIfd, null)).data;
    if (ia.length <= 8) throw CieProtocolException('Risposta di autenticazione interna troppo corta');
    final snIcc = ia.sublist(0, 8);
    final recovered = CieCrypto.modPow(ia.sublist(8), _dappPubExp, _dappModulus);
    if (recovered.first != 0x6A || recovered.last != 0xBC) {
      throw CieProtocolException('Autenticazione della carta non riuscita (formato)');
    }
    final prnd2 = recovered.sublist(1, recovered.length - shaSize - 1);
    final hashIcc = recovered.sublist(recovered.length - shaSize - 1, recovered.length - 1);
    final expected = Bytes.sha256([prnd2, _dhIccPublic, snIcc, rndIfd, _dhPublic, _dhG, _dhP, _dhQ]);
    if (!Bytes.equal(expected, hashIcc)) throw CieProtocolException('Autenticazione della carta non riuscita (impronta)');

    // Da qui il contatore riparte dai challenge scambiati.
    _sm = _sm!.withCounter(Bytes.concat([Bytes.right(challenge, 4), Bytes.right(rndIfd, 4)]));
  }

  // Trasporto

  Future<ApduResponse> _transmit(List<int> apdu) async =>
      ApduResponse.parse(await _transport.transceive(Uint8List.fromList(apdu)));

  /// Comando in chiaro, con concatenamento oltre 255 byte e GET RESPONSE.
  Future<ApduResponse> _sendPlain(List<int> header, List<int> data, {int? le}) async {
    var offset = 0;
    while (true) {
      final chunk = data.sublist(offset, offset + 255 < data.length ? offset + 255 : data.length);
      offset += chunk.length;
      final last = offset >= data.length;
      final h = List<int>.of(header);
      if (!last) h[0] |= 0x10;
      final apdu = [...h, if (chunk.isNotEmpty) ...[chunk.length, ...chunk], if (le != null) le];
      final resp = await _transmit(apdu);
      if (!last) {
        if (!resp.isOk) throw CardStatusException('comando concatenato', resp.sw);
        continue;
      }
      return _collectGetResponse(resp);
    }
  }

  Future<ApduResponse> _collectGetResponse(ApduResponse first) async {
    var resp = first;
    final data = BytesBuilder()..add(first.data);
    while ((resp.sw >> 8) == 0x61) {
      resp = await _transmit([0x00, 0xC0, 0x00, 0x00, resp.sw & 0xFF]);
      data.add(resp.data);
    }
    return ApduResponse(data.toBytes(), resp.sw);
  }

  /// Comando protetto, con concatenamento oltre 0xE7 byte.
  Future<ApduResponse> _sendSm(List<int> header, List<int> data, int? le) async {
    final channel = _sm ?? (throw StateError('Canale sicuro non attivo'));
    var offset = 0;
    while (true) {
      final end = offset + SecureMessaging.maxChunk < data.length ? offset + SecureMessaging.maxChunk : data.length;
      final chunk = data.sublist(offset, end);
      offset += chunk.length;
      final last = offset >= data.length;
      final h = List<int>.of(header);
      if (!last) h[0] |= 0x10;
      final raw = await _collectGetResponse(await _transmit(channel.wrap(h, chunk, last ? le : null)));
      final ApduResponse resp;
      if (raw.sw == 0x9000 || raw.sw == 0x6282 || raw.sw == 0x6B00) {
        resp = channel.unwrap(raw.data);
      } else {
        throw CardStatusException(last ? 'comando protetto' : 'comando protetto concatenato', raw.sw);
      }
      if (!last) {
        if (!resp.isOk) throw CardStatusException('comando protetto concatenato', resp.sw);
        continue;
      }
      return resp;
    }
  }

  Future<Uint8List> _readFilePlain(int fileId) async {
    final select = await _sendPlain([0x00, 0xA4, 0x02, 0x04], _fileIdBytes(fileId));
    if (!select.isOk) _log('Selezione del file ${_h4(fileId)}: SW=${_h4(select.sw)}');
    final content = BytesBuilder();
    while (true) {
      var resp = await _sendPlain(_readBinaryHeader(content.length), const [], le: 0x00);
      if ((resp.sw >> 8) == 0x6C) resp = await _sendPlain(_readBinaryHeader(content.length), const [], le: resp.sw & 0xFF);
      if (resp.isOk && resp.data.isNotEmpty) {
        content.add(resp.data);
      } else {
        if (resp.sw == 0x6282) content.add(resp.data);
        return content.toBytes();
      }
    }
  }

  Future<Uint8List> _readFileSm(int fileId) async {
    _expectOk('selezione del file', await _sendSm([0x00, 0xA4, 0x02, 0x04], _fileIdBytes(fileId), null));
    final content = BytesBuilder();
    while (true) {
      var resp = await _sendSm(_readBinaryHeader(content.length), const [], 0x00);
      if ((resp.sw >> 8) == 0x6C) resp = await _sendSm(_readBinaryHeader(content.length), const [], resp.sw & 0xFF);
      if (resp.isOk && resp.data.isNotEmpty) {
        content.add(resp.data);
      } else {
        if (resp.sw == 0x6282) content.add(resp.data);
        return content.toBytes();
      }
    }
  }

  List<int> _readBinaryHeader(int offset) => [0x00, 0xB0, (offset >> 8) & 0xFF, offset & 0xFF];

  List<int> _fileIdBytes(int id) => [(id >> 8) & 0xFF, id & 0xFF];

  ApduResponse _expectOk(String step, ApduResponse resp) {
    if (!resp.isOk) throw CardStatusException(step, resp.sw);
    return resp;
  }

  void _checkPinStatus(int sw) {
    if (sw == 0x9000) return;
    if ((sw & 0xFFF0) == 0x63C0) {
      final left = sw & 0x0F;
      if (left == 0) throw PinBlockedException();
      throw WrongPinException(left);
    }
    if (sw == 0x6983) throw PinBlockedException();
    throw CardStatusException('verifica del PIN', sw);
  }

  /// Elimina eventuali byte di riempimento dopo la struttura DER del certificato.
  static Uint8List trimDer(Uint8List raw) {
    if (raw.length < 2 || raw[0] != 0x30) return raw;
    var len = raw[1];
    var header = 2;
    if (len > 0x80) {
      final n = len - 0x80;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | raw[2 + i];
      }
      header += n;
    }
    final total = header + len;
    return total <= raw.length ? raw.sublist(0, total) : raw;
  }
}
