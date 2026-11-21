# CIE Sign per PC

App **Flutter** per Windows (prima piattaforma), macOS e Linux. Firma documenti con la **CIE** usando lo smartphone abbinato come lettore **NFC**: il PC prepara il documento e manda allo smartphone solo gli attributi da firmare; il PIN si digita sul telefono.

> **Stato: scheletro.** Funzionano apertura e trascinamento dei file, anteprima dei PDF, posizionamento della firma visibile, verifica di integrità delle firme presenti, estrazione del documento dai .p7m, abbinamento con QR code e codice di sei cifre e una **firma di prova** con una chiave inclusa nell'app, che non ha alcun valore legale. La firma con la CIE reale arriverà quando l'app companion parlerà questo protocollo.

## Come provarla

- Scaricare l'artifact `cie-sign-windows` dall'ultima esecuzione del workflow *App desktop* (scheda Actions), estrarre l'archivio e avviare `cie_sign_desktop.exe`; oppure
- con Flutter installato: `cd desktop && flutter run -d windows`.

Si può anche aprire un documento dalla riga di comando: `cie_sign_desktop.exe contratto.pdf`.

Al primo avvio Windows chiede di consentire all'app l'accesso alla rete privata: serve perché lo smartphone si colleghi al PC sulla Wi-Fi di casa.

## Struttura

| Percorso | Contenuto |
|---|---|
| `lib/main.dart` | Finestra principale, apertura e trascinamento dei file |
| `lib/src/document_page.dart` | Anteprima, riquadro della firma visibile, pannello di firma e verifica |
| `lib/src/sign_workflow.dart` | Flusso di firma indipendente dall'interfaccia |
| `lib/src/signers.dart` | Firma tramite smartphone e firma di prova |
| `lib/src/link_service.dart` | Identità del PC, smartphone abbinati, server sulla rete locale |
| `lib/src/pairing_dialog.dart` | Abbinamento con QR code e codice di sei cifre |

Il motore di firma e il protocollo sono pacchetti Dart separati, in `../packages`, così l'app companion può riusarli.

## Test

```
flutter test
```
