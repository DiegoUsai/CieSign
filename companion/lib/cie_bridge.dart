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
  ///
  /// Con [pin] nullo si usa il PIN salvato sul telefono, dopo lo sblocco con
  /// biometria o blocco schermo (vedi [vaultStatus]); il PIN non passa da Flutter.
  Future<CieResult> start({String? pin, Uint8List? digest}) async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('start', {..._pinArgs(pin), 'digest': digest});
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
    required String? pin,
    required Future<Uint8List> Function(Uint8List certificate) prepare,
  }) async {
    _prepare = prepare;
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('start', {..._pinArgs(pin), 'prepare': true});
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

  static Map<String, Object?> _pinArgs(String? pin) => pin == null ? {'savedPin': true} : {'pin': pin};

  /// Stato dello sblocco facoltativo del PIN (UC13). Fuori da Android risulta
  /// non disponibile.
  Future<VaultStatus> vaultStatus() => _vault('vaultStatus');

  /// Attiva o disattiva lo sblocco; disattivandolo il PIN salvato si cancella.
  Future<VaultStatus> setVaultEnabled(bool enabled) => _vault('vaultSetEnabled', {'enabled': enabled});

  /// Cancella il PIN salvato, lasciando la funzione attiva.
  Future<VaultStatus> forgetPin() => _vault('vaultForget');

  /// Salva [pin] dopo lo sblocco con biometria o blocco schermo. Va chiamato solo
  /// dopo che la carta ha accettato quel PIN.
  Future<VaultStatus> savePin(String pin) => _vault('vaultSave', {'pin': pin});

  Future<VaultStatus> _vault(String method, [Map<String, Object?>? args]) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>(method, args);
      return VaultStatus.fromMap(m ?? const {});
    } on MissingPluginException {
      return const VaultStatus.unavailable();
    } on PlatformException catch (e) {
      throw CieError(e.code, e.message ?? e.code);
    }
  }
}

/// Disponibilità dello sblocco del PIN sul telefono.
enum VaultAvailability {
  /// Impronta, volto o blocco schermo configurati e abbastanza sicuri.
  ready,

  /// Il telefono lo permetterebbe, ma non c'è un'impronta o un blocco schermo.
  notEnrolled,

  /// Nessun metodo di sblocco abbastanza sicuro (o piattaforma non supportata).
  unsupported,
}

/// Stato dello sblocco facoltativo del PIN della CIE (UC13, D25).
class VaultStatus {
  const VaultStatus({
    required this.availability,
    required this.enabled,
    required this.saved,
    this.deviceCredential = false,
  });

  const VaultStatus.unavailable()
      : availability = VaultAvailability.unsupported,
        enabled = false,
        saved = false,
        deviceCredential = false;

  factory VaultStatus.fromMap(Map<String, Object?> m) => VaultStatus(
    availability: switch (m['availability']) {
      'ready' => VaultAvailability.ready,
      'not_enrolled' => VaultAvailability.notEnrolled,
      _ => VaultAvailability.unsupported,
    },
    enabled: m['enabled'] == true,
    saved: m['saved'] == true,
    deviceCredential: m['deviceCredential'] == true,
  );

  final VaultAvailability availability;

  /// L'utente ha attivato la funzione nelle impostazioni (spenta in partenza).
  final bool enabled;

  /// C'è un PIN salvato, accettato dalla carta almeno una volta.
  final bool saved;

  /// Oltre alla biometria è ammesso il blocco schermo del telefono (Android 11+).
  final bool deviceCredential;

  /// Si può firmare senza digitare il PIN.
  bool get canUnlock => enabled && saved && availability == VaultAvailability.ready;

  /// Dopo una firma con PIN digitato lo si può salvare.
  bool get canSave => enabled && !saved && availability == VaultAvailability.ready;
}

String hex(List<int> bytes, {String sep = ''}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);
