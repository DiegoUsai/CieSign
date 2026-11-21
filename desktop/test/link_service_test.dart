import 'package:cie_sign_desktop/src/link_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('crea l\'identità e mette il seme nel portachiavi', () async {
    final store = MemoryKeyStore();
    final a = await LinkService.loadIdentity(null, store, fallbackName: 'PC-PROVA');
    expect(a.inSystemStore, isTrue);
    expect(store.values.values.single, isNotEmpty);
    // Al riavvio il file JSON non contiene il seme: si legge dal portachiavi.
    final json = a.identity.toJson()..remove('seed');
    final b = await LinkService.loadIdentity(json, store, fallbackName: 'x');
    expect(b.identity.publicKey, a.identity.publicKey);
    expect(b.identity.id, a.identity.id);
  });

  test('sposta nel portachiavi il seme del vecchio file JSON', () async {
    final store = MemoryKeyStore();
    final old = (await LinkService.loadIdentity(null, MemoryKeyStore(), fallbackName: 'PC')).identity;
    final r = await LinkService.loadIdentity(old.toJson(), store, fallbackName: 'x');
    expect(r.identity.publicKey, old.publicKey);
    expect(store.values.values.single, old.toJson()['seed']);
  });

  test('senza portachiavi il seme resta nel file', () async {
    final r = await LinkService.loadIdentity(null, MemoryKeyStore(broken: true), fallbackName: 'PC');
    expect(r.inSystemStore, isFalse);
  });
}
