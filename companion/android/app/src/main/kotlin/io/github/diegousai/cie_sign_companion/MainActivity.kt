package io.github.diegousai.cie_sign_companion

import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Attività principale. Espone a Flutter il canale "ciesign/cie" con questi metodi:
 * - nfcStatus: indica se l'NFC è presente e attivo;
 * - start: attende la CIE, verifica il PIN, legge il certificato e, se richiesto,
 *   firma l'impronta SHA-256 ricevuta; con prepare=true l'impronta la calcola
 *   Flutter (metodo "prepare") dal certificato appena letto, nella stessa sessione;
 * - cancel: interrompe l'attesa della carta;
 * - initialLink: collegamento ciesign://pair?... con cui l'app è stata aperta;
 * - deviceName: produttore e modello del telefono, mostrati sul PC.
 * Durante l'operazione invia a Flutter il metodo "status" con lo stato corrente,
 * e il metodo "link" quando un QR code di abbinamento apre l'app già avviata.
 */
class MainActivity : FlutterActivity() {

    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: PendingRequest? = null
    private var initialLink: String? = null

    private class PendingRequest(
        val pin: CharArray,
        val digest: ByteArray?,
        val prepare: Boolean,
        val result: MethodChannel.Result,
    ) {
        /** Diventa vero alla prima carta rilevata, per ignorare rilevamenti successivi. */
        val started = java.util.concurrent.atomic.AtomicBoolean(false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ciesign/cie")
        channel.setMethodCallHandler(::onMethodCall)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialLink = pairingLink(intent)
        requestLocalNetworkPermission()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pairingLink(intent)?.let { channel.invokeMethod("link", it) }
    }

    /** Collegamento ciesign://pair?... aperto, per esempio, dalla fotocamera del telefono. */
    private fun pairingLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return if (intent.action == Intent.ACTION_VIEW && data.scheme == "ciesign" && data.host == "pair") data.toString() else null
    }

    /**
     * Dalle versioni più recenti di Android l'accesso ai dispositivi della rete locale
     * richiede un permesso a runtime. Sulle versioni che non lo prevedono la richiesta
     * è ignorata.
     */
    private fun requestLocalNetworkPermission() {
        if (Build.VERSION.SDK_INT < 36) return
        if (checkSelfPermission(LOCAL_NETWORK) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(LOCAL_NETWORK), 1)
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "nfcStatus" -> {
                val adapter = NfcAdapter.getDefaultAdapter(this)
                result.success(mapOf("available" to (adapter != null), "enabled" to (adapter?.isEnabled == true)))
            }
            "start" -> start(call, result)
            "initialLink" -> {
                result.success(initialLink)
                initialLink = null
            }
            "deviceName" -> {
                val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                val model = Build.MODEL
                result.success(if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model")
            }
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
        val prepare = call.argument<Boolean>("prepare") == true
        pending = PendingRequest(pin, digest, prepare, result)
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
            val trace = StringBuilder()
            try {
                isoDep.connect()
                isoDep.timeout = 10_000
                status("Carta rilevata, non allontanarla")
                trace.append("Tecnologie: ").append(tag.techList.joinToString { it.substringAfterLast('.') }).append('\n')
                isoDep.historicalBytes?.let { trace.append("Historical bytes (NFC-A): ").append(hex(it)).append('\n') }
                isoDep.hiLayerResponse?.let { trace.append("Higher layer response (NFC-B): ").append(hex(it)).append('\n') }
                // Registro dei comandi: solo intestazione e status word, mai i dati (PIN compreso).
                val transport = ApduTransport { apdu ->
                    val resp = isoDep.transceive(apdu)
                    val lc = if (apdu.size > 4) " Lc=%02X".format(apdu[4].toInt() and 0xFF) else ""
                    val sw = if (resp.size >= 2) hex(resp.copyOfRange(resp.size - 2, resp.size)) else "??"
                    trace.append("> ").append(hex(apdu.copyOfRange(0, 4))).append(lc)
                        .append("  < SW=").append(sw).append(" (").append(resp.size - 2).append(" byte)\n")
                    resp
                }
                val log: (String) -> Unit = { trace.append("# ").append(it).append('\n'); status(it) }
                val session = if (request.prepare) {
                    CieSigner.runWithCertificate(transport, request.pin, { cert -> askDigest(request, cert) }, log)
                } else {
                    CieSigner.run(transport, request.pin, request.digest, log)
                }
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
                finish(request) { it.error("PIN_BLOCKED", e.message, trace.toString()) }
            } catch (e: InvalidPinFormatException) {
                finish(request) { it.error("BAD_PIN", e.message, trace.toString()) }
            } catch (e: NotACieException) {
                finish(request) { it.error("NOT_CIE", e.message, trace.toString()) }
            } catch (e: PrepareException) {
                finish(request) { it.error("PREPARE_FAILED", e.message, null) }
            } catch (e: IOException) {
                finish(request) { it.error("TAG_LOST", "Collegamento con la carta interrotto: tienila ferma e riprova", "$trace${e.message}") }
            } catch (e: CieException) {
                finish(request) { it.error("CIE_ERROR", e.message, trace.toString()) }
            } catch (e: Exception) {
                finish(request) { it.error("UNEXPECTED", e.toString(), trace.toString()) }
            } finally {
                try { isoDep.close() } catch (_: IOException) { }
            }
        }
    }

    private class PrepareException(message: String) : Exception(message)

    /**
     * Chiede a Flutter l'impronta da firmare per il certificato appena letto, mentre la
     * carta resta nel campo NFC. Gira sul thread del lettore, quindi può attendere.
     */
    private fun askDigest(request: PendingRequest, cert: ByteArray): ByteArray {
        val latch = CountDownLatch(1)
        var digest: ByteArray? = null
        var error: String? = null
        status("Preparazione del documento, non allontanare la carta")
        main.post {
            if (pending !== request) {
                error = "Operazione annullata"
                latch.countDown()
                return@post
            }
            channel.invokeMethod("prepare", cert, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    digest = result as? ByteArray
                    latch.countDown()
                }

                override fun error(code: String, message: String?, details: Any?) {
                    error = message ?: code
                    latch.countDown()
                }

                override fun notImplemented() {
                    error = "Preparazione non disponibile"
                    latch.countDown()
                }
            })
        }
        if (!latch.await(60, TimeUnit.SECONDS)) throw PrepareException("Preparazione del documento troppo lenta")
        error?.let { throw PrepareException(it) }
        val d = digest ?: throw PrepareException("Impronta non ricevuta")
        if (d.size != 32) throw PrepareException("L'impronta deve essere SHA-256 (32 byte)")
        return d
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

    private fun hex(b: ByteArray) = b.joinToString("") { "%02X".format(it.toInt() and 0xFF) }

    override fun onPause() {
        super.onPause()
        // La modalità lettore è legata all'attività in primo piano: in pausa si annulla.
        if (pending != null) {
            stopReader()
            pending?.let { it.pin.fill('0'); it.result.error("CANCELLED", "App in secondo piano, operazione annullata", null) }
            pending = null
        }
    }

    private companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}
