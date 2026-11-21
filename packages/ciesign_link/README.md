# ciesign_link

Protocollo di CIE Sign tra PC e smartphone, versione 1 (bozza). Pacchetto **Dart** puro, usato sia dall'app desktop sia dall'app companion.

- **Abbinamento**: il PC mostra un QR code `ciesign://pair?...` con la propria chiave pubblica, un segreto monouso e i propri indirizzi sulla rete locale; lo smartphone si collega, dimostra di aver letto il QR code e i due dispositivi mostrano lo stesso codice di sei cifre, che l'utente conferma su entrambi.
- **Riconnessione**: chiavi statiche **X25519** scambiate all'abbinamento più chiavi effimere a ogni collegamento, sul modello di Noise KK.
- **Canale cifrato**: ChaCha20-Poly1305, una chiave per direzione, contatore come nonce.
- **Trasporto**: frame preceduti dalla lunghezza su 4 byte; oggi TCP sulla Wi-Fi di casa (porta 47321, servizio mDNS `_ciesign._tcp`), in seguito Bluetooth Low Energy con lo stesso formato.
- **Messaggi**: richiesta del certificato, richiesta di firma con gli attributi firmati (lo smartphone ne calcola l'impronta e controlla l'impronta del documento), risposta, rifiuto, errore della carta, scaricamento del documento a blocchi.

## Test

```
dart test
```

Il test principale fa l'intero giro su 127.0.0.1: abbinamento, riconnessione, certificato e firma CAdES con una carta simulata.
