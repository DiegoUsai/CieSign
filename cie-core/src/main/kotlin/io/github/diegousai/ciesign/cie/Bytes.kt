package io.github.diegousai.ciesign.cie

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/** Funzioni di supporto per la manipolazione di array di byte. */
internal object Bytes {

    private val random = SecureRandom()

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02X".format(it.toInt() and 0xFF) }

    fun fromHex(hex: String): ByteArray {
        val clean = hex.replace(" ", "")
        require(clean.length % 2 == 0) { "Stringa esadecimale di lunghezza dispari" }
        return ByteArray(clean.length / 2) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    fun concat(vararg parts: ByteArray): ByteArray {
        val out = ByteArray(parts.sumOf { it.size })
        var pos = 0
        for (p in parts) {
            p.copyInto(out, pos)
            pos += p.size
        }
        return out
    }

    fun random(size: Int): ByteArray = ByteArray(size).also { random.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    /** Padding ISO/IEC 9797-1 metodo 2: 0x80 seguito da zeri fino al multiplo di 8. */
    fun isoPad(data: ByteArray): ByteArray {
        val padded = ByteArray((data.size / 8 + 1) * 8)
        data.copyInto(padded)
        padded[data.size] = 0x80.toByte()
        return padded
    }

    /** Rimuove il padding ISO/IEC 9797-1 metodo 2. */
    fun isoUnpad(data: ByteArray): ByteArray {
        var i = data.size - 1
        while (i >= 0 && data[i] == 0.toByte()) i--
        if (i < 0 || data[i] != 0x80.toByte()) throw SecureMessagingException("Padding ISO assente nella risposta")
        return data.copyOfRange(0, i)
    }

    /** Incrementa di uno un contatore big-endian (il Send Sequence Counter). */
    fun increment(counter: ByteArray) {
        for (i in counter.indices.reversed()) {
            val v = (counter[i].toInt() and 0xFF) + 1
            counter[i] = v.toByte()
            if (v <= 0xFF) return
        }
    }

    fun stripLeadingZeros(data: ByteArray): ByteArray {
        var i = 0
        while (i < data.size - 1 && data[i] == 0.toByte()) i++
        return data.copyOfRange(i, data.size)
    }

    fun right(data: ByteArray, n: Int): ByteArray = data.copyOfRange(data.size - n, data.size)

    /** Converte un intero non negativo in un array di lunghezza fissa (I2OSP di PKCS#1). */
    fun toFixedLength(value: BigInteger, length: Int): ByteArray {
        val raw = value.toByteArray()
        return when {
            raw.size == length -> raw
            raw.size == length + 1 && raw[0] == 0.toByte() -> raw.copyOfRange(1, raw.size)
            raw.size < length -> ByteArray(length - raw.size) + raw
            else -> throw IllegalArgumentException("Valore troppo grande per $length byte")
        }
    }
}
