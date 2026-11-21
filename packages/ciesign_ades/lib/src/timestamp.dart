import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cms.dart';
import 'der.dart';
import 'oids.dart';
import 'x509.dart';

/// Marca temporale RFC 3161 trovata in una firma: come attributo non firmato
/// della firma (CAdES-T, PAdES-T) oppure come firma a sé nel PDF
/// (DocTimeStamp, PAdES-LTA).
///
/// La verifica controlla che la marca copra davvero i dati attesi e che la
/// firma della TSA (Time Stamping Authority) sia integra. La fiducia nella TSA
/// (elenco EU dei prestatori qualificati) e la revoca del suo certificato non
/// sono ancora controllate.
class TimestampInfo {
  TimestampInfo._({
    required this.genTime,
    required this.hashAlgorithm,
    required this.imprint,
    required this.imprintMatches,
    required this.integrity,
    required this.tsaCertificate,
    required this.tsaName,
    required this.policy,
    required this.serialNumber,
  });

  /// Legge il TimeStampToken (ContentInfo con SignedData e TSTInfo) e lo
  /// confronta con [covered], i dati che la marca dovrebbe coprire: il valore
  /// della firma per una marca di firma, i byte del ByteRange per una
  /// DocTimeStamp.
  factory TimestampInfo.parse(Uint8List token, Uint8List covered) {
    final cms = CmsSignedData.parse(token);
    final tst = cms.content;
    if (tst == null) throw const FormatException('Marca temporale senza TSTInfo');
    final info = DerNode.parse(tst);
    var i = 1; // version
    final policy = info[i++].asOid;
    final mi = info[i++];
    final alg = mi[0][0].asOid;
    final imprint = Uint8List.fromList(mi[1].content);
    final serial = info[i++].asBigInt;
    final genTime = info[i++].asTime;
    String? tsaField;
    for (; i < info.length; i++) {
      if (info[i].tag == DerTag.context(0, constructed: true)) {
        tsaField = _generalName(info[i][0]);
      }
    }
    final expected = _digest(alg, covered);
    final signer = cms.signers.isEmpty ? null : cms.signers.first;
    SignatureIntegrity integrity;
    if (signer == null) {
      integrity = SignatureIntegrity.certificateMissing;
    } else {
      try {
        integrity = signer.checkIntegrity(Uint8List.fromList(sha256.convert(tst).bytes));
      } on Object {
        // Chiave della TSA non RSA o algoritmo non gestito dal motore.
        integrity = SignatureIntegrity.unsupportedAlgorithm;
      }
    }
    final cert = signer?.certificate;
    return TimestampInfo._(
      genTime: genTime,
      hashAlgorithm: alg,
      imprint: imprint,
      imprintMatches: expected != null && _eq(expected, imprint),
      integrity: integrity,
      tsaCertificate: cert,
      tsaName: cert?.subject.get(Oids.organization) ?? cert?.subject.get(Oids.commonName) ?? tsaField,
      policy: policy,
      serialNumber: serial,
    );
  }

  /// Data e ora certificate dalla TSA.
  final DateTime genTime;

  /// OID dell'algoritmo dell'impronta marcata.
  final String hashAlgorithm;
  final Uint8List imprint;

  /// La marca copre i dati attesi.
  final bool imprintMatches;

  /// Integrità della firma della TSA sulla marca.
  final SignatureIntegrity integrity;
  final Certificate? tsaCertificate;

  /// Nome leggibile della TSA (organizzazione o CN del certificato).
  final String? tsaName;
  final String policy;
  final BigInt serialNumber;

  bool get isValid => imprintMatches && integrity == SignatureIntegrity.valid;

  static Uint8List? _digest(String oid, Uint8List data) {
    final h = switch (oid) {
      Oids.sha256 => sha256,
      Oids.sha384 => sha384,
      Oids.sha512 => sha512,
      Oids.sha1 => sha1,
      _ => null,
    };
    return h == null ? null : Uint8List.fromList(h.convert(data).bytes);
  }

  /// GeneralName della TSA: di solito un directoryName [4].
  static String? _generalName(DerNode n) {
    try {
      if (n.tag == DerTag.context(4, constructed: true)) {
        final dn = DistinguishedName(n[0]);
        return dn.get(Oids.organization) ?? dn.get(Oids.commonName) ?? dn.toString();
      }
      return n.asString;
    } on Object {
      return null;
    }
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
