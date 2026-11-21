package io.github.diegousai.ciesign.cie

import java.math.BigInteger
import java.security.Signature
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CieCardTest {

    private fun runSession(card: SimulatedCie, pin: String, digest: ByteArray?): CieSessionResult {
        val c = CieCard(card, {}, card.caPrivateExponent)
        c.openSecureChannel()
        c.verifyPin(pin.toCharArray())
        val cert = c.readCertificate()
        if (digest == null) return CieSessionResult(cert, null, null, null)
        val sig = c.signDigestInfo(CieSigner.digestInfoSha256(digest))
        return CieSessionResult(cert, digest, sig, CieSigner.verifyPkcs1Sha256(cert, digest, sig))
    }

    @Test
    fun `legge il certificato e firma un'impronta con la carta simulata`() {
        val card = SimulatedCie()
        val data = "Prova CIE Sign".toByteArray()
        val digest = CieSigner.sha256(data)

        val result = runSession(card, "12345678", digest)

        assertContentEquals(card.certificateDer, result.certificate, "Il certificato deve essere ripulito dal riempimento finale")
        assertEquals(true, result.signatureValid)
        val sig = assertNotNull(result.signature)
        assertEquals(256, sig.size)

        // Verifica indipendente con la libreria standard Java sul messaggio originale.
        val verifier = Signature.getInstance("SHA256withRSA")
        verifier.initVerify(CieSigner.parseCertificate(result.certificate))
        verifier.update(data)
        assertTrue(verifier.verify(sig))
    }

    @Test
    fun `una firma alterata non viene accettata`() {
        val card = SimulatedCie()
        val digest = CieSigner.sha256("documento".toByteArray())
        val result = runSession(card, "12345678", digest)
        val tampered = result.signature!!.copyOf().also { it[100] = (it[100].toInt() xor 1).toByte() }
        assertEquals(false, CieSigner.verifyPkcs1Sha256(result.certificate, digest, tampered))
        assertEquals(false, CieSigner.verifyPkcs1Sha256(result.certificate, CieSigner.sha256("altro".toByteArray()), result.signature!!))
    }

    @Test
    fun `PIN errato riporta i tentativi rimasti`() {
        val card = SimulatedCie()
        val e = assertFailsWith<WrongPinException> { runSession(card, "00000000", null) }
        assertEquals(2, e.remainingAttempts)
    }

    @Test
    fun `PIN errato con status non protetto`() {
        val card = SimulatedCie(plainPinErrors = true, remainingAttempts = 2)
        val e = assertFailsWith<WrongPinException> { runSession(card, "00000000", null) }
        assertEquals(1, e.remainingAttempts)
    }

    @Test
    fun `PIN bloccato`() {
        val card = SimulatedCie(remainingAttempts = 0)
        assertFailsWith<PinBlockedException> { runSession(card, "12345678", null) }
        val last = SimulatedCie(remainingAttempts = 1)
        assertFailsWith<PinBlockedException> { runSession(last, "11111111", null) }
    }

    @Test
    fun `PIN di formato errato non arriva alla carta`() {
        val card = SimulatedCie()
        val c = CieCard(card, {}, card.caPrivateExponent)
        c.openSecureChannel()
        val before = card.commandCount
        assertFailsWith<InvalidPinFormatException> { c.verifyPin("1234".toCharArray()) }
        assertFailsWith<InvalidPinFormatException> { c.verifyPin("1234567a".toCharArray()) }
        assertEquals(before, card.commandCount)
        assertEquals(3, card.remainingAttempts)
    }

    @Test
    fun `la firma funziona anche se la carta rifiuta la selezione con P2=0C`() {
        val card = SimulatedCie(rejectSelectWithoutFci = true)
        val digest = CieSigner.sha256("prova".toByteArray())
        assertEquals(true, runSession(card, "12345678", digest).signatureValid)
    }

    @Test
    fun `una carta diversa dalla CIE viene riconosciuta`() {
        val notCie = ApduTransport { byteArrayOf(0x6A, 0x82.toByte()) }
        assertFailsWith<NotACieException> { CieCard(notCie).openSecureChannel() }
    }

    @Test
    fun `le chiavi del dispositivo formano una coppia RSA valida`() {
        val n = BigInteger(1, CieConstants.IFD_MODULUS)
        val m = BigInteger(1, Bytes.random(200))
        val c = m.modPow(BigInteger(1, CieConstants.IFD_PRIVATE_EXPONENT), n)
        assertEquals(m, c.modPow(BigInteger(1, CieConstants.IFD_PUBLIC_EXPONENT), n))
    }
}
