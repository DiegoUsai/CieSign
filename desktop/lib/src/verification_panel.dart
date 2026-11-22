import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

String formatDate(DateTime? d, {bool seconds = false}) {
  if (d == null) return 'non indicata';
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final s = seconds ? ':${two(l.second)}' : '';
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}$s';
}

String integrityText(SignatureIntegrity i) => switch (i) {
  SignatureIntegrity.valid => 'Firma integra',
  SignatureIntegrity.contentModified => 'Documento modificato dopo la firma',
  SignatureIntegrity.signatureInvalid => 'Firma non valida',
  SignatureIntegrity.certificateMissing => 'Certificato del firmatario assente',
  SignatureIntegrity.unsupportedAlgorithm => 'Algoritmo non supportato',
};

String _hex(List<int> b, {String sep = ':'}) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);

/// Codice fiscale dal serialNumber del soggetto ("TINIT-RSSMRA80A01H501U").
String? fiscalCode(Certificate c) {
  final s = c.subject.get(Oids.serialNumber);
  if (s == null) return null;
  return s.startsWith('TINIT-') ? s.substring(6) : s;
}

String issuerName(Certificate c) =>
    c.issuer.get(Oids.organization) ?? c.issuer.get(Oids.commonName) ?? c.issuer.toString();

/// Testo breve sulla marca temporale, per la scheda e il rapporto.
String timestampText(SignatureReport r) {
  final t = r.timestamp;
  if (t == null) return r.hasTimestamp ? 'Marca temporale presente ma non leggibile' : 'Nessuna marca temporale';
  final who = t.tsaName == null ? '' : ' da ${t.tsaName}';
  final esito = t.isValid
      ? 'integra'
      : !t.imprintMatches
      ? 'non corrisponde ai dati marcati'
      : 'non integra (${integrityText(t.integrity).toLowerCase()})';
  return 'Marca temporale del ${formatDate(t.genTime, seconds: true)}$who, $esito';
}

/// Una riga del dettaglio: etichetta e valore.
typedef ReportLine = (String label, String value);

/// Esito di una firma o marca: valida, da controllare o non valida.
enum Outcome { valid, warning, invalid }

Outcome outcomeOf(SignatureReport r) {
  if (!r.isIntact) return Outcome.invalid;
  final time = r.certificateTime;
  if (r.isDocumentTimestamp) return time == CertificateTime.valid ? Outcome.valid : Outcome.warning;
  if (time == CertificateTime.expired || time == CertificateTime.notYetValid) return Outcome.invalid;
  final chain = r.chain?.status;
  if (chain == ChainStatus.brokenChain || chain == ChainStatus.cieExpired) return Outcome.invalid;
  return Outcome.valid;
}

/// Validità del certificato in una frase.
String certificateTimeText(SignatureReport r) {
  final c = r.certificate;
  if (c == null) return 'Certificato assente';
  final scad = formatDate(c.notAfter);
  return switch (r.certificateTime) {
    CertificateTime.valid => 'Certificato valido fino al $scad',
    CertificateTime.validAtTimestamp =>
      'Certificato scaduto il $scad, ma la marca temporale prova che la firma è stata apposta prima',
    CertificateTime.expired =>
      r.isDocumentTimestamp
          ? 'Certificato della TSA scaduto il $scad'
          : 'Certificato scaduto il $scad: nessuna marca temporale prova che la firma sia stata apposta prima della scadenza',
    CertificateTime.notYetValid =>
      'Certificato non ancora valido alla data della firma (valido dal ${formatDate(c.notBefore)})',
    CertificateTime.unknown => 'Certificato assente',
  };
}

/// Valore della firma secondo la catena. Per i certificati di altri
/// certificatori (per esempio una firma digitale InfoCert o Aruba) l'app non
/// controlla ancora l'elenco europeo dei prestatori qualificati e lo dice.
String chainText(SignatureReport r) {
  final chain = r.chain!;
  if (chain.status == ChainStatus.unknownIssuer && r.certificate != null) {
    return 'Certificato di ${issuerName(r.certificate!)}, non CIE: qualificazione non ancora verificata dall\'app';
  }
  return chain.label;
}

/// Prima riga della scheda: l'esito in poche parole.
String headline(SignatureReport r) {
  if (!r.isIntact) return integrityText(r.integrity);
  if (r.isDocumentTimestamp) return 'Marca temporale integra';
  return switch (r.certificateTime) {
    CertificateTime.expired => 'Non valida: certificato scaduto il ${formatDate(r.certificate!.notAfter)}',
    CertificateTime.notYetValid => 'Non valida: certificato non ancora valido',
    _ when r.chain?.status == ChainStatus.brokenChain => 'Non valida: catena di certificazione non valida',
    _ when r.chain?.status == ChainStatus.cieExpired => 'Non valida: certificato CIE scaduto alla data della firma',
    _ => 'Firma integra, certificato valido',
  };
}

/// Dettaglio di una firma, usato sia nel dialogo sia nel rapporto copiabile.
List<ReportLine> reportLines(SignatureReport r, {required bool pades}) {
  final c = r.certificate;
  return [
    ('Esito', headline(r)),
    ('Integrità', r.isDocumentTimestamp && r.isIntact ? 'Marca temporale integra' : integrityText(r.integrity)),
    ('Validità del certificato', certificateTimeText(r)),
    if (r.chain != null) ...[
      ('Valore della firma', chainText(r)),
      if (r.chain!.note != null) ('Nota', r.chain!.note!),
      if (r.chain!.path.length > 1)
        (
          'Catena di certificazione',
          r.chain!.path.map((c) => c.subject.get(Oids.commonName) ?? c.holderName).join(' → '),
        ),
    ],
    (
      'Tipo',
      r.isDocumentTimestamp
          ? 'Marca temporale del documento (PAdES, DocTimeStamp)'
          : pades
          ? 'Firma PAdES${r.subFilter == null ? '' : ' (${r.subFilter})'}'
          : 'Firma CAdES (.p7m)',
    ),
    if (c != null) ...[
      (r.isDocumentTimestamp ? 'Autorità di marcatura' : 'Firmatario', c.holderName),
      if (!r.isDocumentTimestamp && fiscalCode(c) != null) ('Codice fiscale', fiscalCode(c)!),
      ('Emittente del certificato', issuerName(c)),
      ('Certificato valido', 'dal ${formatDate(c.notBefore)} al ${formatDate(c.notAfter)}'),
      ('Numero di serie', c.serialNumber.toRadixString(16).toUpperCase()),
      ('Impronta SHA-256', _hex(c.sha256Fingerprint)),
    ] else
      ('Firmatario', 'certificato non presente nella firma'),
    if (!r.isDocumentTimestamp) ...[
      (
        'Data dichiarata',
        '${formatDate(r.signingTime, seconds: true)} (orologio del PC di chi firma, non certificata)',
      ),
      ('Marca temporale', timestampText(r)),
    ] else
      ('Data certificata', formatDate(r.signingTime, seconds: true)),
    if (r.coversWholeDocument != null)
      (
        'Copertura',
        r.coversWholeDocument!
            ? 'Copre l\'intero documento'
            : 'Il documento ha aggiunte successive a questa firma (per esempio altre firme o marche)',
      ),
    if (r.fieldName != null && r.fieldName!.isNotEmpty) ('Campo firma', r.fieldName!),
  ];
}

const verificationLimits =
    'Questa versione verifica l\'integrità delle firme e delle marche temporali, la scadenza dei '
    'certificati e riconosce quelli della CIE emessi dal Ministero dell\'Interno. Non controlla ancora '
    'la revoca dei certificati (OCSP, CRL) né l\'elenco europeo dei prestatori qualificati.';

/// Rapporto di verifica in testo semplice, da copiare negli appunti.
String verificationReportText(String documentName, List<SignatureReport> reports, {required bool pades}) {
  final b = StringBuffer()
    ..writeln('Rapporto di verifica Firmami')
    ..writeln('Documento: $documentName')
    ..writeln('Verificato il: ${formatDate(DateTime.now(), seconds: true)}')
    ..writeln('Esito: ${overallText(reports)}')
    ..writeln();
  for (var i = 0; i < reports.length; i++) {
    final r = reports[i];
    b.writeln(r.isDocumentTimestamp ? '${i + 1}. Marca temporale del documento' : '${i + 1}. Firma');
    for (final (l, v) in reportLines(r, pades: pades)) {
      b.writeln('   $l: $v');
    }
    b.writeln();
  }
  b.writeln(verificationLimits);
  return b.toString();
}

/// Esito complessivo in una frase.
String overallText(List<SignatureReport> reports) {
  if (reports.isEmpty) return 'Il documento non contiene firme';
  final firme = reports.where((r) => !r.isDocumentTimestamp).length;
  final marche = reports.length - firme;
  final invalid = reports.where((r) => outcomeOf(r) == Outcome.invalid).length;
  final warning = reports.where((r) => outcomeOf(r) == Outcome.warning).length;
  String n(int k, String s, String p) => k == 1 ? '1 $s' : '$k $p';
  final parts = [
    if (firme > 0) n(firme, 'firma', 'firme'),
    if (marche > 0) n(marche, 'marca temporale del documento', 'marche temporali del documento'),
  ].join(' e ');
  if (invalid > 0) return '$parts: ${n(invalid, 'non è valida', 'non sono valide')}';
  if (warning > 0) return '$parts: ${n(warning, 'da controllare', 'da controllare')}';
  return reports.length == 1 ? '$parts, valida' : '$parts, tutte valide';
}

/// Sezione di verifica (UC5): esito complessivo, una scheda per firma con il
/// dettaglio a richiesta e il rapporto copiabile.
class VerificationPanel extends StatelessWidget {
  const VerificationPanel({super.key, required this.reports, required this.documentName, required this.pades});

  final List<SignatureReport> reports;
  final String documentName;
  final bool pades;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final outcomes = reports.map(outcomeOf).toSet();
    final worst = outcomes.contains(Outcome.invalid)
        ? Outcome.invalid
        : outcomes.contains(Outcome.warning)
        ? Outcome.warning
        : Outcome.valid;
    final color = reports.isEmpty ? scheme.surfaceContainerHighest : _color(worst).withValues(alpha: 0.15);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('esito-verifica'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Icon(reports.isEmpty ? Icons.info_outline : _icon(worst), color: reports.isEmpty ? null : _color(worst)),
              const SizedBox(width: 12),
              Expanded(child: Text(overallText(reports), style: t.titleSmall)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final r in reports)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(r.isDocumentTimestamp ? Icons.schedule : _icon(outcomeOf(r)), color: _color(outcomeOf(r))),
              title: Text(
                r.isDocumentTimestamp
                    ? 'Marca temporale del documento'
                    : r.certificate?.holderName ?? 'Firmatario sconosciuto',
              ),
              subtitle: Text(
                [
                  if (r.isDocumentTimestamp) ...[
                    headline(r),
                    if (r.certificateTime != CertificateTime.valid) certificateTimeText(r),
                    'Data certificata: ${formatDate(r.signingTime)}',
                    if (r.timestamp?.tsaName != null) 'Da ${r.timestamp!.tsaName}',
                  ] else ...[
                    headline(r),
                    if (r.certificateTime == CertificateTime.validAtTimestamp) certificateTimeText(r),
                    if (r.chain != null) chainText(r),
                    'Data dichiarata: ${formatDate(r.signingTime)}',
                    if (r.hasTimestamp) timestampText(r),
                  ],
                  if (r.coversWholeDocument == false) 'Il documento ha aggiunte successive',
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showSignatureDetails(context, r, pades: pades),
            ),
          ),
        if (reports.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showVerificationReport(context, documentName, reports, pades: pades),
              icon: const Icon(Icons.summarize_outlined),
              label: const Text('Rapporto di verifica'),
            ),
          ),
        Text(verificationLimits, style: t.bodySmall),
      ],
    );
  }
}

Color _color(Outcome o) => switch (o) {
  Outcome.valid => Colors.green.shade700,
  Outcome.warning => Colors.orange.shade800,
  Outcome.invalid => Colors.red.shade700,
};

IconData _icon(Outcome o) => switch (o) {
  Outcome.valid => Icons.verified_outlined,
  Outcome.warning => Icons.warning_amber_outlined,
  Outcome.invalid => Icons.gpp_bad_outlined,
};

Widget _lines(BuildContext context, List<ReportLine> lines) {
  final t = Theme.of(context).textTheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (l, v) in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 170, child: Text(l, style: t.labelLarge)),
              Expanded(child: SelectableText(v, style: t.bodyMedium)),
            ],
          ),
        ),
    ],
  );
}

Future<void> showSignatureDetails(BuildContext context, SignatureReport r, {required bool pades}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(r.isDocumentTimestamp ? 'Marca temporale del documento' : 'Dettaglio della firma'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(child: _lines(context, reportLines(r, pades: pades))),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi'))],
    ),
  );
}

Future<void> showVerificationReport(
  BuildContext context,
  String documentName,
  List<SignatureReport> reports, {
  required bool pades,
}) {
  final text = verificationReportText(documentName, reports, pades: pades);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rapporto di verifica'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Rapporto copiato negli appunti.')));
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copia'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
      ],
    ),
  );
}
