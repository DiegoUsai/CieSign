import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../cms.dart';
import '../x509.dart';
import 'pdf_document.dart';
import 'pdf_objects.dart';

/// Posizione del riquadro della firma visibile, in punti tipografici con
/// origine nell'angolo in basso a sinistra del riquadro visibile della pagina.
class VisibleSignature {
  const VisibleSignature({
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int pageIndex;
  final double x, y, width, height;
}

/// Testi del riquadro, composti dai dati del certificato.
class SignatureAppearanceText {
  const SignatureAppearanceText(this.lines);

  factory SignatureAppearanceText.cie(String holder, DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = when.toLocal();
    return SignatureAppearanceText([
      'Firmato con CIE da',
      holder,
      'il ${two(l.day)}/${two(l.month)}/${l.year} alle ${two(l.hour)}:${two(l.minute)}',
      'Firma elettronica avanzata',
    ]);
  }

  final List<String> lines;
}

/// Firma **PAdES** di livello B-B in due tempi, come per CAdES: [prepare]
/// compone l'aggiornamento incrementale con lo spazio per la firma e calcola
/// l'impronta da far firmare alla CIE; [finish] inserisce la firma.
class PadesPreparation {
  PadesPreparation._(
    this.preparedPdf,
    this.byteRange,
    this._contentsOffset,
    this._contentsLength,
    this.certificate,
    this.signedAttributes,
    this.contentDigest,
  );

  /// Spazio riservato alla firma CMS, in byte. Basta per certificato, firma e
  /// attributi; quando arriverà la marca temporale andrà aumentato.
  static const defaultReservedBytes = 12288;

  static PadesPreparation prepare(
    Uint8List pdf,
    Certificate certificate, {
    VisibleSignature? visible,
    SignatureAppearanceText? appearance,
    DateTime? signingTime,
    String? reason,
    String? location,
    int reservedBytes = defaultReservedBytes,
  }) {
    final doc = PdfDocument.parse(pdf);
    final when = signingTime ?? DateTime.now();
    final w = _IncrementalWriter(doc);

    final sigRef = w.allocate();
    final widgetRef = w.allocate();
    final pageIndex = visible?.pageIndex ?? 0;
    if (pageIndex < 0 || pageIndex >= doc.pages.length) throw ArgumentError('Pagina $pageIndex inesistente');
    final pageRef = doc.pages[pageIndex];

    // Campo firma e annotazione (widget) in un unico oggetto.
    final fieldName = _uniqueFieldName(doc);
    final widget = PdfDict({
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Widget'),
      'FT': const PdfName('Sig'),
      'T': PdfString.text(fieldName),
      'V': sigRef,
      'P': pageRef,
      'F': const PdfNumber(132), // Print + Locked
    });
    if (visible != null) {
      final box = doc.pageBox(pageIndex);
      final x0 = box.x + visible.x, y0 = box.y + visible.y;
      widget['Rect'] = PdfArray([
        PdfNumber(x0),
        PdfNumber(y0),
        PdfNumber(x0 + visible.width),
        PdfNumber(y0 + visible.height),
      ]);
      final apRef = w.allocate();
      final text = appearance ?? SignatureAppearanceText.cie(certificate.holderName, when);
      w.put(apRef, _appearanceStream(visible.width, visible.height, text));
      widget['AP'] = PdfDict({'N': apRef});
    } else {
      widget['Rect'] = PdfArray([const PdfNumber(0), const PdfNumber(0), const PdfNumber(0), const PdfNumber(0)]);
    }
    w.put(widgetRef, widget);

    // Annotazione aggiunta alla pagina (o all'array /Annots indiretto).
    final page = (doc.resolve(pageRef) as PdfDict).copy();
    final annots = page['Annots'];
    if (annots is PdfRef) {
      final arr = doc.resolve(annots);
      w.put(annots, PdfArray([if (arr is PdfArray) ...arr.items, widgetRef]));
    } else {
      page['Annots'] = PdfArray([if (annots is PdfArray) ...annots.items, widgetRef]);
      w.put(pageRef, page);
    }

    // Modulo (AcroForm) del documento, nel catalogo o come oggetto a sé.
    final catalog = doc.catalog.copy();
    final acro = catalog['AcroForm'];
    PdfDict form;
    PdfRef? formRef;
    if (acro is PdfRef) {
      formRef = acro;
      form = (doc.resolve(acro) as PdfDict).copy();
    } else {
      form = acro is PdfDict ? acro.copy() : PdfDict();
    }
    final fieldsObj = form['Fields'];
    if (fieldsObj is PdfRef) {
      final arr = doc.resolve(fieldsObj);
      w.put(fieldsObj, PdfArray([if (arr is PdfArray) ...arr.items, widgetRef]));
    } else {
      form['Fields'] = PdfArray([if (fieldsObj is PdfArray) ...fieldsObj.items, widgetRef]);
    }
    form['SigFlags'] = const PdfNumber(3);
    if (formRef != null) {
      w.put(formRef, form);
    } else {
      catalog['AcroForm'] = form;
      w.put(doc.rootRef, catalog);
    }

    // Dizionario di firma con segnaposto di lunghezza fissa per ByteRange e Contents.
    final sig = PdfDict({
      'Type': const PdfName('Sig'),
      'Filter': const PdfName('Adobe.PPKLite'),
      'SubFilter': const PdfName('ETSI.CAdES.detached'),
      'ByteRange': const _Raw(_byteRangePlaceholder),
      'Contents': _Raw('<${'0' * (reservedBytes * 2)}>'),
      'M': PdfString(Uint8List.fromList(latin1.encode(_pdfDate(when)))),
      'Name': PdfString.text(certificate.holderName),
      'Prop_Build': PdfDict({
        'App': PdfDict({'Name': const PdfName('Firmami')}),
      }),
      if (reason != null) 'Reason': PdfString.text(reason),
      if (location != null) 'Location': PdfString.text(location),
    });
    w.put(sigRef, sig);

    final out = w.build();
    final text = latin1.decode(out);
    final brPos = text.lastIndexOf(_byteRangePlaceholder);
    final cPos = text.indexOf('/Contents <', brPos) + '/Contents '.length;
    final cLen = reservedBytes * 2 + 2;
    final range = [0, cPos, cPos + cLen, out.length - (cPos + cLen)];
    final brText = '[${range.map((v) => v.toString().padLeft(10, '0')).join(' ')}]';
    final brBytes = latin1.encode(brText.padRight(_byteRangePlaceholder.length));
    out.setRange(brPos, brPos + brBytes.length, brBytes);

    final digest = sha256.convert([
      ...Uint8List.sublistView(out, 0, range[1]),
      ...Uint8List.sublistView(out, range[2]),
    ]);
    final attrs = CmsBuilder.signedAttributes(contentDigest: digest.bytes, certificate: certificate);
    return PadesPreparation._(out, range, cPos, cLen, certificate, attrs, Uint8List.fromList(digest.bytes));
  }

  static const _byteRangePlaceholder = '[0000000000 0000000000 0000000000 0000000000]';

  /// PDF con lo spazio vuoto per la firma: è anche il documento che lo
  /// smartphone può scaricare per ricontrollare l'impronta.
  final Uint8List preparedPdf;
  final List<int> byteRange;
  final int _contentsOffset;
  final int _contentsLength;
  final Certificate certificate;
  final Uint8List signedAttributes;

  /// Impronta SHA-256 dei byte coperti dal ByteRange.
  final Uint8List contentDigest;

  Uint8List get digestToSign => Uint8List.fromList(sha256.convert(signedAttributes).bytes);

  Uint8List finish(Uint8List signature) {
    if (!certificate.rsaPublicKey.verifySha256(digestToSign, signature)) {
      throw const SignatureMismatchException();
    }
    final cms = CmsBuilder.signedData(
      signedAttributes: signedAttributes,
      signature: signature,
      certificate: certificate,
    );
    final hex = cms.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (hex.length > _contentsLength - 2) throw StateError('Spazio riservato alla firma insufficiente');
    final out = Uint8List.fromList(preparedPdf);
    out.setRange(_contentsOffset + 1, _contentsOffset + 1 + hex.length, latin1.encode(hex));
    return out;
  }

  static String _uniqueFieldName(PdfDocument doc) {
    final names = <String>{};
    final acro = doc.resolve(doc.catalog['AcroForm']);
    if (acro is PdfDict) {
      final fields = doc.resolve(acro['Fields']);
      if (fields is PdfArray) {
        for (final f in fields.items) {
          final d = doc.resolve(f);
          if (d is PdfDict && d['T'] is PdfString) names.add((d['T'] as PdfString).text);
        }
      }
    }
    var i = 1;
    while (names.contains('FirmaCIE$i')) {
      i++;
    }
    return 'FirmaCIE$i';
  }

  static String _pdfDate(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return "D:${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}+00'00'";
  }

  /// Aspetto del riquadro: bordo sottile e testo in Helvetica, uno dei 14
  /// caratteri standard, che non richiede di incorporare font.
  static PdfStream _appearanceStream(double w, double h, SignatureAppearanceText text) {
    final n = text.lines.length;
    final pad = 4.0;
    var size = (h - 2 * pad) / (n * 1.25);
    // Larghezza media di Helvetica circa 0,55 em: riduce il corpo se il testo non entra.
    final longest = text.lines.fold(0, (a, l) => l.length > a ? l.length : a);
    if (longest > 0) size = [size, (w - 2 * pad) / (longest * 0.55), 11.0].reduce((a, b) => a < b ? a : b);
    final lead = size * 1.25;
    final sb = StringBuffer()
      ..writeln('q 0.15 0.3 0.6 RG 0.8 w 0.4 0.4 ${PdfNumber.format(w - 0.8)} ${PdfNumber.format(h - 0.8)} re S Q')
      ..writeln('BT /F1 ${PdfNumber.format(size)} Tf 0.1 0.1 0.1 rg');
    var y = h - pad - size;
    for (var i = 0; i < n; i++) {
      final s = PdfString(Uint8List.fromList(_winAnsi(text.lines[i]))).toBytes();
      sb.writeln('1 0 0 1 ${PdfNumber.format(pad)} ${PdfNumber.format(y)} Tm ${latin1.decode(s)} Tj');
      y -= lead;
    }
    sb.writeln('ET');
    return PdfStream(
      PdfDict({
        'Type': const PdfName('XObject'),
        'Subtype': const PdfName('Form'),
        'BBox': PdfArray([const PdfNumber(0), const PdfNumber(0), PdfNumber(w), PdfNumber(h)]),
        'Resources': PdfDict({
          'Font': PdfDict({
            'F1': PdfDict({
              'Type': const PdfName('Font'),
              'Subtype': const PdfName('Type1'),
              'BaseFont': const PdfName('Helvetica'),
              'Encoding': const PdfName('WinAnsiEncoding'),
            }),
          }),
        }),
      }),
      Uint8List.fromList(latin1.encode(sb.toString())),
    );
  }

  /// WinAnsi coincide con Latin-1 per le lettere accentate italiane; i
  /// caratteri fuori tabella diventano "?".
  static List<int> _winAnsi(String s) => [for (final c in s.runes) c < 0x100 ? c : 0x3f];
}

/// Valore scritto così com'è, per i segnaposto di lunghezza fissa.
class _Raw extends PdfObject {
  const _Raw(this.text);
  final String text;
  @override
  void writeTo(BytesBuilder out) => out.add(latin1.encode(text));
}

/// Aggiornamento incrementale (ISO 32000-1, 7.5.6): i byte originali restano
/// intatti, così le firme già presenti continuano a valere.
class _IncrementalWriter {
  _IncrementalWriter(this.doc) : _next = doc.size;

  final PdfDocument doc;
  int _next;
  final Map<int, (int gen, PdfObject obj)> _objects = {};

  PdfRef allocate() => PdfRef(_next++, 0);

  void put(PdfRef ref, PdfObject obj) => _objects[ref.number] = (ref.generation, obj);

  Uint8List build() {
    final out = BytesBuilder(copy: false)..add(doc.bytes);
    final last = doc.bytes.last;
    if (last != 0x0a && last != 0x0d) out.addByte(0x0a);
    final offsets = <int, int>{};
    final numbers = _objects.keys.toList()..sort();
    for (final n in numbers) {
      final (gen, obj) = _objects[n]!;
      offsets[n] = out.length;
      out.add(latin1.encode('$n $gen obj\n'));
      obj.writeTo(out);
      out.add(latin1.encode('\nendobj\n'));
    }
    final trailer = PdfDict({
      'Size': PdfNumber(_next),
      'Root': doc.rootRef,
      if (doc.trailer['Info'] != null) 'Info': doc.trailer['Info']!,
      if (doc.trailer['ID'] != null) 'ID': doc.trailer['ID']!,
      if (doc.lastXrefOffset > 0) 'Prev': PdfNumber(doc.lastXrefOffset),
    });
    if (doc.lastXrefIsStream) {
      _writeXrefStream(out, offsets, numbers, trailer);
    } else {
      _writeXrefTable(out, offsets, numbers, trailer);
    }
    return out.toBytes();
  }

  List<(int, int)> _runs(List<int> numbers) {
    final runs = <(int, int)>[];
    for (final n in numbers) {
      if (runs.isNotEmpty && runs.last.$1 + runs.last.$2 == n) {
        runs[runs.length - 1] = (runs.last.$1, runs.last.$2 + 1);
      } else {
        runs.add((n, 1));
      }
    }
    return runs;
  }

  void _writeXrefTable(BytesBuilder out, Map<int, int> offsets, List<int> numbers, PdfDict trailer) {
    final xref = out.length;
    final sb = StringBuffer('xref\n');
    for (final (start, count) in _runs(numbers)) {
      sb.write('$start $count\n');
      for (var n = start; n < start + count; n++) {
        sb.write('${offsets[n]!.toString().padLeft(10, '0')} ${_objects[n]!.$1.toString().padLeft(5, '0')} n\r\n');
      }
    }
    sb.write('trailer\n');
    out.add(latin1.encode(sb.toString()));
    trailer.writeTo(out);
    out.add(latin1.encode('\nstartxref\n$xref\n%%EOF\n'));
  }

  void _writeXrefStream(BytesBuilder out, Map<int, int> offsets, List<int> numbers, PdfDict trailer) {
    final xrefNumber = _next++;
    trailer['Size'] = PdfNumber(_next);
    final xref = out.length;
    offsets[xrefNumber] = xref;
    final all = [...numbers, xrefNumber];
    final rows = BytesBuilder();
    for (final n in all) {
      final off = offsets[n]!;
      final gen = n == xrefNumber ? 0 : _objects[n]!.$1;
      rows
        ..addByte(1)
        ..add([(off >> 24) & 0xff, (off >> 16) & 0xff, (off >> 8) & 0xff, off & 0xff])
        ..add([(gen >> 8) & 0xff, gen & 0xff]);
    }
    final index = <PdfObject>[];
    for (final (s, c) in _runs(all)) {
      index
        ..add(PdfNumber(s))
        ..add(PdfNumber(c));
    }
    final dict = trailer.copy()
      ..['Type'] = const PdfName('XRef')
      ..['W'] = PdfArray([const PdfNumber(1), const PdfNumber(4), const PdfNumber(2)])
      ..['Index'] = PdfArray(index);
    out.add(latin1.encode('$xrefNumber 0 obj\n'));
    PdfStream(dict, rows.toBytes()).writeTo(out);
    out.add(latin1.encode('\nendobj\nstartxref\n$xref\n%%EOF\n'));
  }
}
