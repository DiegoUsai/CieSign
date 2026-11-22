import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Archivio dei segreti, separato per poterlo sostituire nei test.
abstract class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Portachiavi di sistema: Credential Manager su Windows, Portachiavi su
/// macOS, libsecret su Linux.
///
/// Su macOS si usa il Portachiavi classico e non quello con protezione dei
/// dati: quest'ultimo richiede l'entitlement keychain-access-groups e quindi
/// un profilo di provisioning Apple, che un'app firmata ad hoc non ha.
class SystemKeyStore implements KeyStore {
  final _s = const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
}

/// Archivio in memoria, per i test.
class MemoryKeyStore implements KeyStore {
  MemoryKeyStore({this.broken = false});

  final bool broken;
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async {
    if (broken) throw StateError('portachiavi non disponibile');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (broken) throw StateError('portachiavi non disponibile');
    values[key] = value;
  }
}
