import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cms.dart';
import 'pdf/pdf_document.dart';
import 'pdf/pdf_objects.dart';
import 'trust.dart';
import 'timestamp.dart';
import 'x509.dart';

/// Esito della verifica di una firma: integrità crittografica e catena fino
/// alle CA della CIE del Ministero dell'Interno ([chain]). Lo stato di revoca
/// (OCSP o CRL) non è ancora controllato.
class SignatureReport {
  SignatureReport({
    required this.integrity,
    required this.certificate,
    this.signingTime,
    this.hasTimestamp = false,
    this.fieldName,
    this.coversWholeDocument,
    this.subFilter,
    this.chain,
    this.timestamp,
    this.isDocumentTimestamp = false,
  });

  /// Catena del firmatario verso le CA della CIE; nullo senza certificato.
  final ChainReport? chain;

  final SignatureIntegrity integrity;
  final Certificate? certificate;
  final DateTime? signingTime;
  final bool hasTimestamp;

  /// Solo PAdES: nome del campo firma, copertura del file e SubFilter.
  final String? fieldName;
  final bool? coversWholeDocument;
  final String? subFilter;

  /// Marca temporale: della firma, oppure la marca stessa quando
  /// [isDocumentTimestamp] è vero. Nulla se assente o illeggibile.
  final TimestampInfo? timestamp;

  /// Vero per una DocTimeStamp PAdES: non è una firma di una persona ma una
  /// marca temporale sull'intero documento.
  final bool isDocumentTimestamp;

  bool get isIntact => integrity == SignatureIntegrity.valid;

  /// Validità del certificato del firmatario rispetto a oggi, come fanno
  /// i verificatori (EU DSS, Aruba Sign, Dike): la data dichiarata nella firma
  /// la sceglie chi firma e non prova nulla; solo una marca temporale integra
  /// dimostra che la firma esisteva prima della scadenza del certificato.
  CertificateTime get certificateTime => certificateTimeAt(DateTime.now());

  CertificateTime certificateTimeAt(DateTime now) {
    final c = certificate;
    if (c == null) return CertificateTime.unknown;
    final st = signingTime;
    if (now.isBefore(c.notBefore) || (!isDocumentTimestamp && st != null && st.isBefore(c.notBefore))) {
      return CertificateTime.notYetValid;
    }
    if (!now.isAfter(c.notAfter)) return CertificateTime.valid;
    final t = timestamp;
    final poe = !isDocumentTimestamp && t != null && t.isValid ? t.genTime : null;
    if (poe != null && !poe.isBefore(c.notBefore) && !poe.isAfter(c.notAfter)) return CertificateTime.validAtTimestamp;
    return CertificateTime.expired;
  }
}

/// Validità temporale del certificato del firmatario.
enum CertificateTime {
  /// Certificato valido oggi.
  valid,

  /// Certificato scaduto oggi, ma una marca temporale integra prova che la
  /// firma è stata apposta mentre era valido.
  validAtTimestamp,

  /// Certificato scaduto e nessuna prova che la firma sia anteriore alla scadenza.
  expired,

  /// Certificato non ancora valido oggi o alla data dichiarata della firma.
  notYetValid,

  /// Certificato assente nella firma.
  unknown,
}

/// Verifica e sbustamento di un file CAdES (.p7m).
class CadesFile {
  CadesFile._(this.cms, this.reports);

  /// [detachedContent] serve solo per le firme staccate.
  factory CadesFile.open(Uint8List p7m, {Uint8List? detachedContent}) {
    final cms = CmsSignedData.parse(p7m);
    final content = cms.content ?? detachedContent;
    if (content == null) throw const FormatException('Firma staccata: serve anche il documento originale');
    final digest = Uint8List.fromList(sha256.convert(content).bytes);
    final reports = [
      for (final s in cms.signers)
        SignatureReport(
          integrity: s.checkIntegrity(digest),
          certificate: s.certificate,
          signingTime: s.signingTime,
          hasTimestamp: s.hasSignatureTimestamp,
          chain: _chain(s.certificate, cms.certificates, s.signingTime),
          timestamp: _signatureTimestamp(s),
        ),
    ];
    return CadesFile._(cms, reports);
  }

  final CmsSignedData cms;
  final List<SignatureReport> reports;

  /// Documento estratto dalla busta (sbustamento), disponibile anche quando la
  /// firma non è integra: l'esito della verifica va mostrato accanto.
  Uint8List? get content => cms.content;

  /// Nome del file estratto: "contratto.pdf.p7m" diventa "contratto.pdf",
  /// anche con più firme annidate ("x.pdf.p7m.p7m").
  static String unwrappedName(String name) {
    var n = name;
    while (n.toLowerCase().endsWith('.p7m')) {
      n = n.substring(0, n.length - 4);
    }
    return n == name ? '$name.estratto' : n;
  }
}

/// Marca temporale di firma: copre il valore della firma (RFC 3161, CAdES-T).
TimestampInfo? _signatureTimestamp(CmsSignerInfo s) {
  final token = s.signatureTimestampToken;
  if (token == null) return null;
  try {
    return TimestampInfo.parse(token, s.signature);
  } on Object {
    return null;
  }
}

/// Firme presenti in un PDF.
class PadesVerifier {
  static List<SignatureReport> verify(Uint8List pdf) {
    final doc = PdfDocument.parse(pdf);
    final out = <SignatureReport>[];
    final acro = doc.resolve(doc.catalog['AcroForm']);
    if (acro is! PdfDict) return out;
    final fields = doc.resolve(acro['Fields']);
    if (fields is! PdfArray) return out;

    void visit(PdfObject f, String prefix) {
      final d = doc.resolve(f);
      if (d is! PdfDict) return;
      final t = d['T'] is PdfString ? (d['T'] as PdfString).text : '';
      final name = prefix.isEmpty ? t : '$prefix.$t';
      final kids = doc.resolve(d['Kids']);
      if (kids is PdfArray && (d['FT'] == null)) {
        for (final k in kids.items) {
          visit(k, name);
        }
        return;
      }
      if ((d['FT'] as PdfName?)?.value != 'Sig') return;
      final v = doc.resolve(d['V']);
      if (v is! PdfDict) return;
      out.add(_verifySignature(pdf, v, name));
    }

    for (final f in fields.items) {
      visit(f, '');
    }
    return out;
  }

  static SignatureReport _verifySignature(Uint8List pdf, PdfDict sig, String name) {
    final br = (sig['ByteRange'] as PdfArray).items.map((e) => (e as PdfNumber).intValue).toList();
    final contents = (sig['Contents'] as PdfString).bytes;
    final sub = (sig['SubFilter'] as PdfName?)?.value;
    final b = BytesBuilder(copy: false);
    for (var i = 0; i + 1 < br.length; i += 2) {
      b.add(Uint8List.sublistView(pdf, br[i], br[i] + br[i + 1]));
    }
    final digest = Uint8List.fromList(sha256.convert(b.toBytes()).bytes);
    final covers = br.length == 4 && br[0] == 0 && br[2] + br[3] == pdf.length;
    final token = _trimZeros(contents);
    if (sub == 'ETSI.RFC3161' || (sig['Type'] as PdfName?)?.value == 'DocTimeStamp') {
      return _documentTimestamp(token, b.toBytes(), name, covers, sub);
    }
    final cms = CmsSignedData.parse(token);
    final s = cms.signers.first;
    return SignatureReport(
      integrity: s.checkIntegrity(digest),
      certificate: s.certificate,
      signingTime: s.signingTime ?? _parsePdfDate(sig['M']),
      hasTimestamp: s.hasSignatureTimestamp,
      timestamp: _signatureTimestamp(s),
      fieldName: name,
      coversWholeDocument: covers,
      subFilter: sub,
      chain: _chain(s.certificate, cms.certificates, s.signingTime ?? _parsePdfDate(sig['M'])),
    );
  }

  /// Una DocTimeStamp contiene un TimeStampToken sui byte del ByteRange.
  static SignatureReport _documentTimestamp(Uint8List token, Uint8List covered, String name, bool covers, String? sub) {
    final t = TimestampInfo.parse(token, covered);
    return SignatureReport(
      integrity: !t.imprintMatches ? SignatureIntegrity.contentModified : t.integrity,
      certificate: t.tsaCertificate,
      signingTime: t.genTime,
      hasTimestamp: true,
      fieldName: name,
      coversWholeDocument: covers,
      subFilter: sub,
      timestamp: t,
      isDocumentTimestamp: true,
    );
  }

  /// Il valore /Contents è riempito di zeri fino allo spazio riservato.
  static Uint8List _trimZeros(Uint8List c) {
    final root = _tlvLength(c);
    return Uint8List.sublistView(c, 0, root);
  }

  static int _tlvLength(Uint8List c) {
    final l = c[1];
    if (l < 0x80) return 2 + l;
    final n = l & 0x7f;
    var len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | c[2 + i];
    }
    return 2 + n + len;
  }

  static DateTime? _parsePdfDate(PdfObject? o) {
    if (o is! PdfString) return null;
    final m = RegExp(r"D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?").firstMatch(o.text);
    if (m == null) return null;
    int g(int i, int d) => m[i] == null ? d : int.parse(m[i]!);
    return DateTime.utc(g(1, 0), g(2, 1), g(3, 1), g(4, 0), g(5, 0), g(6, 0));
  }
}

ChainReport? _chain(Certificate? signer, List<Certificate> extra, DateTime? at) {
  if (signer == null) return null;
  try {
    return CieTrust.verify(signer, extra: extra, at: at);
  } on Object {
    return ChainReport(ChainStatus.brokenChain, [signer]);
  }
}
