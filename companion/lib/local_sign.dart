import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart' show SignFormat;

/// Documento scelto sul telefono per la firma senza PC.
class LocalDocument {
  LocalDocument(this.name, this.bytes);

  final String name;
  final Uint8List bytes;

  bool get isPdf {
    final n = bytes.length < 1024 ? bytes.length : 1024;
    return bytes.length > 4 && String.fromCharCodes(bytes.sublist(0, n)).contains('%PDF-');
  }

  bool get isP7m {
    final lower = name.toLowerCase();
    return lower.endsWith('.p7m') || lower.endsWith('.p7s');
  }
}

/// Errore della firma sul telefono, con un messaggio già pronto per l'utente.
class LocalSignException implements Exception {
  LocalSignException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Firma preparata per un certificato: l'impronta che la CIE deve firmare e la
/// funzione che inserisce la firma ricevuta nel documento.
class PreparedSignature {
  PreparedSignature._(this.certificate, this.digestToSign, this._finish);

  final Certificate certificate;
  final Uint8List digestToSign;
  final Uint8List Function(Uint8List) _finish;

  Uint8List finish(Uint8List signature) {
    try {
      return _finish(signature);
    } on SignatureMismatchException {
      throw LocalSignException('La firma della carta non corrisponde al certificato letto.');
    }
  }
}

/// Firma di un documento interamente sul telefono (UC11): lo stesso motore
/// PAdES/CAdES del PC, con il certificato letto dalla CIE nella stessa
/// sessione in cui la carta firma.
class LocalSigner {
  LocalSigner._();

  /// Prepara gli attributi firmati per [certificateDer]; rifiuta un certificato
  /// scaduto o non ancora valido, perché la firma nascerebbe già non valida.
  static PreparedSignature prepare(
    LocalDocument doc,
    SignFormat format,
    Uint8List certificateDer, {
    VisibleSignature? visible,
    DateTime? now,
  }) {
    final cert = Certificate.fromDer(certificateDer);
    final when = now ?? DateTime.now();
    if (when.isAfter(cert.notAfter)) {
      throw LocalSignException('Il certificato della CIE è scaduto il ${_date(cert.notAfter)}: non può più firmare.');
    }
    if (when.isBefore(cert.notBefore)) {
      throw LocalSignException('Il certificato della CIE è valido solo dal ${_date(cert.notBefore)}.');
    }
    if (format == SignFormat.pades) {
      if (!doc.isPdf) throw LocalSignException('La firma PAdES si applica solo ai PDF.');
      try {
        final p = PadesPreparation.prepare(doc.bytes, cert, visible: visible, signingTime: when);
        return PreparedSignature._(cert, p.digestToSign, p.finish);
      } on PdfFormatException catch (e) {
        throw LocalSignException('PDF non supportato: ${e.message}');
      }
    }
    final p = CadesPreparation.prepare(doc.bytes, cert, signingTime: when);
    return PreparedSignature._(cert, p.digestToSign, p.finish);
  }

  /// Nome proposto per il file firmato, come sul PC.
  static String signedName(String name, SignFormat f) {
    if (f == SignFormat.cades) return '$name.p7m';
    final dot = name.lastIndexOf('.');
    return dot > 0 ? '${name.substring(0, dot)}-signed${name.substring(dot)}' : '$name-signed.pdf';
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }
}

/// Copie dei documenti firmati sul telefono, nella cartella privata dell'app.
class SignedStore {
  SignedStore(this.dir);

  final Directory dir;

  /// Salva [bytes] con [name], senza sovrascrivere un file esistente.
  Future<File> save(String name, Uint8List bytes) async {
    await dir.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var file = File('${dir.path}/$safe');
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    for (var i = 2; await file.exists(); i++) {
      file = File('${dir.path}/$base ($i)$ext');
    }
    return file.writeAsBytes(bytes, flush: true);
  }

  /// Documenti firmati, dal più recente.
  Future<List<File>> list() async {
    if (!await dir.exists()) return const [];
    final files = await dir.list().where((e) => e is File).cast<File>().toList();
    final stamps = {for (final f in files) f.path: await f.lastModified()};
    files.sort((a, b) => stamps[b.path]!.compareTo(stamps[a.path]!));
    return files;
  }
}
