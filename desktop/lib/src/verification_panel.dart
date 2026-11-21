import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:material_ui/material_ui.dart';

String formatDate(DateTime? d) {
  if (d == null) return 'non indicata';
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

String integrityText(SignatureIntegrity i) => switch (i) {
  SignatureIntegrity.valid => 'Firma integra',
  SignatureIntegrity.contentModified => 'Documento modificato dopo la firma',
  SignatureIntegrity.signatureInvalid => 'Firma non valida',
  SignatureIntegrity.certificateMissing => 'Certificato del firmatario assente',
  SignatureIntegrity.unsupportedAlgorithm => 'Algoritmo non supportato',
};

/// Elenco delle firme trovate (UC5). Per ora l'esito riguarda l'integrità;
/// catena di certificazione e revoca arriveranno in seguito, e lo si dice.
class VerificationPanel extends StatelessWidget {
  const VerificationPanel({super.key, required this.reports});

  final List<SignatureReport> reports;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (reports.isEmpty) return Text('Nessuna firma nel documento.', style: t.bodyMedium);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in reports)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(
                r.isIntact ? Icons.verified_outlined : Icons.error_outline,
                color: r.isIntact ? Colors.green.shade700 : Colors.red.shade700,
              ),
              title: Text(r.certificate?.holderName ?? 'Firmatario sconosciuto'),
              subtitle: Text(
                [
                  integrityText(r.integrity),
                  'Data dichiarata: ${formatDate(r.signingTime)}',
                  if (r.hasTimestamp) 'Con marca temporale',
                  if (r.coversWholeDocument == false) 'Il documento ha modifiche successive a questa firma',
                  if (r.certificate != null) 'Emittente: ${r.certificate!.issuer}',
                ].join('\n'),
              ),
              isThreeLine: true,
            ),
          ),
        Text(
          'Verifica di integrità. Il controllo del certificato presso il Ministero dell\'Interno '
          '(catena e revoca) non è ancora disponibile in questa versione.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}
