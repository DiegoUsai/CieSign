import 'package:ciesign_ades/ciesign_ades.dart' show formatDate;
import 'package:material_ui/material_ui.dart';

/// Legge "gg/mm/aaaa" con l'ora facoltativa "hh:mm"; nullo se non valida.
DateTime? parseItalianDate(String s) {
  final m = RegExp(r'^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})(?:\s+(\d{1,2})[:.](\d{2}))?\s*$').firstMatch(s);
  if (m == null) return null;
  final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
  final h = m[4] == null ? 23 : int.parse(m[4]!), mi = m[5] == null ? 59 : int.parse(m[5]!);
  if (mo < 1 || mo > 12 || d < 1 || h > 23 || mi > 59) return null;
  final t = DateTime(y, mo, d, h, mi);
  return t.day == d && t.month == mo ? t : null;
}

/// Scelta della data di riferimento della verifica ("verifica alla data",
/// come in Aruba Sign). Restituisce la data scelta, oppure [DateTime(0)]
/// per tornare ad "adesso", oppure nullo se si annulla.
Future<DateTime?> pickReferenceDate(BuildContext context, DateTime? current) {
  return showDialog<DateTime>(context: context, builder: (_) => _ReferenceDateDialog(current: current));
}

class _ReferenceDateDialog extends StatefulWidget {
  const _ReferenceDateDialog({this.current});
  final DateTime? current;

  @override
  State<_ReferenceDateDialog> createState() => _ReferenceDateDialogState();
}

class _ReferenceDateDialogState extends State<_ReferenceDateDialog> {
  late final _text = TextEditingController(text: widget.current == null ? '' : formatDate(widget.current));
  String? _error;

  void _ok() {
    final d = parseItalianDate(_text.text);
    if (d == null) {
      setState(() => _error = 'Scrivi la data come gg/mm/aaaa, con l\'ora facoltativa (hh:mm)');
      return;
    }
    if (d.isAfter(DateTime.now())) {
      setState(() => _error = 'La data non può essere nel futuro');
      return;
    }
    Navigator.pop(context, d);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Verifica alla data'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Le firme vengono valutate come erano a quella data: certificati scaduti dopo quella data '
              'risultano validi, e una revoca successiva non conta.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('data-riferimento'),
              controller: _text,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Data e ora',
                hintText: 'gg/mm/aaaa hh:mm',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 8),
            Text('Senza ora vale la fine della giornata (23:59).', style: t.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, DateTime(0)), child: const Text('Torna ad adesso')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        FilledButton(onPressed: _ok, child: const Text('Verifica')),
      ],
    );
  }
}
