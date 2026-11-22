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
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Attività principale. Il dialogo con la CIE (canale sicuro, PIN, certificato, firma) è
 * in Dart nel pacchetto ciesign_cie, uguale su Android e iOS: qui resta solo il lettore NFC.
 * Metodi del canale "ciesign/cie":
 * - nfcStatus: indica se l'NFC è presente e attivo;
 * - nfcBegin: attende la carta in modalità lettore e la collega (IsoDep);
 * - transceive: invia un comando APDU alla carta e ne restituisce la risposta;
 * - nfcEnd: chiude il collegamento con la carta e la modalità lettore;
 * - nfcMessage: testo per il pannello NFC di iOS, qui ignorato (lo stato lo mostra Flutter);
 * - cancel: interrompe l'attesa della carta;
 * - initialLink: collegamento ciesign://pair?... con cui l'app è stata aperta;
 * - deviceName: produttore e modello del telefono, mostrati sul PC;
 * - vaultStatus, vaultSetEnabled, vaultSave, vaultForget, vaultUnlock: sblocco facoltativo
 *   del PIN con biometria o blocco schermo (vedi [PinVault]).
 * Invia a Flutter il metodo "link" quando un QR code di abbinamento apre l'app già avviata.
 */
// FlutterFragmentActivity perché BiometricPrompt richiede una FragmentActivity.
class MainActivity : FlutterFragmentActivity() {

    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var initialLink: String? = null
    private val vault by lazy { PinVault(this) }

    /** Attesa della carta in corso (risposta a nfcBegin non ancora data). */
    private var waiting: MethodChannel.Result? = null

    /** Attesa rimandata finché l'attività non torna in primo piano (dopo lo sblocco del PIN). */
    private var deferred: MethodChannel.Result? = null

    /** Carta collegata, usata da transceive fino a nfcEnd. */
    @Volatile private var isoDep: IsoDep? = null

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
            "nfcBegin" -> begin(result)
            "transceive" -> transceive(call.arguments as ByteArray, result)
            "nfcEnd" -> {
                closeCard()
                stopReader()
                result.success(null)
            }
            "nfcMessage" -> result.success(null)
            "initialLink" -> {
                result.success(initialLink)
                initialLink = null
            }
            "deviceName" -> {
                val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                val model = Build.MODEL
                result.success(if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model")
            }
            "vaultStatus" -> result.success(vault.status())
            "vaultSetEnabled" -> {
                vault.setEnabled(call.argument<Boolean>("enabled") == true)
                result.success(vault.status())
            }
            "vaultForget" -> {
                vault.forget()
                result.success(vault.status())
            }
            "vaultSave" -> {
                val pin = (call.argument<String>("pin") ?: "").toCharArray()
                if (pin.size != 8 || pin.any { it !in '0'..'9' }) {
                    pin.fill('0')
                    result.error("BAD_PIN", "Il PIN della CIE è di 8 cifre", null)
                } else {
                    vault.save(pin, { result.success(vault.status()) }, { result.error(it.code, it.message, null) })
                }
            }
            // Il PIN sbloccato passa a Dart, come quello digitato, e resta in memoria solo per la sessione.
            "vaultUnlock" -> vault.unlock(
                onPin = { pin -> result.success(String(pin)); pin.fill('0') },
                onError = { result.error(it.code, it.message, null) },
            )
            "cancel" -> {
                cancelWaiting("Operazione annullata")
                closeCard()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun begin(result: MethodChannel.Result) {
        if (waiting != null || deferred != null || isoDep != null) {
            result.error("BUSY", "Un'operazione è già in corso", null)
            return
        }
        // Lo sblocco con il blocco schermo apre una schermata di sistema e mette in pausa
        // l'attività; la modalità lettore funziona solo in primo piano, quindi si aspetta.
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) startReader(result) else deferred = result
    }

    override fun onResume() {
        super.onResume()
        deferred?.let { r -> deferred = null; main.post { startReader(r) } }
    }

    private fun startReader(result: MethodChannel.Result) {
        val adapter = NfcAdapter.getDefaultAdapter(this)
        if (adapter == null || !adapter.isEnabled) {
            result.error("NFC_OFF", "NFC assente o disattivato", null)
            return
        }
        waiting = result
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 1000) }
        adapter.enableReaderMode(
            this,
            ::onTag,
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            extras,
        )
    }

    private fun onTag(tag: Tag) {
        worker.execute {
            val dep = IsoDep.get(tag)
            val trace = StringBuilder()
            var error: Pair<String, String>? = null
            if (dep == null) {
                error = "NOT_ISODEP" to "La carta non supporta ISO 14443-4"
            } else {
                try {
                    dep.connect()
                    dep.timeout = 10_000
                    trace.append("Tecnologie: ").append(tag.techList.joinToString { it.substringAfterLast('.') }).append('\n')
                    dep.historicalBytes?.let { trace.append("Historical bytes (NFC-A): ").append(hex(it)).append('\n') }
                    dep.hiLayerResponse?.let { trace.append("Higher layer response (NFC-B): ").append(hex(it)).append('\n') }
                } catch (e: IOException) {
                    error = "TAG_LOST" to "Collegamento con la carta interrotto: tienila ferma e riprova"
                }
            }
            main.post {
                val r = waiting
                if (r == null) {
                    // Già annullata, o carta rilevata una seconda volta: la si ignora.
                    if (isoDep !== dep) try { dep?.close() } catch (_: IOException) { }
                    return@post
                }
                waiting = null
                val e = error
                if (e != null) {
                    stopReader()
                    r.error(e.first, e.second, trace.toString())
                } else {
                    isoDep = dep
                    r.success(mapOf("trace" to trace.toString()))
                }
            }
        }
    }

    private fun transceive(apdu: ByteArray, result: MethodChannel.Result) {
        val dep = isoDep ?: return result.error("TAG_LOST", "Nessuna carta collegata", null)
        worker.execute {
            try {
                val resp = dep.transceive(apdu)
                main.post { result.success(resp) }
            } catch (e: Exception) {
                main.post { result.error("TAG_LOST", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun cancelWaiting(message: String) {
        deferred?.error("CANCELLED", message, null)
        deferred = null
        waiting?.error("CANCELLED", message, null)
        waiting = null
        stopReader()
    }

    private fun closeCard() {
        val dep = isoDep ?: return
        isoDep = null
        worker.execute { try { dep.close() } catch (_: IOException) { } }
    }

    private fun stopReader() {
        NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02X".format(it.toInt() and 0xFF) }

    override fun onPause() {
        super.onPause()
        // La modalità lettore è legata all'attività in primo piano: in pausa si annulla.
        if (waiting != null) cancelWaiting("App in secondo piano, operazione annullata")
        if (isoDep != null) {
            closeCard()
            stopReader()
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
