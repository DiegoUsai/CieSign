import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _x25519 = X25519();
final _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List unb64u(String s) => base64Url.decode(s.padRight((s.length + 3) & ~3, '='));

/// Identità permanente di un dispositivo (PC o smartphone): un identificativo
/// casuale, un nome leggibile e una coppia di chiavi **X25519** statica.
/// Si salva solo il seme di 32 byte, da tenere nel portachiavi di sistema.
class DeviceIdentity {
  DeviceIdentity._(this.id, this.name, this.seed, this.keyPair, this.publicKey);

  static Future<DeviceIdentity> create(String name) =>
      restore(id: b64u(randomBytes(12)), name: name, seed: randomBytes(32));

  static Future<DeviceIdentity> restore({required String id, required String name, required List<int> seed}) async {
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return DeviceIdentity._(id, name, Uint8List.fromList(seed), kp, Uint8List.fromList(pub.bytes));
  }

  final String id;
  final String name;
  final Uint8List seed;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'seed': b64u(seed)};

  static Future<DeviceIdentity> fromJson(Map<String, Object?> j) =>
      restore(id: j['id'] as String, name: j['name'] as String, seed: unb64u(j['seed'] as String));
}

/// Dispositivo con cui l'abbinamento è stato confermato.
class PairedDevice {
  PairedDevice({required this.id, required this.name, required this.publicKey, required this.pairedAt});

  final String id;
  final String name;
  final Uint8List publicKey;
  final DateTime pairedAt;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'key': b64u(publicKey),
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  factory PairedDevice.fromJson(Map<String, Object?> j) => PairedDevice(
    id: j['id'] as String,
    name: j['name'] as String,
    publicKey: unb64u(j['key'] as String),
    pairedAt: DateTime.parse(j['pairedAt'] as String),
  );
}

Future<SimpleKeyPair> newEphemeral() => _x25519.newKeyPair();

Future<Uint8List> dh(SimpleKeyPair mine, List<int> theirs) async {
  final s = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await s.extractBytes());
}

Future<Uint8List> publicOf(SimpleKeyPair kp) async => Uint8List.fromList((await kp.extractPublicKey()).bytes);

Future<Uint8List> hkdf(List<int> ikm, {required List<int> salt, required String info, int length = 32}) async {
  final k = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: length,
  ).deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: utf8.encode(info));
  return Uint8List.fromList(await k.extractBytes());
}

Future<Uint8List> hmacSha256(List<int> key, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> sha256Of(List<int> data) async => Uint8List.fromList((await Sha256().hash(data)).bytes);

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
