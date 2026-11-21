# CIE Sign, app companion

App Flutter per lo smartphone. Nel prototipo legge il certificato dalla CIE via NFC e le fa firmare un'impronta SHA-256 di prova. Il dialogo con la carta è nel modulo `../cie-core`, i cui sorgenti sono inclusi nella build Android (vedi `android/app/build.gradle.kts`); il ponte tra Flutter e Android è in `MainActivity.kt` e `lib/cie_bridge.dart`.

```
flutter pub get
flutter test
flutter build apk --debug
```
