import 'dart:typed_data';

import 'bytes.dart';
import 'cie_card.dart';

/// Esito di una sessione con la carta.
class CieSessionResult {
  CieSessionResult(this.certificate, this.digest, this.signature);

  /// Certificato del titolare in DER.
  final Uint8List certificate;

  /// Impronta SHA-256 firmata, se è stata chiesta una firma.
  final Uint8List? digest;

  /// Firma RSA PKCS#1 v1.5 dell'impronta, se è stata chiesta una firma.
  final Uint8List? signature;
}

/// Operazioni di alto livello: lettura del certificato e firma di un'impronta SHA-256.
abstract final class CieSigner {
  static final _sha256DigestInfoPrefix = Bytes.fromHex('3031300D060960864801650304020105000420');

  static Uint8List digestInfoSha256(List<int> digest) {
    if (digest.length != 32) throw ArgumentError("L'impronta SHA-256 deve essere di 32 byte");
    return Bytes.concat([_sha256DigestInfoPrefix, digest]);
  }

  /// Apre il canale sicuro, verifica il PIN, legge il certificato e, se [digestFor]
  /// restituisce un'impronta calcolata dal certificato, la fa firmare alla carta.
  /// Tutto nella stessa sessione, così basta avvicinare la carta una volta.
  static Future<CieSessionResult> run(
    CieCard card,
    String pin,
    Future<Uint8List?> Function(Uint8List certificate) digestFor,
  ) async {
    await card.openSecureChannel();
    await card.verifyPin(pin);
    final cert = await card.readCertificate();
    final digest = await digestFor(cert);
    if (digest == null) return CieSessionResult(cert, null, null);
    if (digest.length != 32) throw ArgumentError("L'impronta SHA-256 deve essere di 32 byte");
    final signature = await card.signDigestInfo(digestInfoSha256(digest));
    return CieSessionResult(cert, digest, signature);
  }

  /// Verifica una firma RSA PKCS#1 v1.5 su un'impronta SHA-256, dati modulo ed esponente pubblici.
  static bool verifyPkcs1Sha256(BigInt modulus, BigInt exponent, List<int> digest, List<int> signature) {
    final k = Bytes.byteLength(modulus);
    final s = Bytes.toBigInt(signature);
    if (signature.length != k || s >= modulus) return false;
    final em = Bytes.toFixedLength(s.modPow(exponent, modulus), k);
    final t = digestInfoSha256(digest);
    if (k < t.length + 11) return false;
    final expected = Uint8List(k)
      ..[1] = 0x01
      ..fillRange(2, k - t.length - 1, 0xFF)
      ..setAll(k - t.length, t);
    return Bytes.equal(em, expected);
  }
}
