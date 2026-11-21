package io.github.diegousai.ciesign.cie

import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPublicKey

/** Esito di una sessione con la carta. */
class CieSessionResult(
    /** Certificato del titolare in DER. */
    val certificate: ByteArray,
    /** Impronta SHA-256 firmata, se è stata chiesta una firma. */
    val digest: ByteArray?,
    /** Firma RSA PKCS#1 v1.5 dell'impronta, se è stata chiesta una firma. */
    val signature: ByteArray?,
    /** Esito della verifica locale della firma con la chiave pubblica del certificato. */
    val signatureValid: Boolean?,
)

/**
 * Operazioni di alto livello: lettura del certificato e firma di un'impronta SHA-256.
 * È la funzione che lo smartphone eseguirà quando il PC gli invierà un'impronta da firmare.
 */
object CieSigner {

    /** Prefisso DER della struttura DigestInfo per SHA-256 (RFC 8017, nota 1 del par. 9.2). */
    private val SHA256_DIGEST_INFO_PREFIX = Bytes.fromHex("3031300D060960864801650304020105000420")

    fun digestInfoSha256(digest: ByteArray): ByteArray {
        require(digest.size == 32) { "L'impronta SHA-256 deve essere di 32 byte" }
        return SHA256_DIGEST_INFO_PREFIX + digest
    }

    fun sha256(data: ByteArray): ByteArray = Bytes.sha256(data)

    /**
     * Apre il canale sicuro, verifica il PIN, legge il certificato e, se [digest] non è nullo,
     * fa firmare l'impronta alla carta e verifica la firma ottenuta.
     */
    fun run(transport: ApduTransport, pin: CharArray, digest: ByteArray?, log: (String) -> Unit = {}): CieSessionResult {
        val card = CieCard(transport, log)
        card.openSecureChannel()
        log("Verifica del PIN")
        card.verifyPin(pin)
        val cert = card.readCertificate()
        if (digest == null) return CieSessionResult(cert, null, null, null)
        val signature = card.signDigestInfo(digestInfoSha256(digest))
        val valid = verifyPkcs1Sha256(cert, digest, signature)
        log(if (valid) "Firma verificata con il certificato" else "La firma NON corrisponde al certificato")
        return CieSessionResult(cert, digest, signature, valid)
    }

    fun parseCertificate(der: ByteArray): X509Certificate =
        CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate

    /**
     * Verifica una firma RSA PKCS#1 v1.5 su un'impronta SHA-256 già calcolata, ricostruendo
     * il blocco 00 01 FF..FF 00 DigestInfo con la chiave pubblica del certificato.
     */
    fun verifyPkcs1Sha256(certificateDer: ByteArray, digest: ByteArray, signature: ByteArray): Boolean {
        val key = parseCertificate(certificateDer).publicKey as? RSAPublicKey ?: return false
        return verifyPkcs1Sha256(key.modulus, key.publicExponent, digest, signature)
    }

    internal fun verifyPkcs1Sha256(modulus: BigInteger, exponent: BigInteger, digest: ByteArray, signature: ByteArray): Boolean {
        val k = (modulus.bitLength() + 7) / 8
        val s = BigInteger(1, signature)
        if (signature.size != k || s >= modulus) return false
        val em = Bytes.toFixedLength(s.modPow(exponent, modulus), k)
        val t = digestInfoSha256(digest)
        if (k < t.size + 11) return false
        val expected = ByteArray(k)
        expected[0] = 0x00
        expected[1] = 0x01
        for (i in 2 until k - t.size - 1) expected[i] = 0xFF.toByte()
        expected[k - t.size - 1] = 0x00
        t.copyInto(expected, k - t.size)
        return em.contentEquals(expected)
    }
}
