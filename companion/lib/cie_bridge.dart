import 'package:flutter/services.dart';

/// Esito di una sessione con la CIE restituito dal codice nativo Android.
class CieResult {
  CieResult.fromMap(Map<Object?, Object?> m)
      : certificate = m['certificate'] as Uint8List,
        subject = m['subject'] as String,
        issuer = m['issuer'] as String,
        serial = m['serial'] as String,
        notBefore = m['notBefore'] as String,
        notAfter = m['notAfter'] as String,
        certSha256 = m['certSha256'] as Uint8List,
        digest = m['digest'] as Uint8List?,
        signature = m['signature'] as Uint8List?,
        signatureValid = m['signatureValid'] as bool?,
        durationMs = m['durationMs'] as int;

  final Uint8List certificate;
  final String subject;
  final String issuer;
  final String serial;
  final String notBefore;
  final String notAfter;
  final Uint8List certSha256;
  final Uint8List? digest;
  final Uint8List? signature;
  final bool? signatureValid;
  final int durationMs;
}

/// Errore riportato dalla carta o dal lettore NFC.
class CieError implements Exception {
  CieError(this.code, this.message, [this.remainingAttempts]);

  final String code;
  final String message;
  final int? remainingAttempts;

  @override
  String toString() => message;
}

/// Ponte verso il modulo nativo che parla con la CIE.
class CieBridge {
  CieBridge({required this.onStatus}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status') onStatus(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('ciesign/cie');
  final void Function(String) onStatus;

  Future<({bool available, bool enabled})> nfcStatus() async {
    final m = await _channel.invokeMapMethod<String, bool>('nfcStatus') ?? {};
    return (available: m['available'] ?? false, enabled: m['enabled'] ?? false);
  }

  /// Attende la carta, verifica il [pin] e legge il certificato; se [digest] è
  /// presente fa firmare alla carta quell'impronta SHA-256.
  Future<CieResult> start({required String pin, Uint8List? digest}) async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('start', {'pin': pin, 'digest': digest});
      return CieResult.fromMap(m!);
    } on PlatformException catch (e) {
      throw CieError(e.code, e.message ?? e.code, e.code == 'WRONG_PIN' ? e.details as int? : null);
    }
  }

  Future<void> cancel() => _channel.invokeMethod('cancel');
}

String hex(List<int> bytes, {String sep = ''}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);
