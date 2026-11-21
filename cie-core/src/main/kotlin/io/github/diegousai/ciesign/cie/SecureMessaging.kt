package io.github.diegousai.ciesign.cie

/** Risposta di un comando APDU: dati e status word. */
class ApduResponse(val data: ByteArray, val sw: Int) {
    val isOk: Boolean get() = sw == 0x9000

    companion object {
        fun parse(raw: ByteArray): ApduResponse {
            if (raw.size < 2) throw CieProtocolException("Risposta APDU troppo corta")
            val sw = ((raw[raw.size - 2].toInt() and 0xFF) shl 8) or (raw[raw.size - 1].toInt() and 0xFF)
            return ApduResponse(raw.copyOfRange(0, raw.size - 2), sw)
        }
    }
}

/**
 * Secure messaging ISO/IEC 7816-4 con 3DES e Retail MAC, nella variante usata dalla CIE:
 * dati cifrati nel DO 87 (o 85 per le istruzioni dispari), Le nel DO 97, status nel DO 99,
 * MAC nel DO 8E calcolato sul Send Sequence Counter seguito dall'intestazione e dai DO.
 */
internal class SecureMessaging(
    private val encKey: ByteArray,
    private val macKey: ByteArray,
    initialSsc: ByteArray,
) {
    private val ssc = initialSsc.copyOf()

    /** Valore corrente del Send Sequence Counter, esposto per i test. */
    val sendSequenceCounter: ByteArray get() = ssc.copyOf()

    /**
     * Protegge un comando. [header] sono CLA INS P1 P2, [data] il campo dati in chiaro
     * (massimo 0xE7 byte, il chiamante gestisce il concatenamento), [le] la lunghezza
     * attesa della risposta o null se il comando non ne prevede.
     */
    fun wrap(header: ByteArray, data: ByteArray, le: Int?): ByteArray {
        require(header.size == 4)
        require(data.size <= MAX_SM_CHUNK) { "Campo dati troppo lungo per un singolo comando protetto" }
        Bytes.increment(ssc)

        val smHeader = header.copyOf()
        smHeader[0] = (smHeader[0].toInt() or 0x0C).toByte()

        var dataObjects = ByteArray(0)
        if (data.isNotEmpty()) {
            val encrypted = Crypto.tdesEncrypt(encKey, Bytes.isoPad(data))
            val odd = (header[1].toInt() and 0x01) == 1
            dataObjects += if (odd) Tlv.encode(0x85, encrypted) else Tlv.encode(0x87, byteArrayOf(0x01) + encrypted)
        }
        if (le != null) {
            dataObjects += Tlv.encode(0x97, byteArrayOf(le.toByte()))
        }

        val macInput = Bytes.isoPad(Bytes.concat(Bytes.isoPad(Bytes.concat(ssc, smHeader)), dataObjects))
        val mac = Crypto.retailMac(macKey, macInput)
        val body = dataObjects + Tlv.encode(0x8E, mac)
        return Bytes.concat(smHeader, byteArrayOf(body.size.toByte()), body, byteArrayOf(0x00))
    }

    /** Verifica il MAC e decifra il corpo di una risposta protetta (senza lo status word esterno). */
    fun unwrap(body: ByteArray): ApduResponse {
        Bytes.increment(ssc)
        var encObject = ByteArray(0)
        var encData: ByteArray? = null
        var statusObject = ByteArray(0)
        var sw = -1
        var macVerified = false

        var pos = 0
        while (pos < body.size) {
            val tag = body[pos].toInt() and 0xFF
            var lenPos = pos + 1
            if (lenPos >= body.size) throw SecureMessagingException("Risposta protetta troncata")
            var len = body[lenPos].toInt() and 0xFF
            var lenBytes = 1
            if (len > 0x80) {
                val n = len - 0x80
                len = 0
                for (i in 1..n) len = (len shl 8) or (body[lenPos + i].toInt() and 0xFF)
                lenBytes += n
            }
            val valueStart = lenPos + lenBytes
            val valueEnd = valueStart + len
            if (valueEnd > body.size) throw SecureMessagingException("Lunghezza errata nella risposta protetta")
            val whole = body.copyOfRange(pos, valueEnd)
            val value = body.copyOfRange(valueStart, valueEnd)
            when (tag) {
                0x87 -> {
                    if (value.isEmpty() || value[0] != 0x01.toByte()) throw SecureMessagingException("Indicatore di padding inatteso nel DO 87")
                    encObject = whole
                    encData = value.copyOfRange(1, value.size)
                }
                0x85 -> {
                    encObject = whole
                    encData = value
                }
                0x99 -> {
                    if (len != 2) throw SecureMessagingException("DO 99 di lunghezza errata")
                    statusObject = whole
                    sw = ((value[0].toInt() and 0xFF) shl 8) or (value[1].toInt() and 0xFF)
                }
                0x8E -> {
                    if (len != 8) throw SecureMessagingException("MAC di lunghezza errata")
                    val expected = Crypto.retailMac(macKey, Bytes.isoPad(Bytes.concat(ssc, encObject, statusObject)))
                    if (!expected.contentEquals(value)) throw SecureMessagingException("MAC della risposta non valido")
                    macVerified = true
                }
                else -> throw SecureMessagingException("Tag %02X inatteso nella risposta protetta".format(tag))
            }
            pos = valueEnd
        }
        if (!macVerified) throw SecureMessagingException("Risposta protetta senza MAC")
        if (sw < 0) throw SecureMessagingException("Risposta protetta senza status word")
        val plain = encData?.let { Bytes.isoUnpad(Crypto.tdesDecrypt(encKey, it)) } ?: ByteArray(0)
        return ApduResponse(plain, sw)
    }

    /** Nuova istanza con le stesse chiavi e un contatore diverso. */
    fun withCounter(newSsc: ByteArray): SecureMessaging = SecureMessaging(encKey, macKey, newSsc)

    companion object {
        /** Dimensione massima dei dati in chiaro per comando, come nel middleware ufficiale. */
        const val MAX_SM_CHUNK = 0xE7
    }
}
