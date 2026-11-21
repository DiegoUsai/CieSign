import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cms.dart';
import 'pdf/pdf_document.dart';
import 'pdf/pdf_objects.dart';
import 'x509.dart';

/// Esito della verifica di una firma. Questa prima versione controlla
/// l'integrità crittografica; la catena fino alla CA del Ministero
/// dell'Interno e lo stato di revoca (OCSP o CRL) arriveranno in seguito.
class SignatureReport {
  SignatureReport({
    required this.integrity,
    required this.certificate,
    this.signingTime,
    this.hasTimestamp = false,
    this.fieldName,
    this.coversWholeDocument,
    this.subFilter,
  });

  final SignatureIntegrity integrity;
  final Certificate? certificate;
  final DateTime? signingTime;
  final bool hasTimestamp;

  /// Solo PAdES: nome del campo firma, copertura del file e SubFilter.
  final String? fieldName;
  final bool? coversWholeDocument;
  final String? subFilter;

  bool get isIntact => integrity == SignatureIntegrity.valid;
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
    final cms = CmsSignedData.parse(_trimZeros(contents));
    final s = cms.signers.first;
    return SignatureReport(
      integrity: s.checkIntegrity(digest),
      certificate: s.certificate,
      signingTime: s.signingTime ?? _parsePdfDate(sig['M']),
      hasTimestamp: s.hasSignatureTimestamp,
      fieldName: name,
      coversWholeDocument: covers,
      subFilter: sub,
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
