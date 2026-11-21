package io.github.diegousai.ciesign.cie

import java.math.BigInteger
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Primitive crittografiche usate dal secure messaging della CIE. */
internal object Crypto {

    private val zeroIv = IvParameterSpec(ByteArray(8))

    private fun tripleDesKey(key: ByteArray): SecretKeySpec {
        val k24 = when (key.size) {
            8 -> Bytes.concat(key, key, key)
            16 -> Bytes.concat(key, key.copyOfRange(0, 8))
            24 -> key
            else -> throw IllegalArgumentException("Chiave 3DES di lunghezza ${key.size}")
        }
        return SecretKeySpec(k24, "DESede")
    }

    /** 3DES in modalità CBC con IV nullo e senza padding (il padding ISO è applicato a parte). */
    fun tdesEncrypt(key: ByteArray, data: ByteArray): ByteArray {
        val c = Cipher.getInstance("DESede/CBC/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, tripleDesKey(key), zeroIv)
        return c.doFinal(data)
    }

    fun tdesDecrypt(key: ByteArray, data: ByteArray): ByteArray {
        val c = Cipher.getInstance("DESede/CBC/NoPadding")
        c.init(Cipher.DECRYPT_MODE, tripleDesKey(key), zeroIv)
        return c.doFinal(data)
    }

    /**
     * Retail MAC, cioè ISO/IEC 9797-1 algoritmo 3 con DES: CBC-DES con la prima metà
     * della chiave, poi decifratura con la seconda metà e cifratura con la prima sull'ultimo
     * blocco. I dati devono essere già allineati a 8 byte.
     */
    fun retailMac(key: ByteArray, paddedData: ByteArray): ByteArray {
        require(key.size == 16) { "La chiave del MAC deve essere di 16 byte" }
        require(paddedData.size % 8 == 0) { "Dati del MAC non allineati" }
        val k1 = key.copyOfRange(0, 8)
        val k2 = key.copyOfRange(8, 16)
        val cbc = tdesEncrypt(k1, paddedData)
        val last = cbc.copyOfRange(cbc.size - 8, cbc.size)
        val mid = tdesDecrypt(k2, last)
        return tdesEncrypt(k1, mid)
    }

    /**
     * Operazione RSA grezza: data^exp mod modulus, con risultato della stessa lunghezza
     * in byte del modulo. Serve sia per le operazioni con chiave privata sia con chiave
     * pubblica, e per lo scambio Diffie-Hellman (g^x mod p).
     */
    fun modPow(data: ByteArray, exponent: ByteArray, modulus: ByteArray): ByteArray {
        val n = BigInteger(1, modulus)
        val result = BigInteger(1, data).modPow(BigInteger(1, exponent), n)
        return Bytes.toFixedLength(result, (n.bitLength() + 7) / 8)
    }
}
