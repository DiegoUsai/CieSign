package io.github.diegousai.cie_sign_companion

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Custodia facoltativa del PIN della CIE (UC13, D25).
 *
 * Il PIN è cifrato con AES-256-GCM da una chiave dell'Android Keystore che non esce
 * mai dall'hardware sicuro del telefono e che si usa solo dopo uno sblocco biometrico
 * forte (classe 3) o, da Android 11, anche con il PIN, la sequenza o la password del
 * telefono. Ogni cifratura e decifratura richiede uno sblocco: non c'è una finestra di
 * validità. La chiave è invalidata dal sistema quando si aggiunge un'impronta o un volto,
 * o quando si toglie il blocco schermo; in quel caso il PIN salvato si cancella e l'utente
 * lo digita di nuovo.
 *
 * I file stanno in noBackupFilesDir, quindi non finiscono nei backup del telefono.
 * Il PIN in chiaro esiste solo per il tempo della sessione con la carta e non arriva
 * mai al codice Flutter quando lo si sblocca.
 */
class PinVault(private val activity: FragmentActivity) {

    /** Esito negativo di uno sblocco o di un salvataggio. */
    class VaultException(val code: String, message: String) : Exception(message)

    private val dir get() = activity.noBackupFilesDir
    private val pinFile get() = File(dir, "pin-cie.enc")
    private val enabledFile get() = File(dir, "sblocco-biometrico")

    /** Metodi di sblocco ammessi: da Android 11 anche il blocco schermo del telefono. */
    private val authenticators =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) BIOMETRIC_STRONG or DEVICE_CREDENTIAL else BIOMETRIC_STRONG

    /**
     * Disponibilità sul telefono: "ready", "not_enrolled" (manca un'impronta o un blocco
     * schermo), "unsupported" (nessun sensore abbastanza sicuro).
     */
    fun availability(): String = when (BiometricManager.from(activity).canAuthenticate(authenticators)) {
        BiometricManager.BIOMETRIC_SUCCESS -> "ready"
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "not_enrolled"
        else -> "unsupported"
    }

    val enabled: Boolean get() = enabledFile.exists()
    val saved: Boolean get() = pinFile.exists()

    fun status(): Map<String, Any> = mapOf(
        "availability" to availability(),
        "enabled" to enabled,
        "saved" to saved,
        "deviceCredential" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R),
    )

    /** Attiva o disattiva la funzione; disattivandola si cancellano PIN e chiave. */
    fun setEnabled(on: Boolean) {
        if (on) {
            enabledFile.writeText("1")
        } else {
            enabledFile.delete()
            forget()
        }
    }

    /** Cancella il PIN salvato e la chiave che lo cifra. */
    fun forget() {
        pinFile.delete()
        try {
            keyStore().deleteEntry(ALIAS)
        } catch (_: Exception) {
        }
    }

    /** Cifra [pin] dopo uno sblocco e lo salva. [pin] viene azzerato in ogni caso. */
    fun save(pin: CharArray, onDone: () -> Unit, onError: (VaultException) -> Unit) {
        if (!enabled) {
            pin.fill('0')
            onError(VaultException("VAULT_DISABLED", "Sblocco biometrico non attivo"))
            return
        }
        val cipher = try {
            // Una chiave nuova a ogni salvataggio: quella vecchia, se c'era, non serve più.
            forget()
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, createKey()) }
        } catch (e: Exception) {
            pin.fill('0')
            onError(VaultException("VAULT_ERROR", "Impossibile preparare la chiave: ${e.message}"))
            return
        }
        prompt(
            title = "Ricorda il PIN della CIE",
            subtitle = "Conferma che sei tu: alle prossime firme basterà questo sblocco e la carta",
            cipher = cipher,
            onCipher = { c ->
                val bytes = ByteArray(pin.size) { pin[it].code.toByte() }
                pin.fill('0')
                try {
                    val ct = c.doFinal(bytes)
                    val iv = c.iv
                    pinFile.writeBytes(byteArrayOf(iv.size.toByte()) + iv + ct)
                    onDone()
                } catch (e: Exception) {
                    onError(VaultException("VAULT_ERROR", "Salvataggio non riuscito: ${e.message}"))
                } finally {
                    bytes.fill(0)
                }
            },
            onError = { pin.fill('0'); onError(it) },
        )
    }

    /** Chiede lo sblocco e restituisce il PIN in chiaro: chi lo riceve deve azzerarlo. */
    fun unlock(onPin: (CharArray) -> Unit, onError: (VaultException) -> Unit) {
        val data = if (pinFile.exists()) pinFile.readBytes() else null
        if (!enabled || data == null || data.isEmpty()) {
            onError(VaultException("VAULT_EMPTY", "Nessun PIN salvato sul telefono"))
            return
        }
        val cipher = try {
            val ivLen = data[0].toInt()
            val key = keyStore().getKey(ALIAS, null) as? SecretKey
                ?: throw KeyPermanentlyInvalidatedException("chiave assente")
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, data, 1, ivLen))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            forget()
            onError(VaultException("VAULT_INVALIDATED", "Le impronte, il volto o il blocco schermo sono cambiati"))
            return
        } catch (e: Exception) {
            forget()
            onError(VaultException("VAULT_INVALIDATED", "PIN salvato non leggibile: ${e.message}"))
            return
        }
        prompt(
            title = "Sblocca il PIN della CIE",
            subtitle = "Poi avvicina la carta al telefono",
            cipher = cipher,
            onCipher = { c ->
                val ivLen = data[0].toInt()
                try {
                    val bytes = c.doFinal(data, 1 + ivLen, data.size - 1 - ivLen)
                    val pin = CharArray(bytes.size) { bytes[it].toInt().toChar() }
                    bytes.fill(0)
                    onPin(pin)
                } catch (e: Exception) {
                    forget()
                    onError(VaultException("VAULT_INVALIDATED", "PIN salvato non leggibile: ${e.message}"))
                }
            },
            onError = onError,
        )
    }

    private fun prompt(
        title: String,
        subtitle: String,
        cipher: Cipher,
        onCipher: (Cipher) -> Unit,
        onError: (VaultException) -> Unit,
    ) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val c = result.cryptoObject?.cipher
                if (c == null) onError(VaultException("VAULT_ERROR", "Sblocco senza chiave")) else onCipher(c)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val code = when (errorCode) {
                    BiometricPrompt.ERROR_USER_CANCELED,
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                    BiometricPrompt.ERROR_CANCELED -> "VAULT_CANCELLED"
                    BiometricPrompt.ERROR_LOCKOUT,
                    BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "VAULT_LOCKOUT"
                    else -> "VAULT_ERROR"
                }
                onError(VaultException(code, errString.toString()))
            }
            // onAuthenticationFailed: tentativo non riconosciuto, il sistema lascia riprovare.
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(authenticators)
            // Firmare è un atto voluto: anche con il riconoscimento del volto serve una conferma.
            .setConfirmationRequired(true)
            .apply { if (authenticators and DEVICE_CREDENTIAL == 0) setNegativeButtonText("Inserisci il PIN") }
            .build()
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun createKey(): SecretKey {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // Durata 0: uno sblocco per ogni uso della chiave.
                    setUserAuthenticationParameters(
                        0,
                        KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                    )
                }
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setIsStrongBoxBacked(true)
            }
            .build()

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.init(spec(strongBox = true))
                return generator.generateKey()
            } catch (_: Exception) {
                // StrongBox (chip sicuro dedicato) non c'è su tutti i telefoni: si usa il TEE.
            }
        }
        generator.init(spec(strongBox = false))
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "ciesign-pin-cie"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
