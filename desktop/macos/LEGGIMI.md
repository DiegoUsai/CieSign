# CIE Sign per Mac: come provarlo

**CIE Sign** firma i documenti dal Mac con la **CIE** (Carta d'Identità Elettronica), usando uno smartphone Android come lettore **NFC**. È un **prototipo** di prova: le firme servono a collaudare il programma e non vanno usate per documenti importanti.

## Cosa serve

- Un Mac con macOS 12 (Monterey) o successivo, con processore Apple (M1 e seguenti) oppure Intel.
- Uno smartphone Android 6.0 o successivo con **NFC**, su cui installare l'app CIE Sign per telefono (file **APK** che ti manda chi ti ha dato questo programma).
- La CIE 3.0 e il suo **PIN** di 8 cifre (le prime 4 cifre arrivano con la ricevuta della carta, le ultime 4 con la lettera a casa).
- Mac e telefono collegati alla **stessa rete Wi-Fi**.

## Installazione

1. Apri il file `cie-sign-macos-….dmg`.
2. Trascina **CIE Sign** sulla cartella **Applicazioni**.
3. Espelli il disco "CIE Sign".

## Primo avvio

L'app non è ancora autenticata da Apple (manca la firma con un Apple Developer ID), quindi al primo avvio macOS la blocca. Si sblocca una sola volta così.

**macOS 15 Sequoia e successivi**

1. Fai doppio clic su CIE Sign in Applicazioni: compare l'avviso che l'app non può essere aperta. Premi **Fine** (non "Sposta nel Cestino").
2. Apri **Impostazioni di Sistema → Privacy e sicurezza** e scorri fino alla sezione **Sicurezza**.
3. Accanto a "CIE Sign è stato bloccato…" premi **Apri comunque** e conferma con la password del Mac.

**macOS 12, 13 e 14**

1. In Applicazioni fai clic con il tasto destro (oppure Ctrl + clic) su CIE Sign e scegli **Apri**.
2. Nella finestra che compare premi di nuovo **Apri**.

**Se macOS dice che l'app "è danneggiata"**, apri il **Terminale** e incolla questo comando, poi riprova ad aprirla:

```
xattr -dr com.apple.quarantine "/Applications/CIE Sign.app"
```

## Permessi che l'app chiede

- **Rete locale** ("CIE Sign vuole trovare dispositivi sulla rete locale"): premi **Consenti**. Serve perché il telefono trovi il Mac sulla Wi-Fi. Se l'hai negato per sbaglio, riattivalo in Impostazioni di Sistema → Privacy e sicurezza → Rete locale.
- **Connessioni in entrata**, solo se hai il firewall del Mac attivo: premi **Consenti**.
- **Portachiavi** ("CIE Sign vuole usare le informazioni salvate nel portachiavi"): inserisci la password del Mac e premi **Consenti sempre**. Nel Portachiavi l'app conserva la chiave che la lega al telefono abbinato.

## Abbinare il telefono

1. Installa l'APK sul telefono e attiva l'NFC.
2. Sul Mac, in CIE Sign, premi **Abbina smartphone**: compare un **QR code**.
3. Sul telefono apri CIE Sign, scegli **Abbina PC** e inquadra il codice.
4. Controlla che il **codice di 6 cifre** sia uguale sul Mac e sul telefono, premi **Coincide** sul Mac e conferma sul telefono.

L'abbinamento si fa una volta sola: le volte successive il telefono ritrova il Mac da solo, anche se cambia indirizzo sulla rete.

## Firmare un documento

1. Trascina un PDF (o un altro file) nella finestra di CIE Sign, oppure premi **Apri documento**.
2. Scegli il formato: **PAdES** per i PDF, **CAdES (.p7m)** per qualsiasi file. Per un PDF puoi attivare **Firma visibile** e scegliere dove metterla: il riquadro si sposta e si ridimensiona.
3. Come modo di firma lascia **CIE tramite smartphone** e avvia la firma: sul telefono compare la richiesta. Inserisci il PIN della CIE e appoggia la carta al retro del telefono, tenendola ferma per qualche secondo.
4. Sul Mac scegli dove salvare il file firmato.

Il PIN si digita solo sul telefono, non viene salvato né trasmesso, e il Mac manda al telefono solo i dati da firmare, non il documento. Attenzione: con 3 PIN sbagliati di fila la CIE si blocca e serve il PUK.

## Se qualcosa non va

- **Il telefono non trova il Mac**: controlla che siano sulla stessa Wi-Fi (non sulla rete "ospiti", che spesso isola i dispositivi) e che il permesso Rete locale sia attivo.
- **Verificare un file firmato**: nella schermata iniziale premi **Verifica un file firmato**.
- **Disinstallare**: trascina CIE Sign nel Cestino; i dati dell'app stanno in `~/Library/Application Support/io.github.diegousai.cieSignDesktop`.

Segnala ogni problema a chi ti ha mandato il programma, possibilmente con una schermata.
