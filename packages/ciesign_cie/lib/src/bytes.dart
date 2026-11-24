import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';

import 'errors.dart';

/// Funzioni di supporto per array di byte e primitive crittografiche del secure messaging.
abstract final class Bytes {
  static final _random = Random.secure();

  static String hex(List<int> b) => b.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  static Uint8List fromHex(String hex) {
    final clean = hex.replaceAll(' ', '');
    if (clean.length.isOdd) throw ArgumentError('Stringa esadecimale di lunghezza dispari');
    return Uint8List.fromList([for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)]);
  }

  static Uint8List concat(List<List<int>> parts) {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p);
    }
    return out.toBytes();
  }

  static Uint8List random(int size) => Uint8List.fromList(List.generate(size, (_) => _random.nextInt(256)));

  static Uint8List sha256(List<List<int>> parts) => Uint8List.fromList(c.sha256.convert(concat(parts)).bytes);

  static bool equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Padding ISO/IEC 9797-1 metodo 2: 0x80 seguito da zeri fino al multiplo di 8.
  static Uint8List isoPad(List<int> data) {
    final padded = Uint8List((data.length ~/ 8 + 1) * 8);
    padded.setAll(0, data);
    padded[data.length] = 0x80;
    return padded;
  }

  /// Rimuove il padding ISO/IEC 9797-1 metodo 2.
  static Uint8List isoUnpad(List<int> data) {
    var i = data.length - 1;
    while (i >= 0 && data[i] == 0) {
      i--;
    }
    if (i < 0 || data[i] != 0x80) throw SecureMessagingException('Padding ISO assente nella risposta');
    return Uint8List.fromList(data.sublist(0, i));
  }

  /// Incrementa di uno un contatore big-endian (il Send Sequence Counter).
  static void increment(Uint8List counter) {
    for (var i = counter.length - 1; i >= 0; i--) {
      final v = counter[i] + 1;
      counter[i] = v & 0xFF;
      if (v <= 0xFF) return;
    }
  }

  static Uint8List stripLeadingZeros(List<int> data) {
    var i = 0;
    while (i < data.length - 1 && data[i] == 0) {
      i++;
    }
    return Uint8List.fromList(data.sublist(i));
  }

  static Uint8List right(List<int> data, int n) => Uint8List.fromList(data.sublist(data.length - n));

  static BigInt toBigInt(List<int> data) => data.isEmpty ? BigInt.zero : BigInt.parse(hex(data), radix: 16);

  /// Converte un intero non negativo in un array di lunghezza fissa (I2OSP di PKCS#1).
  static Uint8List toFixedLength(BigInt value, int length) {
    var h = value.toRadixString(16);
    if (h.length.isOdd) h = '0$h';
    final raw = value == BigInt.zero ? Uint8List(0) : fromHex(h);
    if (raw.length > length) throw ArgumentError('Valore troppo grande per $length byte');
    return Uint8List(length)..setAll(length - raw.length, raw);
  }

  static int byteLength(BigInt n) => (n.bitLength + 7) ~/ 8;
}

/// Primitive crittografiche usate dal secure messaging della CIE.
abstract final class CieCrypto {
  static Uint8List _key24(List<int> key) => switch (key.length) {
        8 => Bytes.concat([key, key, key]),
        16 => Bytes.concat([key, key.sublist(0, 8)]),
        24 => Uint8List.fromList(key),
        _ => throw ArgumentError('Chiave 3DES di lunghezza ${key.length}'),
      };

  static Uint8List _tdes(bool encrypt, List<int> key, List<int> data) {
    if (data.length % 8 != 0) throw ArgumentError('Dati 3DES non allineati');
    final cipher = CBCBlockCipher(DESedeEngine())
      ..init(encrypt, ParametersWithIV(KeyParameter(_key24(key)), Uint8List(8)));
    final input = Uint8List.fromList(data);
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 8) {
      cipher.processBlock(input, off, out, off);
    }
    return out;
  }

  /// 3DES in modalità CBC con IV nullo e senza padding (il padding ISO è applicato a parte).
  static Uint8List tdesEncrypt(List<int> key, List<int> data) => _tdes(true, key, data);

  static Uint8List tdesDecrypt(List<int> key, List<int> data) => _tdes(false, key, data);

  /// Retail MAC, cioè ISO/IEC 9797-1 algoritmo 3 con DES. I dati devono essere già allineati a 8 byte.
  static Uint8List retailMac(List<int> key, List<int> paddedData) {
    if (key.length != 16) throw ArgumentError('La chiave del MAC deve essere di 16 byte');
    if (paddedData.length % 8 != 0) throw ArgumentError('Dati del MAC non allineati');
    final k1 = key.sublist(0, 8), k2 = key.sublist(8, 16);
    final cbc = tdesEncrypt(k1, paddedData);
    final mid = tdesDecrypt(k2, cbc.sublist(cbc.length - 8));
    return tdesEncrypt(k1, mid);
  }

  /// Operazione RSA grezza (anche g^x mod p del Diffie-Hellman), con risultato lungo quanto il modulo.
  static Uint8List modPow(List<int> data, List<int> exponent, List<int> modulus) {
    final n = Bytes.toBigInt(modulus);
    return Bytes.toFixedLength(Bytes.toBigInt(data).modPow(Bytes.toBigInt(exponent), n), Bytes.byteLength(n));
  }
}
