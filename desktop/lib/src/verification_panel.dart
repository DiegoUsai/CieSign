import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

export 'package:ciesign_ades/ciesign_ades.dart'
    show Outcome, ReportLine, formatDate, overallText, verificationLimits, verificationReportText;

Color outcomeColor(Outcome? o) => switch (o) {
  Outcome.valid => Colors.green.shade700,
  Outcome.warning => Colors.orange.shade800,
  Outcome.invalid => Colors.red.shade700,
  null => Colors.grey.shade600,
};

IconData outcomeIcon(Outcome? o) => switch (o) {
  Outcome.valid => Icons.verified_outlined,
  Outcome.warning => Icons.warning_amber_outlined,
  Outcome.invalid => Icons.gpp_bad_outlined,
  null => Icons.help_outline,
};

/// Verifica di un documento, come in Aruba Sign ma con le priorità chieste:
/// prima l'esito complessivo, poi una riga per firma con VALIDA o NON VALIDA
/// e il motivo; controlli, certificato e proprietà solo aprendo la firma.
class VerificationPanel extends StatelessWidget {
  const VerificationPanel({
    super.key,
    required this.evaluations,
    required this.documentName,
    this.reference,
    this.checkingRevocation = false,
  });

  final List<SignatureEvaluation> evaluations;
  final String documentName;

  /// Data scelta per la verifica; nulla per "adesso".
  final DateTime? reference;
  final bool checkingRevocation;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final worst = evaluations.isEmpty ? null : worstOutcome(evaluations);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('esito-verifica'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: evaluations.isEmpty ? scheme.surfaceContainerHighest : outcomeColor(worst).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(evaluations.isEmpty ? Icons.info_outline : outcomeIcon(worst), color: evaluations.isEmpty ? null : outcomeColor(worst)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(overallText(evaluations), style: t.titleSmall),
                    if (reference != null) Text('Verifica alla data ${formatDate(reference)}', style: t.bodySmall),
                    if (checkingRevocation)
                      Row(
                        children: [
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                          const SizedBox(width: 6),
                          Text('Controllo della revoca in corso…', style: t.bodySmall),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final e in evaluations) SignatureTile(evaluation: e),
        if (evaluations.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showTextReport(context, documentName, evaluations, reference),
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Rapporto in testo'),
            ),
          ),
      ],
    );
  }
}

/// Una firma: riga sintetica sempre visibile, controlli e pulsanti a richiesta.
class SignatureTile extends StatefulWidget {
  const SignatureTile({super.key, required this.evaluation});
  final SignatureEvaluation evaluation;

  @override
  State<SignatureTile> createState() => _SignatureTileState();
}

class _SignatureTileState extends State<SignatureTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.evaluation;
    final r = e.report;
    final t = Theme.of(context).textTheme;
    final color = outcomeColor(e.outcome);
    final kind = r.isDocumentTimestamp ? 'Marca temporale' : (e.pades ? 'Firma (PAdES)' : 'Firma (CAdES)');
    final when = r.timestamp?.isValid == true ? r.timestamp!.genTime : r.signingTime;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(outcomeIcon(e.outcome), color: color, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.isDocumentTimestamp ? kind : e.title, style: t.titleSmall),
                        Text(
                          [
                            r.isDocumentTimestamp ? (r.timestamp?.tsaName ?? '') : '$kind, ${formatDate(when)}',
                            ?e.where,
                          ].join('\n'),
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: color),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(e.verdict, style: t.labelSmall?.copyWith(color: color, fontWeight: FontWeight.bold)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (e.reason != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 12, 10),
              child: Text(e.reason!, style: t.bodySmall?.copyWith(color: color)),
            ),
          if (_open) _details(context, e),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, SignatureEvaluation e) {
    final r = e.report;
    final t = Theme.of(context).textTheme;
    Widget check(bool? ok, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok == null ? Icons.remove_circle_outline : (ok ? Icons.check_circle_outline : Icons.cancel_outlined),
            size: 18,
            color: ok == null ? Colors.orange.shade800 : (ok ? Colors.green.shade700 : Colors.red.shade700),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: t.bodySmall)),
        ],
      ),
    );
    final time = e.certificateTime;
    final certOk = time == CertificateTime.valid || time == CertificateTime.validAtTimestamp;
    final rev = e.revocation.status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          check(r.isIntact, r.isDocumentTimestamp && r.isIntact ? 'Marca temporale integra' : integrityText(r.integrity)),
          check(r.isDocumentTimestamp && !certOk ? null : certOk, e.certificateTimeText),
          if (!r.isDocumentTimestamp)
            check(
              switch (rev) {
                RevocationStatus.good => true,
                RevocationStatus.revoked => !e.isRevokedAtReference,
                _ => null,
              },
              e.revocationText,
            ),
          if (r.chain != null)
            check(
              r.chain!.status == ChainStatus.brokenChain || r.chain!.status == ChainStatus.cieExpired ? false : true,
              e.chainText,
            ),
          if (r.hasTimestamp && !r.isDocumentTimestamp) check(r.timestamp?.isValid, e.timestampText),
          if (r.coversWholeDocument == false) check(null, 'Il documento ha aggiunte successive a questa firma'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => showLines(context, 'Certificato', e.certificateLines),
                child: const Text('Mostra certificato'),
              ),
              OutlinedButton(
                onPressed: () => showLines(
                  context,
                  r.isDocumentTimestamp ? 'Proprietà della marca temporale' : 'Proprietà della firma',
                  e.signatureLines,
                ),
                child: Text(r.isDocumentTimestamp ? 'Mostra proprietà marca' : 'Mostra proprietà firma'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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

Future<void> showLines(BuildContext context, String title, List<ReportLine> lines) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 620, child: SingleChildScrollView(child: _lines(context, lines))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi'))],
    ),
  );
}

Future<void> showTextReport(BuildContext context, String documentName, List<SignatureEvaluation> evals, DateTime? at) {
  final text = verificationReportText(documentName, evals, at: at);
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
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rapporto copiato negli appunti.')));
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
