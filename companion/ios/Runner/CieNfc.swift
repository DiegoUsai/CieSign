import CoreNFC
import Flutter
import LocalAuthentication
import Security
import UIKit

/// Parte nativa iOS del canale "ciesign/cie", gemella di MainActivity.kt su Android.
///
/// Il dialogo con la CIE (canale sicuro, PIN, certificato, firma) è in Dart nel pacchetto
/// ciesign_cie, uguale sulle due piattaforme: qui restano solo il lettore NFC (CoreNFC,
/// tag ISO 7816), la custodia facoltativa del PIN (Portachiavi con Face ID o Touch ID) e
/// le informazioni sul dispositivo.
final class CieNfc: NSObject, NFCTagReaderSessionDelegate {
  static var shared: CieNfc?

  private let channel: FlutterMethodChannel
  private var session: NFCTagReaderSession?
  private var tag: NFCISO7816Tag?
  private var waiting: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ciesign/cie", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  /// Collegamento ciesign://pair?... aperto dalla fotocamera o da un'altra app.
  func open(url: URL) {
    guard url.scheme == "ciesign", url.host == "pair" else { return }
    channel.invokeMethod("link", arguments: url.absoluteString)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "nfcStatus":
      let ok = NFCTagReaderSession.readingAvailable
      result(["available": ok, "enabled": ok])
    case "nfcBegin": begin(result)
    case "transceive": transceive(call.arguments as? FlutterStandardTypedData, result)
    case "nfcEnd":
      let error = (call.arguments as? [String: Any])?["error"] as? String
      end(error: error)
      result(nil)
    case "nfcMessage":
      if let text = call.arguments as? String { session?.alertMessage = text }
      result(nil)
    case "cancel":
      fail("CANCELLED", "Operazione annullata")
      end(error: nil)
      result(nil)
    case "initialLink":
      if let url = SceneDelegate.launchURL, url.scheme == "ciesign", url.host == "pair" {
        result(url.absoluteString)
      } else {
        result(nil)
      }
      SceneDelegate.launchURL = nil
    case "deviceName":
      result(UIDevice.current.name.isEmpty ? UIDevice.current.model : UIDevice.current.name)
    case "vaultStatus": result(PinVault.status())
    case "vaultSetEnabled":
      PinVault.setEnabled((call.arguments as? [String: Any])?["enabled"] as? Bool ?? false)
      result(PinVault.status())
    case "vaultForget":
      PinVault.forget()
      result(PinVault.status())
    case "vaultSave":
      let pin = (call.arguments as? [String: Any])?["pin"] as? String ?? ""
      PinVault.save(pin) { error in
        DispatchQueue.main.async {
          if let e = error { result(FlutterError(code: e.code, message: e.message, details: nil)) } else { result(PinVault.status()) }
        }
      }
    case "vaultUnlock":
      PinVault.unlock { pin, error in
        DispatchQueue.main.async {
          if let e = error { result(FlutterError(code: e.code, message: e.message, details: nil)) } else { result(pin) }
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Lettore NFC

  private func begin(_ result: @escaping FlutterResult) {
    guard NFCTagReaderSession.readingAvailable else {
      result(FlutterError(code: "NFC_OFF", message: "NFC non disponibile su questo iPhone", details: nil))
      return
    }
    guard waiting == nil, session == nil else {
      result(FlutterError(code: "BUSY", message: "Un'operazione è già in corso", details: nil))
      return
    }
    waiting = result
    session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: .main)
    session?.alertMessage = "Avvicina la CIE alla parte alta del retro dell'iPhone e tienila ferma"
    session?.begin()
  }

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    let code = (error as? NFCReaderError)?.code
    if code == .readerSessionInvalidationErrorUserCanceled {
      fail("CANCELLED", "Operazione annullata")
    } else if code == .readerSessionInvalidationErrorSessionTimeout {
      fail("CANCELLED", "Tempo scaduto: nessuna carta rilevata")
    } else {
      fail("TAG_LOST", error.localizedDescription)
    }
    self.session = nil
    tag = nil
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let first = tags.first, case let .iso7816(iso) = first else {
      session.invalidate(errorMessage: "Questa non sembra una CIE")
      fail("NOT_ISODEP", "La carta non supporta ISO 7816")
      return
    }
    session.connect(to: first) { [weak self] error in
      guard let self else { return }
      if let error {
        session.invalidate(errorMessage: "Collegamento con la carta non riuscito")
        self.fail("TAG_LOST", error.localizedDescription)
        return
      }
      self.tag = iso
      var trace = "Tecnologie: ISO7816 (CoreNFC)\n"
      if let h = iso.historicalBytes { trace += "Historical bytes (NFC-A): \(h.hex)\n" }
      if let a = iso.applicationData { trace += "Higher layer response (NFC-B): \(a.hex)\n" }
      trace += "AID selezionato all'avvio: \(iso.initialSelectedAID)\n"
      session.alertMessage = "Carta rilevata, non allontanarla"
      self.waiting?(["trace": trace])
      self.waiting = nil
    }
  }

  private func transceive(_ data: FlutterStandardTypedData?, _ result: @escaping FlutterResult) {
    guard let tag, let data, let apdu = NFCISO7816APDU(data: data.data) else {
      result(FlutterError(code: "TAG_LOST", message: "Nessuna carta collegata", details: nil))
      return
    }
    tag.sendCommand(apdu: apdu) { response, sw1, sw2, error in
      if let error {
        result(FlutterError(code: "TAG_LOST", message: error.localizedDescription, details: nil))
        return
      }
      var out = response
      out.append(sw1)
      out.append(sw2)
      result(FlutterStandardTypedData(bytes: out))
    }
  }

  private func end(error: String?) {
    if let error { session?.invalidate(errorMessage: error) } else {
      session?.alertMessage = "Fatto"
      session?.invalidate()
    }
    session = nil
    tag = nil
  }

  private func fail(_ code: String, _ message: String) {
    waiting?(FlutterError(code: code, message: message, details: nil))
    waiting = nil
  }
}

private extension Data {
  var hex: String { map { String(format: "%02X", $0) }.joined() }
}

/// Custodia facoltativa del PIN (UC13, D25): il PIN è nel Portachiavi, solo su questo
/// iPhone, leggibile solo dopo Face ID o Touch ID e cancellato se cambiano i volti o le
/// impronte registrate (biometryCurrentSet). Spenta in partenza.
enum PinVault {
  struct VaultError { let code: String; let message: String }

  private static let account = "cie-pin"
  private static let service = "io.github.diegousai.ciesign.pin"
  private static let enabledKey = "pinVaultEnabled"
  private static let savedKey = "pinVaultSaved"

  static func availability() -> String {
    let ctx = LAContext()
    var error: NSError?
    if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return "ready" }
    if let e = error as? LAError, e.code == .biometryNotEnrolled || e.code == .passcodeNotSet { return "not_enrolled" }
    return "unsupported"
  }

  static func status() -> [String: Any] {
    if UserDefaults.standard.bool(forKey: savedKey) && !exists() { UserDefaults.standard.set(false, forKey: savedKey) }
    return [
      "availability": availability(),
      "enabled": UserDefaults.standard.bool(forKey: enabledKey),
      "saved": UserDefaults.standard.bool(forKey: savedKey),
      "deviceCredential": false,
    ]
  }

  static func setEnabled(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: enabledKey)
    if !on { forget() }
  }

  static func forget() {
    SecItemDelete(baseQuery() as CFDictionary)
    UserDefaults.standard.set(false, forKey: savedKey)
  }

  static func save(_ pin: String, done: @escaping (VaultError?) -> Void) {
    guard pin.count == 8, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return done(VaultError(code: "BAD_PIN", message: "Il PIN della CIE è di 8 cifre"))
    }
    guard UserDefaults.standard.bool(forKey: enabledKey) else {
      return done(VaultError(code: "VAULT_DISABLED", message: "Sblocco biometrico non attivo"))
    }
    var err: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &err)
    else { return done(VaultError(code: "VAULT_ERROR", message: "Impossibile preparare la protezione")) }
    // Conferma con Face ID o Touch ID prima di salvare, come su Android.
    let ctx = LAContext()
    ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Conferma per ricordare il PIN della CIE") { ok, e in
      guard ok else { return done(mapLA(e)) }
      SecItemDelete(baseQuery() as CFDictionary)
      var add = baseQuery()
      add[kSecValueData as String] = Data(pin.utf8)
      add[kSecAttrAccessControl as String] = access
      add[kSecUseAuthenticationContext as String] = ctx
      let status = SecItemAdd(add as CFDictionary, nil)
      if status == errSecSuccess {
        UserDefaults.standard.set(true, forKey: savedKey)
        done(nil)
      } else {
        done(VaultError(code: "VAULT_ERROR", message: "Salvataggio non riuscito (\(status))"))
      }
    }
  }

  static func unlock(done: @escaping (String?, VaultError?) -> Void) {
    guard UserDefaults.standard.bool(forKey: enabledKey) else {
      return done(nil, VaultError(code: "VAULT_DISABLED", message: "Sblocco biometrico non attivo"))
    }
    guard UserDefaults.standard.bool(forKey: savedKey) else {
      return done(nil, VaultError(code: "VAULT_EMPTY", message: "Nessun PIN salvato sul telefono"))
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var query = baseQuery()
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      let ctx = LAContext()
      ctx.localizedReason = "Sblocca il PIN della CIE per firmare"
      query[kSecUseAuthenticationContext as String] = ctx
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      switch status {
      case errSecSuccess:
        guard let data = item as? Data, let pin = String(data: data, encoding: .utf8) else {
          forget()
          return done(nil, VaultError(code: "VAULT_INVALIDATED", message: "PIN salvato non leggibile"))
        }
        done(pin, nil)
      case errSecUserCanceled:
        done(nil, VaultError(code: "VAULT_CANCELLED", message: "Sblocco annullato"))
      case errSecItemNotFound:
        // Con biometryCurrentSet l'elemento sparisce se cambiano volti o impronte.
        forget()
        done(nil, VaultError(code: "VAULT_INVALIDATED", message: "Volti o impronte registrati sono cambiati"))
      case errSecAuthFailed:
        done(nil, VaultError(code: "VAULT_LOCKOUT", message: "Sblocco non riuscito"))
      default:
        done(nil, VaultError(code: "VAULT_ERROR", message: "Lettura non riuscita (\(status))"))
      }
    }
  }

  private static func exists() -> Bool {
    var query = baseQuery()
    let ctx = LAContext()
    ctx.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = ctx
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  private static func baseQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  private static func mapLA(_ e: Error?) -> VaultError {
    switch (e as? LAError)?.code {
    case .userCancel, .appCancel, .systemCancel, .userFallback:
      return VaultError(code: "VAULT_CANCELLED", message: "Sblocco annullato")
    case .biometryLockout:
      return VaultError(code: "VAULT_LOCKOUT", message: "Troppi tentativi")
    default:
      return VaultError(code: "VAULT_ERROR", message: e?.localizedDescription ?? "Sblocco non riuscito")
    }
  }
}
