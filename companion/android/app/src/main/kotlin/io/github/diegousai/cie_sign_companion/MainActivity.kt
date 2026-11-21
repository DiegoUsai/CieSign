package io.github.diegousai.cie_sign_companion

import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.diegousai.ciesign.cie.ApduTransport
import io.github.diegousai.ciesign.cie.CieException
import io.github.diegousai.ciesign.cie.CieSigner
import io.github.diegousai.ciesign.cie.InvalidPinFormatException
import io.github.diegousai.ciesign.cie.NotACieException
import io.github.diegousai.ciesign.cie.PinBlockedException
import io.github.diegousai.ciesign.cie.WrongPinException
import java.io.IOException
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Attività principale. Espone a Flutter il canale "ciesign/cie" con due metodi:
 * - nfcStatus: indica se l'NFC è presente e attivo;
 * - start: attende la CIE, verifica il PIN, legge il certificato e, se richiesto,
 *   firma l'impronta SHA-256 ricevuta;
 * - cancel: interrompe l'attesa della carta.
 * Durante l'operazione invia a Flutter il metodo "status" con lo stato corrente.
 */
class MainActivity : FlutterActivity() {

    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: PendingRequest? = null

    private class PendingRequest(val pin: CharArray, val digest: ByteArray?, val result: MethodChannel.Result) {
        /** Diventa vero alla prima carta rilevata, per ignorare rilevamenti successivi. */
        val started = java.util.concurrent.atomic.AtomicBoolean(false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ciesign/cie")
        channel.setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "nfcStatus" -> {
                val adapter = NfcAdapter.getDefaultAdapter(this)
                result.success(mapOf("available" to (adapter != null), "enabled" to (adapter?.isEnabled == true)))
            }
            "start" -> start(call, result)
            "cancel" -> {
                stopReader()
                pending?.let { it.pin.fill('0'); it.result.error("CANCELLED", "Operazione annullata", null) }
                pending = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val adapter = NfcAdapter.getDefaultAdapter(this)
        if (adapter == null || !adapter.isEnabled) {
            result.error("NFC_OFF", "NFC assente o disattivato", null)
            return
        }
        if (pending != null) {
            result.error("BUSY", "Un'operazione è già in corso", null)
            return
        }
        val pin = (call.argument<String>("pin") ?: "").toCharArray()
        val digest = call.argument<ByteArray>("digest")
        if (digest != null && digest.size != 32) {
            result.error("BAD_DIGEST", "L'impronta deve essere SHA-256 (32 byte)", null)
            return
        }
        pending = PendingRequest(pin, digest, result)
        status("Avvicina la CIE al retro del telefono e tienila ferma")
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 1000) }
        adapter.enableReaderMode(
            this,
            ::onTag,
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            extras,
        )
    }

    private fun onTag(tag: Tag) {
        val request = pending ?: return
        if (!request.started.compareAndSet(false, true)) return
        worker.execute {
            val isoDep = IsoDep.get(tag)
            if (isoDep == null) {
                finish(request) { it.error("NOT_ISODEP", "La carta non supporta ISO 14443-4", null) }
                return@execute
            }
            val started = System.currentTimeMillis()
            try {
                isoDep.connect()
                isoDep.timeout = 10_000
                status("Carta rilevata, non allontanarla")
                val transport = ApduTransport { apdu -> isoDep.transceive(apdu) }
                val session = CieSigner.run(transport, request.pin, request.digest) { status(it) }
                val cert = CieSigner.parseCertificate(session.certificate)
                val fmt = SimpleDateFormat("dd/MM/yyyy HH:mm", Locale.ITALY)
                val payload = mapOf(
                    "certificate" to session.certificate,
                    "subject" to cert.subjectX500Principal.name,
                    "issuer" to cert.issuerX500Principal.name,
                    "serial" to cert.serialNumber.toString(16).uppercase(),
                    "notBefore" to fmt.format(cert.notBefore),
                    "notAfter" to fmt.format(cert.notAfter),
                    "certSha256" to MessageDigest.getInstance("SHA-256").digest(session.certificate),
                    "digest" to session.digest,
                    "signature" to session.signature,
                    "signatureValid" to session.signatureValid,
                    "durationMs" to (System.currentTimeMillis() - started).toInt(),
                )
                finish(request) { it.success(payload) }
            } catch (e: WrongPinException) {
                finish(request) { it.error("WRONG_PIN", e.message, e.remainingAttempts) }
            } catch (e: PinBlockedException) {
                finish(request) { it.error("PIN_BLOCKED", e.message, null) }
            } catch (e: InvalidPinFormatException) {
                finish(request) { it.error("BAD_PIN", e.message, null) }
            } catch (e: NotACieException) {
                finish(request) { it.error("NOT_CIE", e.message, null) }
            } catch (e: IOException) {
                finish(request) { it.error("TAG_LOST", "Collegamento con la carta interrotto: tienila ferma e riprova", e.message) }
            } catch (e: CieException) {
                finish(request) { it.error("CIE_ERROR", e.message, null) }
            } catch (e: Exception) {
                finish(request) { it.error("UNEXPECTED", e.toString(), null) }
            } finally {
                try { isoDep.close() } catch (_: IOException) { }
            }
        }
    }

    private fun finish(request: PendingRequest, reply: (MethodChannel.Result) -> Unit) {
        request.pin.fill('0')
        main.post {
            // Se nel frattempo l'operazione è stata annullata, la risposta è già stata data.
            if (pending !== request) return@post
            stopReader()
            pending = null
            reply(request.result)
        }
    }

    private fun stopReader() {
        NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
    }

    private fun status(text: String) {
        main.post { channel.invokeMethod("status", text) }
    }

    override fun onPause() {
        super.onPause()
        // La modalità lettore è legata all'attività in primo piano: in pausa si annulla.
        if (pending != null) {
            stopReader()
            pending?.let { it.pin.fill('0'); it.result.error("CANCELLED", "App in secondo piano, operazione annullata", null) }
            pending = null
        }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}
