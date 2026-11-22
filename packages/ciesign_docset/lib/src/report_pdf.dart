import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'marks.dart';

/// Un documento da riportare nel rapporto di verifica.
class ReportDocument {
  ReportDocument({required this.name, required this.tree, required this.evaluations, this.marks});

  final String name;
  final ContainedFile tree;
  final List<SignatureEvaluation> evaluations;
  final DocumentMarks? marks;
}

/// Rapporto di verifica in PDF, da conservare o allegare (per esempio agli
/// atti di una gara): per ogni documento impronta, esito, motivo, dettaglio
/// di firme e certificati, file contenuti e data di riferimento.
///
/// Usa i caratteri standard del PDF (Helvetica), che coprono l'italiano;
/// i simboli fuori da Latin-1 vengono sostituiti.
class VerificationReportPdf {
  static Future<Uint8List> build(
    List<ReportDocument> docs, {
    DateTime? reference,
    DateTime? generatedAt,
    String appVersion = '',
  }) async {
    final now = generatedAt ?? DateTime.now();
    final ref = reference ?? now;
    final doc = pw.Document(title: 'Rapporto di verifica CIE Sign', author: 'CIE Sign', creator: 'CIE Sign $appVersion'.trim());
    final base = pw.TextStyle(fontSize: 9);
    final small = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);

    PdfColor colorOf(Outcome? o) => switch (o) {
      Outcome.valid => PdfColors.green800,
      Outcome.warning => PdfColors.orange800,
      Outcome.invalid => PdfColors.red800,
      null => PdfColors.grey700,
    };

    pw.Widget lines(List<ReportLine> l) => pw.Table(
      columnWidths: const {0: pw.FixedColumnWidth(130), 1: pw.FlexColumnWidth()},
      children: [
        for (final (k, v) in l)
          pw.TableRow(
            children: [
              pw.Padding(padding: const pw.EdgeInsets.only(bottom: 3), child: pw.Text(_t(k), style: base.copyWith(fontWeight: pw.FontWeight.bold))),
              pw.Padding(padding: const pw.EdgeInsets.only(bottom: 3), child: pw.Text(_t(v), style: base)),
            ],
          ),
      ],
    );

    final widgets = <pw.Widget>[
      pw.Header(level: 0, child: pw.Text('Rapporto di verifica', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold))),
      lines([
        ('Generato il', formatDate(now, seconds: true)),
        ('Data di riferimento', '${formatDate(ref)}${reference == null ? ' (momento della verifica)' : ' (scelta dall\'utente)'}'),
        ('Documenti', '${docs.length}'),
      ]),
      pw.SizedBox(height: 8),
    ];

    if (docs.length > 1) {
      widgets.add(pw.Text('Riepilogo', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)));
      widgets.add(
        pw.TableHelper.fromTextArray(
          headers: ['#', 'Documento', 'Esito'],
          headerStyle: base.copyWith(fontWeight: pw.FontWeight.bold),
          cellStyle: base,
          columnWidths: const {0: pw.FixedColumnWidth(20), 1: pw.FlexColumnWidth(3), 2: pw.FlexColumnWidth(2)},
          data: [
            for (var i = 0; i < docs.length; i++) ['${i + 1}', _t(docs[i].name), _t(overallText(docs[i].evaluations))],
          ],
        ),
      );
      widgets.add(pw.SizedBox(height: 10));
    }

    for (var d = 0; d < docs.length; d++) {
      final r = docs[d];
      final worst = r.evaluations.isEmpty ? null : worstOutcome(r.evaluations);
      widgets
        ..add(pw.Header(level: 1, text: _t('${docs.length > 1 ? '${d + 1}. ' : ''}${r.name}')))
        ..add(
          pw.Container(
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: colorOf(worst)), borderRadius: pw.BorderRadius.circular(4)),
            child: pw.Text(_t(overallText(r.evaluations)), style: pw.TextStyle(fontSize: 11, color: colorOf(worst), fontWeight: pw.FontWeight.bold)),
          ),
        )
        ..add(pw.SizedBox(height: 4))
        ..add(lines([('Impronta SHA-256', sha256.convert(r.tree.bytes).toString().toUpperCase()), ('Dimensione', '${r.tree.bytes.length} byte')]));

      final inner = r.tree.all.where((f) => f != r.tree).toList();
      if (inner.isNotEmpty) {
        widgets.add(pw.Text('Contenuto', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)));
        widgets.add(
          pw.TableHelper.fromTextArray(
            headers: ['File', 'Provenienza', 'Visualizzato'],
            headerStyle: small.copyWith(fontWeight: pw.FontWeight.bold, color: PdfColors.black),
            cellStyle: small,
            data: [
              for (final f in inner)
                [
                  _t(f.path.substring(r.tree.path.length + 1)),
                  switch (f.origin) {
                    ContainedOrigin.p7m => 'busta .p7m',
                    ContainedOrigin.zip => 'archivio zip',
                    ContainedOrigin.pdfAttachment => 'allegato PDF',
                    ContainedOrigin.document => '',
                  },
                  f.isContainer
                      ? '-'
                      : r.marks?.files[f.fingerprint] == null
                      ? 'no'
                      : '${formatDate(r.marks!.files[f.fingerprint]!.viewedAt)}${r.marks!.files[f.fingerprint]!.external ? ' (app esterna)' : ''}',
                ],
            ],
          ),
        );
        widgets.add(pw.SizedBox(height: 6));
      }

      for (var i = 0; i < r.evaluations.length; i++) {
        final e = r.evaluations[i];
        widgets
          ..add(
            pw.Row(
              children: [
                pw.Expanded(child: pw.Text(_t('${i + 1}. ${e.title}'), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))),
                pw.Text(e.verdict, style: pw.TextStyle(fontSize: 10, color: colorOf(e.outcome), fontWeight: pw.FontWeight.bold)),
              ],
            ),
          )
          ..add(pw.SizedBox(height: 2))
          ..add(lines(e.allLines))
          ..add(pw.SizedBox(height: 6));
      }
    }
    widgets.add(pw.SizedBox(height: 8));
    widgets.add(pw.Text(_t(verificationLimits), style: small));

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        footer: (c) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(_t('CIE Sign ${appVersion.isEmpty ? '' : appVersion} - rapporto di verifica'), style: small),
            pw.Text('Pagina ${c.pageNumber} di ${c.pagesCount}', style: small),
          ],
        ),
        build: (_) => widgets,
      ),
    );
    return doc.save();
  }

  /// Sostituisce i caratteri che Helvetica (Latin-1) non ha.
  static String _t(String s) => s
      .replaceAll('→', '>')
      .replaceAll('…', '...')
      .replaceAll('’', "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[–—]'), '-')
      .replaceAll(RegExp(r'[^\u0000-ÿ]'), '?');
}
