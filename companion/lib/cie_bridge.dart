import 'package:ciesign_ades/ciesign_ades.dart' show Certificate, DistinguishedName;
import 'package:ciesign_cie/ciesign_cie.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Esito di una sessione con la CIE.
class CieResult {
  CieResult({
    required this.certificate,
    required this.subject,
    required this.issuer,
    required this.serial,
    required this.notBefore,
    required this.notAfter,
    required this.certSha256,
    this.digest,
    this.signature,
    this.signatureValid,
    this.durationMs = 0,
  });

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
  CieBridge({this.onStatus, this.onLink, @visibleForTesting this.caPrivateExponentForTest}) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'status':
          onStatus?.call(call.arguments as String);
        case 'link':
          onLink?.call(call.arguments as String);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('ciesign/cie');

  /// Chiave della CA di una carta simulata, solo per i test.
  final Uint8List? caPrivateExponentForTest;

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
  /// biometria o blocco schermo (vedi [vaultStatus]).
  Future<CieResult> start({String? pin, Uint8List? digest}) {
    if (digest != null && digest.length != 32) {
      throw CieError('BAD_DIGEST', "L'impronta deve essere SHA-256 (32 byte)");
    }
    return _session(pin, (_) async => digest);
  }

  /// Come [start], ma l'impronta da firmare la calcola [prepare] dal certificato
  /// appena letto, nella stessa sessione: la carta si avvicina una volta sola.
  /// Se [prepare] fallisce la sessione si chiude con l'errore `PREPARE_FAILED`,
  /// il cui messaggio è quello dell'eccezione.
  Future<CieResult> startWithPreparation({
    required String? pin,
    required Future<Uint8List> Function(Uint8List certificate) prepare,
  }) =>
      _session(pin, (cert) async {
        _status('Preparazione del documento, non allontanare la carta');
        try {
          return await prepare(cert);
        } on Object catch (e) {
          throw _PrepareFailed('$e');
        }
      });

  /// Sessione con la carta. Il protocollo (canale sicuro, PIN, certificato, firma) è
  /// in Dart nel pacchetto ciesign_cie, uguale su Android e iOS; il codice nativo
  /// attende la carta e scambia i comandi NFC (metodi nfcBegin, transceive, nfcEnd).
  Future<CieResult> _session(String? pin, Future<Uint8List?> Function(Uint8List) digestFor) async {
    final fromVault = pin == null;
    final String thePin;
    try {
      thePin = pin ?? (await _channel.invokeMethod<String>('vaultUnlock'))!;
    } on PlatformException catch (e) {
      throw CieError(e.code, e.message ?? e.code);
    }
    final trace = StringBuffer();
    final watch = Stopwatch();
    var began = false;
    try {
      _status('Avvicina la CIE al retro del telefono e tienila ferma');
      final info = await _channel.invokeMapMethod<String, Object?>('nfcBegin');
      began = true;
      watch.start();
      _status('Carta rilevata, non allontanarla');
      if (info?['trace'] case final String t) trace.write(t);
      final transport = FunctionTransport((apdu) async {
        final Uint8List resp;
        try {
          resp = (await _channel.invokeMethod<Uint8List>('transceive', apdu))!;
        } on PlatformException catch (e) {
          throw _TagLost(e.message ?? e.code);
        }
        // Registro dei comandi: solo intestazione e status word, mai i dati (PIN compreso).
        final lc = apdu.length > 4 ? ' Lc=${apdu[4].toRadixString(16).padLeft(2, '0').toUpperCase()}' : '';
        final sw = resp.length >= 2 ? hex(resp.sublist(resp.length - 2)) : '??';
        trace.writeln('> ${hex(apdu.sublist(0, 4))}$lc  < SW=$sw (${resp.length - 2} byte)');
        return resp;
      });
      final card = CieCard(transport, caPrivateExponent: caPrivateExponentForTest, log: (m) {
        trace.writeln('# $m');
        _status(m);
      });
      final r = await CieSigner.run(card, thePin, digestFor);
      final cert = Certificate.fromDer(r.certificate);
      bool? valid;
      if (r.signature != null) {
        final key = cert.rsaPublicKey;
        valid = CieSigner.verifyPkcs1Sha256(key.modulus, key.exponent, r.digest!, r.signature!);
        trace.writeln(valid ? '# Firma verificata con il certificato' : '# La firma NON corrisponde al certificato');
      }
      await _end(null);
      began = false;
      return CieResult(
        certificate: r.certificate,
        subject: _dn(cert.subject),
        issuer: _dn(cert.issuer),
        serial: cert.serialNumber.toRadixString(16).toUpperCase(),
        notBefore: _date(cert.notBefore),
        notAfter: _date(cert.notAfter),
        certSha256: cert.sha256Fingerprint,
        digest: r.digest,
        signature: r.signature,
        signatureValid: valid,
        durationMs: watch.elapsedMilliseconds,
      );
    } on PlatformException catch (e) {
      throw CieError(e.code, e.message ?? e.code, trace: '$trace');
    } on WrongPinException catch (e) {
      // Un PIN salvato rifiutato non si riprova mai da solo: costerebbe altri tentativi.
      if (fromVault) await _forgetQuietly();
      throw CieError('WRONG_PIN', e.message, remainingAttempts: e.remainingAttempts);
    } on PinBlockedException catch (e) {
      if (fromVault) await _forgetQuietly();
      throw CieError('PIN_BLOCKED', e.message, trace: '$trace');
    } on InvalidPinFormatException catch (e) {
      throw CieError('BAD_PIN', e.message, trace: '$trace');
    } on NotACieException catch (e) {
      throw CieError('NOT_CIE', e.message, trace: '$trace');
    } on _PrepareFailed catch (e) {
      throw CieError('PREPARE_FAILED', e.message);
    } on _TagLost catch (e) {
      throw CieError('TAG_LOST', 'Collegamento con la carta interrotto: tienila ferma e riprova', trace: '$trace${e.message}');
    } on CieException catch (e) {
      throw CieError('CIE_ERROR', e.message, trace: '$trace');
    } on CieError {
      rethrow;
    } on Object catch (e) {
      throw CieError('UNEXPECTED', '$e', trace: '$trace');
    } finally {
      if (began) await _end('Operazione non riuscita');
    }
  }

  Future<void> _end(String? error) async {
    try {
      await _channel.invokeMethod('nfcEnd', {'error': error});
    } on Object {
      // La sessione NFC potrebbe essere già chiusa.
    }
  }

  Future<void> _forgetQuietly() async {
    try {
      await forgetPin();
    } on Object {
      // Se la cancellazione non riesce, al prossimo uso la carta rifiuterà di nuovo il PIN.
    }
  }

  /// Aggiorna lo stato: sull'app e, su iPhone, nel pannello NFC di sistema.
  void _status(String text) {
    onStatus?.call(text);
    _channel.invokeMethod('nfcMessage', text).ignore();
  }

  static String _dn(DistinguishedName dn) => dn.attributes.map((a) => '${_rdn[a.$1] ?? a.$1}=${a.$2}').join(',');

  static const _rdn = {
    '2.5.4.3': 'CN',
    '2.5.4.5': 'SERIALNUMBER',
    '2.5.4.6': 'C',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
    '2.5.4.4': 'SURNAME',
    '2.5.4.42': 'GIVENNAME',
  };

  static String _date(DateTime d) {
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> cancel() => _channel.invokeMethod('cancel');

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

class _PrepareFailed implements Exception {
  _PrepareFailed(this.message);
  final String message;
}

class _TagLost implements Exception {
  _TagLost(this.message);
  final String message;
}
