package io.github.diegousai.ciesign.cie

import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.interfaces.RSAPrivateCrtKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec

/**
 * Simulatore della parte carta del protocollo IAS ECC, usato solo nei test.
 * Implementa il lato opposto di ogni passo di [CieCard], così da verificare che i
 * messaggi prodotti dal client siano coerenti: certificato CVC, autenticazione esterna
 * e interna, secure messaging, PIN, lettura dei file e firma PKCS#1.
 */
class SimulatedCie(
    private var pin: String = "12345678",
    var remainingAttempts: Int = 3,
    /** Se vero, un PIN errato è restituito come status esterno non protetto. */
    private val plainPinErrors: Boolean = false,
    /** Se vero, la selezione dell'AID con P2=0C fallisce, come su alcune carte reali. */
    private val rejectSelectWithoutFci: Boolean = false,
) : ApduTransport {

    val certificateDer: ByteArray = javaClass.getResource("/titolare-test.der")!!.readBytes()
    private val holderKey: RSAPrivateCrtKey = KeyFactory.getInstance("RSA")
        .generatePrivate(PKCS8EncodedKeySpec(javaClass.getResource("/titolare-test.pk8")!!.readBytes())) as RSAPrivateCrtKey

    private val caKey = rsa(2048)
    val caPrivateExponent: ByteArray = (caKey.private as RSAPrivateCrtKey).privateExponent.toByteArray()
    private val caPublic = caKey.public as RSAPublicKey
    private val dappKey = rsa(2048)
    private val dappPublic = dappKey.public as RSAPublicKey

    private val dhP = BigInteger.probablePrime(1024, java.security.SecureRandom())
    private val dhG = BigInteger.valueOf(2)
    private val dhQ = BigInteger.probablePrime(256, java.security.SecureRandom())
    private val dhPrivate = BigInteger(255, java.security.SecureRandom()).add(BigInteger.ONE)
    private val dhIccPublic = Bytes.toFixedLength(dhG.modPow(dhPrivate, dhP), 128)
    private var dhIfdPublic = ByteArray(0)

    private var encKey = ByteArray(0)
    private var macKey = ByteArray(0)
    private var ssc = ByteArray(8)
    private var smActive = false

    private var selectedFile = 0
    private var challenge = ByteArray(0)
    private var ifdAuthenticated = false
    private var pinVerified = false
    private var signKeySelected = false
    private var chainBuffer = ByteArray(0)
    private var pendingResponse = ByteArray(0)

    var commandCount = 0
        private set

    private val chr = Bytes.fromHex("4954000000000000" + "00000001")
    private val cha = Bytes.fromHex("A0000000308001") // 7 byte: AID di 6 byte e un ruolo

    private fun rsa(bits: Int) = KeyPairGenerator.getInstance("RSA").apply { initialize(bits) }.generateKeyPair()

    override fun transceive(apdu: ByteArray): ByteArray {
        commandCount++
        val ins = apdu[1].toInt() and 0xFF
        // GET RESPONSE in chiaro, anche durante il secure messaging.
        if (ins == 0xC0) return sendPending(apdu[4].toInt() and 0xFF)
        return if ((apdu[0].toInt() and 0x0C) == 0x0C) handleSm(apdu) else handlePlain(apdu)
    }

    // --------------------------------------------------------------------------------
    // Comandi in chiaro
    // --------------------------------------------------------------------------------

    private fun handlePlain(apdu: ByteArray): ByteArray {
        val cla = apdu[0].toInt() and 0xFF
        val ins = apdu[1].toInt() and 0xFF
        val p1 = apdu[2].toInt() and 0xFF
        val p2 = apdu[3].toInt() and 0xFF
        val data = if (apdu.size > 5) apdu.copyOfRange(5, 5 + (apdu[4].toInt() and 0xFF)) else ByteArray(0)

        if (cla and 0x10 != 0) {
            chainBuffer += data
            return sw(0x9000)
        }
        val full = chainBuffer + data
        chainBuffer = ByteArray(0)

        return when {
            ins == 0xA4 && p1 == 0x04 && p2 == 0x0C && rejectSelectWithoutFci -> sw(0x6A86)
            ins == 0xA4 && p1 == 0x04 -> if (full.contentEquals(CieConstants.IAS_AID) || full.contentEquals(CieConstants.CIE_AID)) sw(0x9000) else sw(0x6A82)
            ins == 0xA4 && p1 == 0x02 -> { selectedFile = fileId(full); sw(0x9000) }
            ins == 0xB0 -> readBinary(p1 shl 8 or p2, (apdu.last().toInt() and 0xFF).let { if (it == 0) 256 else it }, plain = true)
            ins == 0xCB -> getData(full)
            ins == 0x22 && p2 == 0xA6 -> {
                dhIfdPublic = Tlv.parse(Bytes.concat(byteArrayOf(0x30), Tlv.encodeLength(full.size), full)).children
                    .first { it.tag[0] == 0x91.toByte() }.value
                deriveSessionKeys()
                sw(0x9000)
            }
            else -> sw(0x6D00)
        }
    }

    private fun getData(query: ByteArray): ByteArray {
        val tag = query.last().let { if (it == 0x00.toByte()) query[query.size - 2] else it }.toInt() and 0xFF
        val body = when {
            query.contentEquals(byteArrayOf(0x4D, 0x04, 0xA6.toByte(), 0x02, 0x91.toByte(), 0x00)) ->
                Tlv.encode(0xA6, Tlv.encode(0x91, dhIccPublic))
            query[4] == 0xBF.toByte() && query[5] == 0xA1.toByte() -> {
                val value = when (tag) {
                    0x97 -> Bytes.stripLeadingZeros(dhG.toByteArray())
                    0x98 -> Bytes.toFixedLength(dhP, 128)
                    0x99 -> Bytes.toFixedLength(dhQ, 32)
                    else -> return sw(0x6A88)
                }
                Tlv.encode(0x70, encodeTag3(0xBFA101, Tlv.encode(0xA3, Tlv.encode(tag, value))))
            }
            query[4] == 0xBF.toByte() && query[5] == 0xA0.toByte() -> {
                // Ordine diverso da quello "ovvio": il modulo non è il primo elemento.
                val key = Bytes.concat(
                    Tlv.encode(0x5F20, chr),
                    Tlv.encode(0x5F4C, cha),
                    Tlv.encode(0x81, Bytes.toFixedLength(caPublic.modulus, 256)),
                    Tlv.encode(0x82, Bytes.stripLeadingZeros(caPublic.publicExponent.toByteArray())),
                )
                Tlv.encode(0x70, encodeTag3(0xBFA004, Tlv.encode(0x7F49, key)))
            }
            else -> return sw(0x6A88)
        }
        return respondWithGetResponse(body)
    }

    private fun encodeTag3(tag: Int, value: ByteArray) =
        Bytes.concat(byteArrayOf((tag shr 16).toByte(), (tag shr 8).toByte(), tag.toByte()), Tlv.encodeLength(value.size), value)

    /** Risponde con 61xx per costringere il client a usare GET RESPONSE. */
    private fun respondWithGetResponse(body: ByteArray): ByteArray {
        pendingResponse = body
        return sw(0x6100 or minOf(body.size, 0xFF).let { if (body.size > 0xFF) 0 else it })
    }

    private fun sendPending(le: Int): ByteArray {
        val n = if (le == 0) minOf(256, pendingResponse.size) else minOf(le, pendingResponse.size)
        val chunk = pendingResponse.copyOfRange(0, n)
        pendingResponse = pendingResponse.copyOfRange(n, pendingResponse.size)
        val status = if (pendingResponse.isEmpty()) 0x9000 else 0x6100 or (if (pendingResponse.size > 0xFF) 0 else pendingResponse.size)
        return chunk + sw(status)
    }

    private fun deriveSessionKeys() {
        val secret = Bytes.toFixedLength(BigInteger(1, dhIfdPublic).modPow(dhPrivate, dhP), 128)
        encKey = Bytes.sha256(secret, byteArrayOf(0, 0, 0, 1)).copyOfRange(0, 16)
        macKey = Bytes.sha256(secret, byteArrayOf(0, 0, 0, 2)).copyOfRange(0, 16)
        ssc = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1)
        smActive = true
    }

    // --------------------------------------------------------------------------------
    // Comandi protetti
    // --------------------------------------------------------------------------------

    private fun handleSm(apdu: ByteArray): ByteArray {
        check(smActive) { "Comando protetto prima dello scambio di chiavi" }
        val lc = apdu[4].toInt() and 0xFF
        val body = apdu.copyOfRange(5, 5 + lc)
        Bytes.increment(ssc)

        var pos = 0
        var dataObjects = ByteArray(0)
        var plain = ByteArray(0)
        var le: Int? = null
        var mac = ByteArray(0)
        while (pos < body.size) {
            val tag = body[pos].toInt() and 0xFF
            var len = body[pos + 1].toInt() and 0xFF
            var hdr = 2
            if (len > 0x80) {
                val n = len - 0x80
                len = 0
                for (i in 0 until n) len = (len shl 8) or (body[pos + 2 + i].toInt() and 0xFF)
                hdr += n
            }
            val whole = body.copyOfRange(pos, pos + hdr + len)
            val value = body.copyOfRange(pos + hdr, pos + hdr + len)
            when (tag) {
                0x87 -> { dataObjects += whole; plain = Bytes.isoUnpad(Crypto.tdesDecrypt(encKey, value.copyOfRange(1, value.size))) }
                0x85 -> { dataObjects += whole; plain = Bytes.isoUnpad(Crypto.tdesDecrypt(encKey, value)) }
                0x97 -> { dataObjects += whole; le = value[0].toInt() and 0xFF }
                0x8E -> mac = value
                else -> error("DO inatteso %02X".format(tag))
            }
            pos += hdr + len
        }
        val header = apdu.copyOfRange(0, 4)
        val expectedMac = Crypto.retailMac(macKey, Bytes.isoPad(Bytes.concat(Bytes.isoPad(Bytes.concat(ssc, header)), dataObjects)))
        check(expectedMac.contentEquals(mac)) { "MAC del comando non valido" }

        val cla = apdu[0].toInt() and 0xFF
        if (cla and 0x10 != 0) {
            chainBuffer += plain
            return smResponse(ByteArray(0), 0x9000)
        }
        val full = chainBuffer + plain
        chainBuffer = ByteArray(0)
        return execute(header, full, le)
    }

    private fun execute(header: ByteArray, data: ByteArray, le: Int?): ByteArray {
        val ins = header[1].toInt() and 0xFF
        val p1 = header[2].toInt() and 0xFF
        val p2 = header[3].toInt() and 0xFF
        return when (ins) {
            0x22 -> {
                signKeySelected = p1 == 0x41 && p2 == 0xA4 && data.contentEquals(Bytes.fromHex("800102840181"))
                smResponse(ByteArray(0), 0x9000)
            }
            0x2A -> smResponse(ByteArray(0), if (verifyCvc(data)) 0x9000 else 0x6300)
            0x84 -> {
                challenge = Bytes.random(le ?: 8)
                smResponse(challenge, 0x9000)
            }
            0x82 -> {
                ifdAuthenticated = verifyExternalAuth(data)
                smResponse(ByteArray(0), if (ifdAuthenticated) 0x9000 else 0x6300)
            }
            0x88 -> if (signKeySelected) sign(data) else internalAuth(data)
            0x20 -> verifyPin(data)
            0xA4 -> { selectedFile = fileId(data); smResponse(ByteArray(0), 0x9000) }
            0xB0 -> readBinary(p1 shl 8 or p2, if (le == null || le == 0) 256 else le, plain = false)
            else -> smResponse(ByteArray(0), 0x6D00)
        }
    }

    private fun verifyCvc(cvc: ByteArray): Boolean {
        val root = Tlv.parse(cvc)
        val sig = root.childWithTag(0x5F, 0x37).value
        val remainder = root.childWithTag(0x5F, 0x38).value
        val recovered = Bytes.toFixedLength(BigInteger(1, sig).modPow(caPublic.publicExponent, caPublic.modulus), 256)
        if (recovered[0] != 0x6A.toByte() || recovered.last() != 0xBC.toByte()) return false
        val head = recovered.copyOfRange(1, recovered.size - 33)
        val hash = recovered.copyOfRange(recovered.size - 33, recovered.size - 1)
        return Bytes.sha256(head + remainder).contentEquals(hash)
    }

    private fun verifyExternalAuth(data: ByteArray): Boolean {
        val snIfd = data.copyOfRange(0, 8)
        val sig = data.copyOfRange(8, data.size)
        val n = BigInteger(1, CieConstants.IFD_MODULUS)
        val recovered = Bytes.toFixedLength(BigInteger(1, sig).modPow(BigInteger(1, CieConstants.IFD_PUBLIC_EXPONENT), n), 256)
        if (recovered[0] != 0x6A.toByte() || recovered.last() != 0xBC.toByte()) return false
        val prnd = recovered.copyOfRange(1, recovered.size - 33)
        val hash = recovered.copyOfRange(recovered.size - 33, recovered.size - 1)
        val expected = Bytes.sha256(prnd, dhIfdPublic, snIfd, challenge, dhIccPublic, dhGBytes(), Bytes.toFixedLength(dhP, 128), Bytes.toFixedLength(dhQ, 32))
        return expected.contentEquals(hash)
    }

    private fun dhGBytes() = Bytes.stripLeadingZeros(dhG.toByteArray())

    private fun internalAuth(rndIfd: ByteArray): ByteArray {
        check(ifdAuthenticated) { "Autenticazione interna prima di quella esterna" }
        val snIcc = Bytes.fromHex("0102030405060708")
        val k = 256
        val prnd2 = Bytes.random(k - 34)
        val hash = Bytes.sha256(prnd2, dhIccPublic, snIcc, rndIfd, dhIfdPublic, dhGBytes(), Bytes.toFixedLength(dhP, 128), Bytes.toFixedLength(dhQ, 32))
        val block = Bytes.concat(byteArrayOf(0x6A), prnd2, hash, byteArrayOf(0xBC.toByte()))
        val priv = dappKey.private as RSAPrivateCrtKey
        val sig = Bytes.toFixedLength(BigInteger(1, block).modPow(priv.privateExponent, priv.modulus), k)
        val response = smResponse(snIcc + sig, 0x9000)
        // Dopo la risposta il contatore riparte dai challenge, come fa la carta reale.
        ssc = Bytes.concat(Bytes.right(challenge, 4), Bytes.right(rndIfd, 4))
        return response
    }

    private fun verifyPin(data: ByteArray): ByteArray {
        if (remainingAttempts == 0) return pinError(0x6983)
        if (String(data, Charsets.US_ASCII) == pin) {
            remainingAttempts = 3
            pinVerified = true
            return smResponse(ByteArray(0), 0x9000)
        }
        remainingAttempts--
        return pinError(0x63C0 or remainingAttempts)
    }

    private fun pinError(status: Int): ByteArray =
        if (plainPinErrors) sw(status) else smResponse(ByteArray(0), status)

    private fun sign(digestInfo: ByteArray): ByteArray {
        signKeySelected = false
        if (!pinVerified) return smResponse(ByteArray(0), 0x6982)
        val k = 256
        val ps = ByteArray(k - digestInfo.size - 3) { 0xFF.toByte() }
        val em = Bytes.concat(byteArrayOf(0x00, 0x01), ps, byteArrayOf(0x00), digestInfo)
        val sig = Bytes.toFixedLength(BigInteger(1, em).modPow(holderKey.privateExponent, holderKey.modulus), k)
        return smResponse(sig, 0x9000)
    }

    private fun readBinary(offset: Int, le: Int, plain: Boolean): ByteArray {
        val content = when (selectedFile) {
            0x1003 -> {
                if (!plain && !pinVerified) return smResponse(ByteArray(0), 0x6982)
                certificateDer + ByteArray(64) // riempimento finale come sulle carte reali
            }
            0x1004 -> Tlv.encode(0x30, Tlv.encode(0x02, byteArrayOf(0) + Bytes.toFixedLength(dappPublic.modulus, 256)) +
                Tlv.encode(0x02, Bytes.stripLeadingZeros(dappPublic.publicExponent.toByteArray())))
            else -> return if (plain) sw(0x6A82) else smResponse(ByteArray(0), 0x6A82)
        }
        if (offset >= content.size) return if (plain) sw(0x6B00) else smResponse(ByteArray(0), 0x6B00, outer = 0x6B00)
        val chunk = content.copyOfRange(offset, minOf(content.size, offset + le))
        val status = if (chunk.size < le) 0x6282 else 0x9000
        return if (plain) chunk + sw(status) else smResponse(chunk, status, outer = status)
    }

    /** Costruisce una risposta protetta; se è lunga la consegna con GET RESPONSE. */
    private fun smResponse(data: ByteArray, status: Int, outer: Int = 0x9000): ByteArray {
        Bytes.increment(ssc)
        val enc = if (data.isNotEmpty()) Tlv.encode(0x87, byteArrayOf(0x01) + Crypto.tdesEncrypt(encKey, Bytes.isoPad(data))) else ByteArray(0)
        val st = Tlv.encode(0x99, byteArrayOf((status shr 8).toByte(), status.toByte()))
        val mac = Crypto.retailMac(macKey, Bytes.isoPad(Bytes.concat(ssc, enc, st)))
        val body = Bytes.concat(enc, st, Tlv.encode(0x8E, mac))
        if (body.size > 200 && outer == 0x9000) return respondWithGetResponse(body)
        return body + sw(outer)
    }

    private fun fileId(data: ByteArray) = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)

    private fun sw(value: Int) = byteArrayOf((value shr 8).toByte(), value.toByte())
}
