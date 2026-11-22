import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Canale "ciesign/cie": lettore NFC della CIE e custodia del PIN (vedi CieNfc.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CieNfc") {
      CieNfc.shared = CieNfc(messenger: registrar.messenger())
    }
  }
}
