/// Quando è avvenuta un'azione, detto come lo direbbe una persona: serve a
/// distinguere a colpo d'occhio cosa si è appena rivisto da cosa si era visto
/// ieri o giorni fa, quando si riprende o si rifà un lavoro.
///
/// "adesso" (meno di 5 minuti), "di recente" (meno di un'ora), "oggi alle
/// 10:42", "ieri alle 18:03", altrimenti "il 12/11/2026".
String relativeTime(DateTime t, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final l = t.toLocal();
  final diff = n.difference(l);
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(l.hour)}:${two(l.minute)}';
  if (diff.inMinutes < 5 && !diff.isNegative) return 'adesso';
  if (diff.inMinutes < 60 && !diff.isNegative) return 'di recente';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(l.year, l.month, l.day);
  final days = today.difference(day).inHours ~/ 24;
  if (days == 0) return 'oggi alle $hm';
  if (days == 1) return 'ieri alle $hm';
  return 'il ${two(l.day)}/${two(l.month)}/${l.year}';
}

/// Freschezza di una marcatura, per scegliere colore o icona nelle app.
enum Freshness {
  /// In questa sessione di lavoro (meno di un'ora).
  now,

  /// Oggi, ma prima.
  today,

  /// Ieri o prima.
  earlier,
}

Freshness freshnessOf(DateTime t, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final l = t.toLocal();
  if (n.difference(l).inMinutes < 60) return Freshness.now;
  if (n.year == l.year && n.month == l.month && n.day == l.day) return Freshness.today;
  return Freshness.earlier;
}
