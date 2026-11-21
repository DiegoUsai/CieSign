# CIE Sign

Applicazione **open source** per firmare documenti dal PC con la **CIE** (Carta d'Identità Elettronica) italiana, usando lo smartphone come lettore **NFC**.

> **Stato: prototipo.** Il codice serve a collaudare la lettura e la firma con la CIE; non è ancora pronto per l'uso quotidiano.

## Struttura del repository

| Cartella | Contenuto |
|---|---|
| `cie-core/` | Modulo in **Kotlin** puro che dialoga con la CIE: **secure messaging**, verifica del **PIN**, lettura del certificato, firma di un'impronta **SHA-256**. Ha test automatici su una carta simulata. |
| `companion/` | App **Flutter** per lo smartphone. Oggi solo Android: legge il certificato dalla CIE e le fa firmare un'impronta di prova, verificandola subito con il certificato. |

## Prototipo Android

Requisiti: smartphone Android 6.0 o successivo con NFC, CIE 3.0 e relativo PIN di 8 cifre.

1. Scaricare l'APK di prova dagli **artifact** dell'ultima esecuzione del workflow *Prototipo Android* (scheda Actions), oppure costruirlo con `cd companion && flutter build apk --debug`.
2. Installarlo sul telefono e attivare l'NFC.
3. Inserire il PIN, scegliere se firmare anche un testo di prova e premere il pulsante; poi appoggiare la CIE al retro del telefono e tenerla ferma per qualche secondo.

Il PIN resta sul telefono: non viene salvato né trasmesso. Dopo un PIN errato l'app lo cancella, così ogni tentativo è voluto; con 3 errori consecutivi la carta si blocca e serve il PUK.

### Verificare la firma sul PC

Il pulsante *Copia il risultato per il PC* copia un JSON con certificato, impronta e firma. Salvati i valori in `cert.der`, `impronta.bin` e `firma.bin` (decodificando il Base64 e l'esadecimale), la firma si verifica con OpenSSL:

```
openssl x509 -inform der -in cert.der -pubkey -noout > pub.pem
openssl pkeyutl -verify -pubin -inkey pub.pem -in impronta.bin -sigfile firma.bin -pkeyopt digest:sha256
```

## Test

```
cd cie-core && gradle test        # modulo CIE sulla JVM
cd companion && flutter test      # interfaccia Flutter
```

## Licenza

[MIT](LICENSE). Il modulo `cie-core` deriva in parte dall'SDK CieID dell'IPZS, con licenza BSD-3-Clause: vedi [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
