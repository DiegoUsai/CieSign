import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';

import 'link_service.dart';
import 'signers.dart';

enum DocumentKind { pdf, p7m, other }

/// Documento aperto nell'app.
class OpenedDocument {
  OpenedDocument(this.path, this.bytes);

  final String path;
  final Uint8List bytes;

  String get name => path.split(RegExp(r'[\\/]')).last;

  DocumentKind get kind {
    final lower = name.toLowerCase();
    if (lower.endsWith('.p7m') || lower.endsWith('.p7s')) return DocumentKind.p7m;
    if (bytes.length > 4 && String.fromCharCodes(bytes.sublist(0, min(1024, bytes.length))).contains('%PDF-')) {
      return DocumentKind.pdf;
    }
    return DocumentKind.other;
  }
}

class SignResult {
  SignResult(this.bytes, this.suggestedName, this.holder);
  final Uint8List bytes;
  final String suggestedName;
  final String holder;
}

/// Flusso completo di una firma: certificato, preparazione, richiesta allo
/// smartphone, inserimento della firma. Indipendente dall'interfaccia.
class SignWorkflow {
  SignWorkflow(this.signer, {this.link, this.requestLifetime = const Duration(seconds: 60)});

  final CardSigner signer;
  final LinkService? link;
  final Duration requestLifetime;

  static String signedName(String name, SignFormat f) {
    if (f == SignFormat.cades) return '$name.p7m';
    final dot = name.lastIndexOf('.');
    return dot > 0 ? '${name.substring(0, dot)}-signed${name.substring(dot)}' : '$name-signed.pdf';
  }

  Future<SignResult> run(
    OpenedDocument doc,
    SignFormat format, {
    VisibleSignature? visible,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Lettura del certificato della CIE…');
    final cert = await signer.certificate();
    if (DateTime.now().isAfter(cert.notAfter)) throw SignFailure('Il certificato della CIE è scaduto.');

    onStatus?.call('Preparazione del documento…');
    final Uint8List attrs;
    final Uint8List Function(Uint8List) finish;
    Uint8List? servedDocument;
    if (format == SignFormat.pades) {
      final p = PadesPreparation.prepare(doc.bytes, cert, visible: visible);
      attrs = p.signedAttributes;
      finish = p.finish;
      servedDocument = p.preparedPdf;
    } else {
      final p = CadesPreparation.prepare(doc.bytes, cert);
      attrs = p.signedAttributes;
      finish = p.finish;
      servedDocument = doc.bytes;
    }

    final request = SignRequest(
      id: _newId(),
      documentName: doc.name,
      documentSize: doc.bytes.length,
      format: format,
      signedAttributes: attrs,
      expiresAt: DateTime.now().add(requestLifetime),
      visiblePage: visible == null ? null : visible.pageIndex + 1,
      documentAvailable: link != null,
    );

    // Se lo smartphone chiede di vedere il documento (UC10), lo riceve a blocchi.
    StreamSubscription<(SecureChannel, LinkMessage)>? docServer;
    if (link != null) {
      docServer = link!.incoming.listen((e) async {
        final (c, m) = e;
        if (m is! DocumentRequest || m.id != request.id) return;
        final data = servedDocument!;
        for (var off = 0; off < data.length; off += DocumentChunk.chunkSize) {
          final end = min(off + DocumentChunk.chunkSize, data.length);
          await c.send(DocumentChunk(m.id, off, Uint8List.sublistView(data, off, end), end == data.length));
        }
      });
    }

    try {
      onStatus?.call(
        signer.isTest
            ? 'Firma con la chiave di prova…'
            : 'Appoggia la CIE al telefono e inserisci il PIN su ${signer.label.replaceFirst('Smartphone ', '')}…',
      );
      final signature = await signer.sign(request);
      onStatus?.call('Inserimento della firma…');
      final out = finish(signature);
      return SignResult(out, signedName(doc.name, format), cert.holderName);
    } on SignatureMismatchException {
      throw SignFailure('La firma ricevuta non corrisponde: è stata usata una CIE diversa da quella registrata?');
    } finally {
      await docServer?.cancel();
    }
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
