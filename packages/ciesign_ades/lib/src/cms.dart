import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';
import 'oids.dart';
import 'x509.dart';

/// Costruzione delle strutture **CMS** (RFC 5652) per CAdES e PAdES di livello
/// B-B (ETSI EN 319 122-1 e EN 319 142-1).
class CmsBuilder {
  /// Attributi firmati. È questa struttura, codificata come SET, che la CIE
  /// firma: il PC ne calcola l'impronta e la manda allo smartphone.
  ///
  /// Per PAdES lo standard vieta l'attributo signing-time (l'ora va nella voce
  /// /M del dizionario di firma), quindi [signingTime] va lasciato nullo.
  static Uint8List signedAttributes({
    required List<int> contentDigest,
    required Certificate certificate,
    DateTime? signingTime,
  }) {
    Uint8List attr(String oid, List<int> value) => Der.seq([
      Der.oid(oid),
      Der.setOf([value]),
    ]);
    return Der.setOf([
      attr(Oids.contentType, Der.oid(Oids.data)),
      if (signingTime != null) attr(Oids.signingTime, Der.utcTime(signingTime)),
      attr(Oids.messageDigest, Der.octets(contentDigest)),
      attr(Oids.signingCertificateV2, _signingCertificateV2(certificate)),
    ]);
  }

  /// ESS signing-certificate-v2 (RFC 5035): lega la firma al certificato.
  /// L'algoritmo SHA-256 è il valore predefinito e per DER va omesso.
  static Uint8List _signingCertificateV2(Certificate c) {
    final issuerSerial = Der.seq([
      Der.seq([Der.explicit(4, c.issuerDer)]),
      Der.integer(c.serialNumber),
    ]);
    final essCertIdV2 = Der.seq([Der.octets(c.sha256Fingerprint), issuerSerial]);
    return Der.seq([
      Der.seq([essCertIdV2]),
    ]);
  }

  /// ContentInfo di tipo SignedData. Con [content] la firma è "imbustata",
  /// come nei file .p7m; senza, è staccata, come dentro un PDF.
  static Uint8List signedData({
    required Uint8List signedAttributes,
    required Uint8List signature,
    required Certificate certificate,
    Uint8List? content,
  }) {
    if (signedAttributes.isEmpty || signedAttributes[0] != DerTag.set) {
      throw ArgumentError('Gli attributi firmati devono essere un SET DER');
    }
    // Dentro il SignerInfo il SET diventa [0] IMPLICIT, con lo stesso contenuto.
    final implicitAttrs = Uint8List.fromList(signedAttributes)..[0] = DerTag.context(0);
    final signerInfo = Der.seq([
      Der.smallInt(1),
      Der.seq([certificate.issuerDer, Der.integer(certificate.serialNumber)]),
      Der.algorithm(Oids.sha256),
      implicitAttrs,
      Der.algorithm(Oids.sha256WithRsa, withNull: true),
      Der.octets(signature),
    ]);
    final sd = Der.seq([
      Der.smallInt(1),
      Der.setOf([Der.algorithm(Oids.sha256)]),
      Der.seq([Der.oid(Oids.data), if (content != null) Der.explicit(0, Der.octets(content))]),
      Der.tlv(DerTag.context(0), certificate.der),
      Der.setOf([signerInfo]),
    ]);
    return Der.seq([Der.oid(Oids.signedData), Der.explicit(0, sd)]);
  }
}

/// Firma CAdES in due tempi: prima si preparano gli attributi firmati, poi,
/// ricevuta la firma dalla carta, si compone il file .p7m.
class CadesPreparation {
  CadesPreparation._(this.content, this.certificate, this.signedAttributes, this.detached);

  factory CadesPreparation.prepare(
    Uint8List content,
    Certificate certificate, {
    DateTime? signingTime,
    bool detached = false,
  }) {
    final attrs = CmsBuilder.signedAttributes(
      contentDigest: sha256.convert(content).bytes,
      certificate: certificate,
      signingTime: signingTime ?? DateTime.now(),
    );
    return CadesPreparation._(content, certificate, attrs, detached);
  }

  final Uint8List content;
  final Certificate certificate;
  final Uint8List signedAttributes;
  final bool detached;

  /// Impronta SHA-256 che la CIE deve firmare.
  Uint8List get digestToSign => Uint8List.fromList(sha256.convert(signedAttributes).bytes);

  Uint8List finish(Uint8List signature) {
    if (!certificate.rsaPublicKey.verifySha256(digestToSign, signature)) {
      throw const SignatureMismatchException();
    }
    return CmsBuilder.signedData(
      signedAttributes: signedAttributes,
      signature: signature,
      certificate: certificate,
      content: detached ? null : content,
    );
  }
}

/// La firma restituita non corrisponde all'impronta o al certificato atteso,
/// per esempio perché è stata appoggiata una CIE diversa.
class SignatureMismatchException implements Exception {
  const SignatureMismatchException();

  @override
  String toString() => 'La firma ricevuta non corrisponde al documento o al certificato atteso';
}

/// Lettura di un SignedData esistente, per la verifica e lo sbustamento.
class CmsSignedData {
  CmsSignedData._(this._sd, this.signers, this.certificates, this.content);

  /// Accetta DER, BER a lunghezza indefinita e .p7m codificati in Base64.
  factory CmsSignedData.parse(Uint8List bytes) {
    final der = _maybeBase64(bytes);
    final ci = DerNode.parse(der);
    if (ci[0].asOid != Oids.signedData) throw const FormatException('Il file non contiene una firma CMS');
    final sd = ci[1][0];
    var i = 2;
    final encap = sd[i++];
    final content = encap.length > 1 ? encap[1][0].octetValue : null;
    final certs = <Certificate>[];
    final crlsOrCerts = <DerNode>[];
    while (sd[i].tag != DerTag.set) {
      crlsOrCerts.add(sd[i++]);
    }
    for (final n in crlsOrCerts) {
      if (n.tag == DerTag.context(0)) {
        for (final c in n.children) {
          if (c.tag == DerTag.sequence) certs.add(Certificate.fromDer(Uint8List.fromList(c.raw)));
        }
      }
    }
    final signers = [for (final s in sd[i].children) CmsSignerInfo._(s, certs)];
    return CmsSignedData._(sd, signers, certs, content == null ? null : Uint8List.fromList(content));
  }

  // ignore: unused_field
  final DerNode _sd;
  final List<CmsSignerInfo> signers;
  final List<Certificate> certificates;

  /// Documento originale, presente solo nelle firme imbustate.
  final Uint8List? content;

  bool get isDetached => content == null;

  static Uint8List _maybeBase64(Uint8List b) {
    if (b.isNotEmpty && (b[0] == DerTag.sequence)) return b;
    final text = latin1.decode(b).replaceAll(RegExp(r'-----[^-]+-----'), '').replaceAll(RegExp(r'\s'), '');
    try {
      return base64.decode(text);
    } on FormatException {
      throw const FormatException('Il file non è una firma CMS in DER né in Base64');
    }
  }
}

class CmsSignerInfo {
  CmsSignerInfo._(this._node, List<Certificate> certs) {
    var i = 1;
    final sid = _node[i++];
    _digestAlg = _node[i++][0].asOid;
    if (_node[i].tag == DerTag.context(0)) _attrs = _node[i++];
    i++; // algoritmo di firma
    signature = Uint8List.fromList(_node[i++].content);
    if (i < _node.length && _node[i].tag == DerTag.context(1)) _unsigned = _node[i];
    certificate = _findCert(sid, certs);
  }

  final DerNode _node;
  late final String _digestAlg;
  DerNode? _attrs;
  DerNode? _unsigned;
  late final Uint8List signature;
  late final Certificate? certificate;

  String get digestAlgorithm => _digestAlg;

  Uint8List? get signedAttributesDer {
    final a = _attrs;
    if (a == null) return null;
    return Uint8List.fromList(a.raw)..[0] = DerTag.set;
  }

  DerNode? _attr(DerNode? set, String oid) {
    if (set == null) return null;
    for (final a in set.children) {
      if (a[0].asOid == oid) return a[1][0];
    }
    return null;
  }

  Uint8List? get messageDigest => _attr(_attrs, Oids.messageDigest)?.content;

  DateTime? get signingTime => _attr(_attrs, Oids.signingTime)?.asTime;

  /// Vero se la firma porta una marca temporale (attributo non firmato).
  bool get hasSignatureTimestamp => _attr(_unsigned, Oids.signatureTimeStampToken) != null;

  /// Controlla che l'impronta del contenuto coincida e che la firma sia
  /// stata prodotta dalla chiave del certificato. Non controlla la catena né
  /// la revoca del certificato.
  SignatureIntegrity checkIntegrity(Uint8List contentDigestSha256) {
    final cert = certificate;
    if (cert == null) return SignatureIntegrity.certificateMissing;
    if (_digestAlg != Oids.sha256) return SignatureIntegrity.unsupportedAlgorithm;
    final attrs = signedAttributesDer;
    final List<int> signed;
    if (attrs != null) {
      if (!_eq(messageDigest ?? const [], contentDigestSha256)) return SignatureIntegrity.contentModified;
      signed = sha256.convert(attrs).bytes;
    } else {
      signed = contentDigestSha256;
    }
    return cert.rsaPublicKey.verifySha256(signed, signature)
        ? SignatureIntegrity.valid
        : SignatureIntegrity.signatureInvalid;
  }

  static Certificate? _findCert(DerNode sid, List<Certificate> certs) {
    if (sid.tag != DerTag.sequence) return certs.length == 1 ? certs.first : null;
    final serial = sid[1].asBigInt;
    final issuer = sid[0].raw;
    for (final c in certs) {
      if (c.serialNumber == serial && _eq(c.issuerDer, issuer)) return c;
    }
    return null;
  }
}

enum SignatureIntegrity { valid, contentModified, signatureInvalid, certificateMissing, unsupportedAlgorithm }

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
