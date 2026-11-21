package io.github.diegousai.ciesign.cie

/** Radice delle eccezioni del modulo CIE. */
open class CieException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** La carta avvicinata non è una CIE o non espone l'applicazione IAS ECC. */
class NotACieException(detail: String) :
    CieException("La carta non risponde come una CIE 3.0 ($detail)")

/** PIN errato: [remainingAttempts] indica i tentativi rimasti prima del blocco. */
class WrongPinException(val remainingAttempts: Int) :
    CieException("PIN errato, tentativi rimasti: $remainingAttempts")

/** PIN bloccato: serve il PUK per sbloccarlo. */
class PinBlockedException : CieException("PIN bloccato, serve il PUK")

/** Il PIN inserito non ha il formato atteso (8 cifre). */
class InvalidPinFormatException : CieException("Il PIN della CIE è composto da 8 cifre")

/** Errore nella cifratura o nella verifica del secure messaging. */
class SecureMessagingException(message: String) : CieException(message)

/** Risposta inattesa della carta a un comando. */
open class CieProtocolException(message: String) : CieException(message)

/** La carta ha risposto con uno status word di errore. */
class CardStatusException(val step: String, val sw: Int) :
    CieProtocolException("Errore della carta durante \"$step\": SW=%04X".format(sw))
