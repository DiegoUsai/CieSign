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
  CieError(this.code, this.message, {this.remainingAttempts, this.trace});

  final String code;
  final String message;
  final int? remainingAttempts;

  /// Registro tecnico dei comandi scambiati con la carta (senza dati né PIN).
  final String? trace;

  @override
  String toString() => message;
}

/// Ponte verso il modulo nativo che parla con la CIE.
class CieBridge {
  CieBridge({this.onStatus, this.onLink}) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'status':
          onStatus?.call(call.arguments as String);
        case 'link':
          onLink?.call(call.arguments as String);
        case 'prepare':
          final prepare = _prepare;
          if (prepare == null) throw PlatformException(code: 'PREPARE_FAILED', message: 'Nessuna firma in corso');
          try {
            return await prepare(call.arguments as Uint8List);
          } on Object catch (e) {
            throw PlatformException(code: 'PREPARE_FAILED', message: '$e');
          }
      }
      return null;
    });
  }

  static const _channel = MethodChannel('ciesign/cie');

  /// Stato dell'operazione con la carta, da mostrare all'utente.
  void Function(String)? onStatus;

  /// Collegamento `ciesign://pair?...` aperto mentre l'app è già avviata,
  /// per esempio inquadrando il QR code con la fotocamera del telefono.
  void Function(String)? onLink;

  /// Collegamento con cui l'app è stata avviata, se c'è; lo si legge una volta.
  Future<String?> initialLink() async {
    try {
      return await _channel.invokeMethod<String>('initialLink');
    } on MissingPluginException {
      return null;
    }
  }

  /// Nome del telefono (produttore e modello), mostrato sul PC.
  Future<String> deviceName() async {
    try {
      return await _channel.invokeMethod<String>('deviceName') ?? 'Smartphone';
    } on MissingPluginException {
      return 'Smartphone';
    }
  }

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
      final details = e.details;
      throw CieError(
        e.code,
        e.message ?? e.code,
        remainingAttempts: details is int ? details : null,
        trace: details is String ? details : null,
      );
    }
  }

  Future<Uint8List> Function(Uint8List certificate)? _prepare;

  /// Come [start], ma l'impronta da firmare la calcola [prepare] dal certificato
  /// appena letto, nella stessa sessione: la carta si avvicina una volta sola.
  /// Se [prepare] fallisce la sessione si chiude con l'errore `PREPARE_FAILED`,
  /// il cui messaggio è quello dell'eccezione.
  Future<CieResult> startWithPreparation({
    required String pin,
    required Future<Uint8List> Function(Uint8List certificate) prepare,
  }) async {
    _prepare = prepare;
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('start', {'pin': pin, 'prepare': true});
      return CieResult.fromMap(m!);
    } on PlatformException catch (e) {
      final details = e.details;
      throw CieError(
        e.code,
        e.message ?? e.code,
        remainingAttempts: details is int ? details : null,
        trace: details is String ? details : null,
      );
    } finally {
      _prepare = null;
    }
  }

  Future<void> cancel() => _channel.invokeMethod('cancel');
}

String hex(List<int> bytes, {String sep = ''}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);
