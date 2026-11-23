# Signaling su Cloudflare

Worker con **Durable Objects** che espone lo stesso sottoinsieme dell'API REST del Firebase Realtime Database usato dalle app (GET, PUT, DELETE su percorsi `.json` e ascolto con `text/event-stream`), più `/v1/ice.json` con credenziali **TURN** temporanee di Cloudflare. Per passare da Firebase a qui basta cambiare l'indirizzo.

## Pubblicazione

```
npm ci
npx wrangler login
npx wrangler deploy
# facoltativo, per il TURN (Realtime, TURN keys nella dashboard di Cloudflare)
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

Poi nel repository CieSign imposta la variabile `CIESIGN_SIGNALING_URL` all'indirizzo del Worker e cancella `CIESIGN_FIREBASE_API_KEY`.

## Collaudo in locale

```
npx wrangler dev --port 8787 --ip 127.0.0.1
cd ../../packages/ciesign_link
CIESIGN_TEST_SIGNALING_URL=http://127.0.0.1:8787 dart test -t servizio
```

Fonti: [Durable Objects](https://developers.cloudflare.com/durable-objects/), [credenziali TURN](https://developers.cloudflare.com/realtime/turn/generate-credentials/), [REST API del Realtime Database](https://firebase.google.com/docs/reference/rest/database/).
