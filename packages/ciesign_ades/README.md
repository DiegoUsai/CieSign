# ciesign_ades

Motore di firma di CIE Sign in **Dart** puro, senza dipendenze native.

- **PAdES** di livello B-B (`ETSI.CAdES.detached`) con aggiornamento incrementale del PDF, firma visibile o invisibile, PDF con tabella xref classica o compressa (xref stream e object stream).
- **CAdES** di livello B-B, imbustata (.p7m) o staccata.
- Verifica di integrità delle firme PAdES e CAdES, lettura di .p7m in DER, BER o Base64, estrazione del documento (**sbustamento**).

La firma avviene in due tempi, perché la chiave privata resta nella CIE: `prepare` produce gli attributi firmati e l'impronta da far firmare alla carta, `finish` inserisce la firma ricevuta dopo averla verificata con il certificato.

```dart
final prep = PadesPreparation.prepare(pdf, certificato,
    visible: const VisibleSignature(pageIndex: 0, x: 72, y: 60, width: 200, height: 64));
// prep.signedAttributes va allo smartphone, che fa firmare sha256(signedAttributes) alla CIE
final firmato = prep.finish(firmaDellaCarta);
```

## Conformità

I test producono file firmati in `build/test-output`, che il workflow *App desktop* valida con **EU DSS** ([tools/dss-validator](../../tools/dss-validator)): devono risultare PAdES-BASELINE-B e CAdES-BASELINE-B con esito TOTAL_PASSED.

Limiti noti: PDF cifrati non supportati; pagine ruotate non gestite nel posizionamento della firma visibile; nessuna marca temporale (prevista dopo la beta); verifica senza controllo della catena e della revoca.
