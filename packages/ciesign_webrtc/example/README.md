# Prova del collegamento WebRTC

App vuota per il test di integrazione `integration_test/webrtc_test.dart`: due peer WebRTC veri nello stesso processo, stretta di mano di ciesign_link sopra il data channel e un frame da 200 KB; con le variabili del signaling anche l'abbinamento completo attraverso il servizio.

```
flutter test integration_test/webrtc_test.dart -d linux
```

Su un Linux senza scheda audio serve PulseAudio con un'uscita finta (`pactl load-module module-null-sink`), perché libwebrtc inizializza comunque il modulo audio.
