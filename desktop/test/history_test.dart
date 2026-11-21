import 'dart:io';

import 'package:cie_sign_desktop/src/signed_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('elenco dei documenti firmati: aggiunta, ordine, persistenza e rimozione', () async {
    final dir = await Directory.systemTemp.createTemp('storico');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/signed-history.json');
    final h = await SignedHistory.open(file: f);
    expect(h.entries, isEmpty);
    await h.add(
      SignedEntry(
        path: 'C:\\Doc\\a-signed.pdf',
        signedAt: DateTime.utc(2026, 11, 21, 10),
        format: 'PAdES',
        holder: 'MARIO ROSSI',
      ),
    );
    await h.add(
      SignedEntry(
        path: 'C:\\Doc\\b.pdf.p7m',
        signedAt: DateTime.utc(2026, 11, 21, 11),
        format: 'CAdES',
        holder: 'MARIO ROSSI',
        test: true,
      ),
    );
    await h.add(
      SignedEntry(
        path: 'C:\\Doc\\a-signed.pdf',
        signedAt: DateTime.utc(2026, 11, 21, 12),
        format: 'PAdES',
        holder: 'MARIO ROSSI',
      ),
    );
    expect(h.entries.map((e) => e.name), ['a-signed.pdf', 'b.pdf.p7m']);

    final again = await SignedHistory.open(file: f);
    expect(again.entries, hasLength(2));
    expect(again.entries[1].test, isTrue);
    expect(again.entries[0].signedAt, DateTime.utc(2026, 11, 21, 12));

    await again.remove(again.entries.first);
    expect((await SignedHistory.open(file: f)).entries.single.name, 'b.pdf.p7m');
  });

  test('un file illeggibile non blocca l\'app', () async {
    final dir = await Directory.systemTemp.createTemp('storico');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/signed-history.json')..writeAsStringSync('non è json');
    expect((await SignedHistory.open(file: f)).entries, isEmpty);
  });
}
