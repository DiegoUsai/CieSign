/// Motore di firma di CIE Sign: prepara le firme PAdES e CAdES di livello
/// B-B, le completa con la firma prodotta dalla CIE, le verifica ed estrae il
/// documento dai file .p7m.
///
/// Il flusso è sempre in due tempi, perché la chiave privata resta nella
/// carta: il PC prepara gli attributi firmati e ne calcola l'impronta, lo
/// smartphone la fa firmare alla CIE e il PC inserisce la firma ricevuta.
library;

export 'src/cms.dart'
    show CadesPreparation, CmsBuilder, CmsSignedData, CmsSignerInfo, SignatureIntegrity, SignatureMismatchException;
export 'src/der.dart' show Der, DerNode, DerTag;
export 'src/oids.dart';
export 'src/pdf/pades.dart' show PadesPreparation, SignatureAppearanceText, VisibleSignature;
export 'src/pdf/pdf_document.dart' show PdfDocument, PdfFormatException, PdfRect;
export 'src/verify.dart';
export 'src/x509.dart';
