import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';
import 'oids.dart';

/// Certificato **X.509** letto quanto basta per firmare e mostrare il titolare.
class Certificate {
  Certificate._(this.der, this._root);

  factory Certificate.fromDer(Uint8List der) {
    final root = DerNode.parse(der);
    if (root.tag != DerTag.sequence || root.length < 3) throw const FormatException('Certificato X.509 non valido');
    return Certificate._(Uint8List.fromList(root.raw), root);
  }

  final Uint8List der;
  final DerNode _root;

  DerNode get _tbs => _root[0];

  /// Indice dei campi del TBSCertificate, che ha la versione facoltativa in [0].
  int get _o => _tbs[0].tag == DerTag.context(0) ? 1 : 0;

  BigInt get serialNumber => _tbs[_o].asBigInt;

  /// Numero di serie già codificato in DER (INTEGER), per le richieste OCSP.
  Uint8List get serialNumberDer => Uint8List.fromList(_tbs[_o].raw);

  /// Nome dell'emittente così come codificato nel certificato.
  Uint8List get issuerDer => Uint8List.fromList(_tbs[_o + 2].raw);
  Uint8List get subjectDer => Uint8List.fromList(_tbs[_o + 4].raw);

  DistinguishedName get issuer => DistinguishedName(_tbs[_o + 2]);
  DistinguishedName get subject => DistinguishedName(_tbs[_o + 4]);

  DateTime get notBefore => _tbs[_o + 3][0].asTime;
  DateTime get notAfter => _tbs[_o + 3][1].asTime;

  /// Chiave pubblica **RSA**, l'unico tipo usato dalla CIE 3.0.
  RsaPublicKey get rsaPublicKey {
    final spki = _tbs[_o + 5];
    final alg = spki[0][0].asOid;
    if (alg != Oids.rsaEncryption) throw UnsupportedError('Chiave pubblica non RSA ($alg)');
    final bits = spki[1].content;
    final key = DerNode.parse(Uint8List.sublistView(bits, 1));
    return RsaPublicKey(key[0].asBigInt, key[1].asBigInt);
  }

  Uint8List get sha256Fingerprint => Uint8List.fromList(sha256.convert(der).bytes);

  /// Parte firmata dall'emittente (TBSCertificate) e firma dell'emittente.
  Uint8List get tbsDer => Uint8List.fromList(_tbs.raw);
  String get signatureAlgorithm => _root[1][0].asOid;
  Uint8List get signatureValue => Uint8List.sublistView(_root[2].content, 1);

  /// Estensioni X.509 per OID, con il valore già estratto dall'OCTET STRING.
  Map<String, DerNode> get _extensions {
    final out = <String, DerNode>{};
    for (final n in _tbs.children) {
      if (n.tag != DerTag.context(3)) continue;
      for (final ext in n[0].children) {
        final value = ext[ext.length - 1];
        out[ext[0].asOid] = DerNode.parse(Uint8List.fromList(value.content));
      }
    }
    return out;
  }

  /// Valore della chiave pubblica (BIT STRING senza il byte dei bit inutilizzati):
  /// la sua impronta SHA-1 identifica l'emittente nelle richieste OCSP.
  Uint8List get subjectPublicKeyBits => Uint8List.sublistView(_tbs[_o + 5][1].content, 1);

  /// Indirizzi dei servizi OCSP (estensione AuthorityInfoAccess).
  List<Uri> get ocspUrls => _accessUrls(Oids.authorityInfoAccess, Oids.adOcsp);

  /// Indirizzi da cui scaricare il certificato dell'emittente (AIA caIssuers).
  List<Uri> get caIssuersUrls => _accessUrls(Oids.authorityInfoAccess, Oids.adCaIssuers);

  List<Uri> _accessUrls(String ext, String method) {
    final aia = _extensions[ext];
    if (aia == null) return const [];
    final out = <Uri>[];
    for (final ad in aia.children) {
      if (ad.length < 2 || ad[0].asOid != method) continue;
      final u = _uriOf(ad[1]);
      if (u != null) out.add(u);
    }
    return out;
  }

  /// Indirizzi delle liste di revoca (estensione CRLDistributionPoints).
  List<Uri> get crlUrls {
    final dp = _extensions[Oids.crlDistributionPoints];
    if (dp == null) return const [];
    final out = <Uri>[];
    void collect(DerNode n) {
      if (n.tag == 0x86) {
        final u = _uriOf(n);
        if (u != null) out.add(u);
        return;
      }
      if (n.isConstructed) {
        for (final c in n.children) {
          collect(c);
        }
      }
    }

    collect(dp);
    return out;
  }

  static Uri? _uriOf(DerNode n) {
    if (n.tag != 0x86) return null;
    final u = Uri.tryParse(String.fromCharCodes(n.content));
    return u != null && (u.scheme == 'http' || u.scheme == 'https') ? u : null;
  }

  /// Vero se il certificato è abilitato a firmare risposte OCSP (id-kp-OCSPSigning).
  bool get allowsOcspSigning {
    final eku = _extensions[Oids.extKeyUsage];
    if (eku == null) return false;
    return eku.children.any((n) => n.tag == DerTag.oid && n.asOid == Oids.kpOcspSigning);
  }

  /// Vero se l'estensione KeyUsage consente digitalSignature; vero anche se
  /// l'estensione manca, perché allora l'uso non è limitato.
  bool get allowsDigitalSignature {
    final ku = _extensions[Oids.keyUsage];
    if (ku == null) return true;
    final bits = ku.content;
    return bits.length > 1 && (bits[1] & 0x80) != 0;
  }

  /// Vero se BasicConstraints dichiara il certificato come CA.
  bool get isCa {
    final bc = _extensions[Oids.basicConstraints];
    if (bc == null || bc.length == 0) return false;
    final first = bc[0];
    return first.tag == DerTag.boolean && first.content.isNotEmpty && first.content[0] != 0;
  }

  /// Vero se [issuer] ha emesso questo certificato: il nome dell'emittente
  /// coincide e la firma sha256WithRSAEncryption è valida.
  bool isIssuedBy(Certificate issuer) {
    if (!_bytesEqual(issuerDer, issuer.subjectDer)) return false;
    if (signatureAlgorithm != Oids.sha256WithRsa) return false;
    try {
      return issuer.rsaPublicKey.verifySha256(sha256.convert(tbsDer).bytes, signatureValue);
    } on UnsupportedError {
      return false;
    }
  }

  /// Verifica una firma fatta con la chiave di questo certificato su [data],
  /// con l'algoritmo [algorithmOid] (RSA con SHA-1, SHA-256, SHA-384 o SHA-512).
  bool verifies(String algorithmOid, List<int> data, List<int> signature) {
    try {
      return rsaPublicKey.verify(algorithmOid, data, signature);
    } on UnsupportedError {
      return false;
    }
  }

  /// Come [isIssuedBy], ma con qualunque algoritmo RSA supportato.
  bool isSignedBy(Certificate issuer) =>
      _bytesEqual(issuerDer, issuer.subjectDer) && issuer.verifies(signatureAlgorithm, tbsDer, signatureValue);

  bool isValidAt(DateTime t) => !t.isBefore(notBefore) && !t.isAfter(notAfter);

  @override
  bool operator ==(Object other) => other is Certificate && _bytesEqual(der, other.der);

  @override
  int get hashCode => Object.hashAll(sha256Fingerprint.take(8));

  /// Nome leggibile del titolare: nome e cognome se presenti, altrimenti il CN.
  String get holderName {
    final s = subject;
    final gn = s.get(Oids.givenName), sn = s.get(Oids.surname);
    if (gn != null && sn != null) return '$gn $sn';
    return s.get(Oids.commonName) ?? s.toString();
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class DistinguishedName {
  DistinguishedName(this._node);

  final DerNode _node;

  List<(String oid, String value)> get attributes => [
    for (final rdn in _node.children)
      for (final atv in rdn.children) (atv[0].asOid, atv[1].asString),
  ];

  String? get(String oid) {
    for (final a in attributes) {
      if (a.$1 == oid) return a.$2;
    }
    return null;
  }

  @override
  String toString() {
    const names = {
      Oids.commonName: 'CN',
      Oids.surname: 'SN',
      Oids.givenName: 'GN',
      Oids.serialNumber: 'serialNumber',
      Oids.country: 'C',
      Oids.organization: 'O',
    };
    return attributes.map((a) => '${names[a.$1] ?? a.$1}=${a.$2}').join(', ');
  }
}

class RsaPublicKey {
  RsaPublicKey(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;

  int get sizeInBytes => (modulus.bitLength + 7) >> 3;

  /// Verifica una firma **PKCS#1 v1.5** di [data] con l'algoritmo indicato.
  bool verify(String algorithmOid, List<int> data, List<int> signature) {
    final (hash, prefix) = switch (algorithmOid) {
      Oids.sha256WithRsa => (sha256, Rsa.sha256DigestInfoPrefix),
      Oids.sha1WithRsa => (sha1, Rsa.sha1DigestInfoPrefix),
      Oids.sha384WithRsa => (sha384, Rsa.sha384DigestInfoPrefix),
      Oids.sha512WithRsa => (sha512, Rsa.sha512DigestInfoPrefix),
      _ => throw UnsupportedError('Algoritmo di firma non supportato ($algorithmOid)'),
    };
    final t = [...prefix, ...hash.convert(data).bytes];
    final k = sizeInBytes;
    if (signature.length != k || k < t.length + 11) return false;
    final s = _toBigInt(signature);
    if (s >= modulus) return false;
    final em = _fromBigInt(s.modPow(exponent, modulus), k);
    final expected = [0x00, 0x01, ...List.filled(k - t.length - 3, 0xff), 0x00, ...t];
    var diff = 0;
    for (var i = 0; i < k; i++) {
      diff |= em[i] ^ expected[i];
    }
    return diff == 0;
  }

  /// Verifica una firma **PKCS#1 v1.5** su un'impronta SHA-256.
  bool verifySha256(List<int> digest, List<int> signature) {
    if (signature.length != sizeInBytes) return false;
    final s = _toBigInt(signature);
    if (s >= modulus) return false;
    final em = _fromBigInt(s.modPow(exponent, modulus), sizeInBytes);
    final expected = Rsa.pkcs1v15Encode(digest, sizeInBytes);
    if (em.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < em.length; i++) {
      diff |= em[i] ^ expected[i];
    }
    return diff == 0;
  }
}

/// Primitive RSA minime. La firma con chiave privata serve solo ai test e alla
/// modalità di prova dell'app: con la CIE la chiave privata non lascia la carta.
class Rsa {
  /// Prefisso DER del DigestInfo per SHA-256 (RFC 8017, sezione 9.2).
  static final sha256DigestInfoPrefix = Uint8List.fromList([
    0x30,
    0x31,
    0x30,
    0x0d,
    0x06,
    0x09,
    0x60,
    0x86,
    0x48,
    0x01,
    0x65,
    0x03,
    0x04,
    0x02,
    0x01,
    0x05,
    0x00,
    0x04,
    0x20,
  ]);

  static final sha1DigestInfoPrefix = Uint8List.fromList([
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14, //
  ]);
  static final sha384DigestInfoPrefix = Uint8List.fromList([
    0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30, //
  ]);
  static final sha512DigestInfoPrefix = Uint8List.fromList([
    0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40, //
  ]);

  /// DigestInfo che la CIE riceve e su cui applica da sé il padding PKCS#1.
  static Uint8List digestInfoSha256(List<int> digest) {
    if (digest.length != 32) throw ArgumentError('Impronta SHA-256 di lunghezza errata');
    return Uint8List.fromList([...sha256DigestInfoPrefix, ...digest]);
  }

  static Uint8List pkcs1v15Encode(List<int> digest, int k) {
    final t = digestInfoSha256(digest);
    if (k < t.length + 11) throw ArgumentError('Chiave RSA troppo corta');
    return Uint8List.fromList([0x00, 0x01, ...List.filled(k - t.length - 3, 0xff), 0x00, ...t]);
  }
}

class RsaPrivateKey {
  RsaPrivateKey(this.modulus, this.privateExponent);

  /// Legge una chiave **PKCS#8** non cifrata.
  factory RsaPrivateKey.fromPkcs8(Uint8List der) {
    final root = DerNode.parse(der);
    final inner = DerNode.parse(root[2].content);
    return RsaPrivateKey(inner[1].asBigInt, inner[3].asBigInt);
  }

  final BigInt modulus;
  final BigInt privateExponent;

  Uint8List signSha256(List<int> digest) {
    final k = (modulus.bitLength + 7) >> 3;
    final m = _toBigInt(Rsa.pkcs1v15Encode(digest, k));
    return _fromBigInt(m.modPow(privateExponent, modulus), k);
  }
}

BigInt _toBigInt(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List _fromBigInt(BigInt v, int len) {
  final out = Uint8List(len);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}
