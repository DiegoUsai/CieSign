# Signaling su Firebase

Servizio di **signaling** del collegamento via internet di CIE Sign, sul **Firebase Realtime Database** con accesso anonimo. Le app scambiano qui solo offerta e risposta **WebRTC**, cifrate; il documento e la firma viaggiano poi sul collegamento diretto, cifrato da un capo all'altro.

## Creazione del progetto

1. Crea un progetto su [console.firebase.google.com](https://console.firebase.google.com) (piano gratuito Spark, Analytics non serve).
2. **Authentication**, Metodi di accesso: attiva **Anonimo**.
3. **Realtime Database**: crea il database in `europe-west1`, in modalità bloccata.
4. Nella scheda Regole incolla il contenuto di [database.rules.json](database.rules.json) e pubblica.
5. Annota l'URL del database (`https://<progetto>-default-rtdb.europe-west1.firebasedatabase.app`) e la **Web API key** (Impostazioni progetto, Generali).

## Collegamento alle build

Nel repository CieSign, Settings, Secrets and variables, Actions, scheda Variables, crea:

| Variabile | Valore |
|---|---|
| `CIESIGN_SIGNALING_URL` | URL del Realtime Database |
| `CIESIGN_FIREBASE_API_KEY` | Web API key |

I workflow *App desktop* e *Prototipo Android* le passano alle app con `--dart-define`. Senza variabili le app funzionano solo sulla rete locale. In locale: `flutter run --dart-define=CIESIGN_SIGNALING_URL=... --dart-define=CIESIGN_FIREBASE_API_KEY=...`.

Facoltativo: un server **TURN** fisso si può pubblicare nel nodo `/v1/ice` del database, nella forma `{"iceServers": [{"urls": ["turn:..."], "username": "...", "credential": "..."}]}`.

## Collaudo con gli emulatori

```
npm i -g firebase-tools
firebase emulators:exec --only auth,database --project demo-ciesign \
  "cd ../../packages/ciesign_link && dart test -t servizio"
```

## Passaggio a Cloudflare

Il Worker in [../signaling-worker](../signaling-worker) espone la stessa API: basta cambiare `CIESIGN_SIGNALING_URL` e cancellare `CIESIGN_FIREBASE_API_KEY`.
