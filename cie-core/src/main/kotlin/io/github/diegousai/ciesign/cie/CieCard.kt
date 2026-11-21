package io.github.diegousai.ciesign.cie

import java.math.BigInteger

/** Canale verso la carta: su Android è implementato con IsoDep. */
fun interface ApduTransport {
    fun transceive(apdu: ByteArray): ByteArray
}

/**
 * Dialogo con l'applicazione IAS ECC della CIE 3.0.
 *
 * La sequenza riproduce quella del middleware e dell'SDK ufficiali del Ministero
 * dell'Interno e dell'IPZS (licenza BSD-3-Clause, vedi THIRD_PARTY_NOTICES.md):
 * selezione delle applicazioni, scambio di chiavi Diffie-Hellman, autenticazione
 * reciproca tra dispositivo e carta (DAPP), secure messaging, verifica del PIN,
 * lettura del certificato e firma con la chiave del titolare.
 */
class CieCard internal constructor(
    private val transport: ApduTransport,
    private val log: (String) -> Unit,
    private val caPrivateExponent: ByteArray,
) {
    constructor(transport: ApduTransport, log: (String) -> Unit = {}) :
        this(transport, log, CieConstants.CA_PRIVATE_EXPONENT)

    private var dhG = ByteArray(0)
    private var dhP = ByteArray(0)
    private var dhQ = ByteArray(0)
    private var dhPrivate = ByteArray(0)
    private var dhPublic = ByteArray(0)
    private var dhIccPublic = ByteArray(0)
    private var caModulus = ByteArray(0)
    private var caCar = ByteArray(0)
    private var caAid = ByteArray(0)
    private var dappModulus = ByteArray(0)
    private var dappPubExp = ByteArray(0)
    private var sm: SecureMessaging? = null

    /** Stabilisce il canale sicuro con la carta. Va chiamato prima di ogni altra operazione. */
    fun openSecureChannel() {
        log("Selezione dell'applicazione IAS")
        // Come l'SDK ufficiale, l'esito delle selezioni non blocca la sequenza: alcune carte
        // rispondono in modo diverso a seconda di P2. Si riprova con P2=00 e si prosegue.
        var ias = sendPlain(SELECT_AID, CieConstants.IAS_AID)
        if (!ias.isOk) {
            log("Selezione IAS con P2=0C: SW=%04X, riprovo con P2=00".format(ias.sw))
            ias = sendPlain(SELECT_AID_FCI, CieConstants.IAS_AID, 0x00)
            if (!ias.isOk) log("Selezione IAS con P2=00: SW=%04X".format(ias.sw))
        }
        val cie = sendPlain(SELECT_AID, CieConstants.CIE_AID)
        if (!cie.isOk) log("Selezione AID CIE: SW=%04X".format(cie.sw))

        log("Lettura dei parametri Diffie-Hellman")
        try {
            dhG = readDhParam(0x97)
        } catch (e: CardStatusException) {
            throw NotACieException("selezione IAS SW=%04X, selezione CIE SW=%04X, parametri DH SW=%04X".format(ias.sw, cie.sw, e.sw))
        }
        dhP = readDhParam(0x98)
        dhQ = readDhParam(0x99)

        log("Lettura della chiave pubblica della carta")
        readDappPublicKey()
        readExtAuthKeyParams()

        log("Scambio di chiavi")
        dhKeyExchange()

        log("Autenticazione reciproca con la carta")
        deviceAuthentication()
        log("Canale sicuro attivo")
    }

    /**
     * Verifica il PIN di 8 cifre. Solleva [WrongPinException] o [PinBlockedException]
     * se la verifica non riesce.
     */
    fun verifyPin(pin: CharArray) {
        if (pin.size != 8 || pin.any { it !in '0'..'9' }) throw InvalidPinFormatException()
        val pinBytes = ByteArray(8) { pin[it].code.toByte() }
        try {
            val resp = sendSm(byteArrayOf(0x00, 0x20, 0x00, CieConstants.PIN_ID), pinBytes, null)
            checkPinStatus(resp.sw)
        } catch (e: CardStatusException) {
            checkPinStatus(e.sw)
        } finally {
            pinBytes.fill(0)
        }
    }

    /** Legge il certificato X.509 del titolare (file 1003) e lo restituisce in DER. */
    fun readCertificate(): ByteArray {
        log("Lettura del certificato")
        val raw = readFileSm(CieConstants.CERT_FILE_ID)
        if (raw.isEmpty()) throw CieProtocolException("Certificato vuoto")
        return trimDer(raw)
    }

    /**
     * Firma con la chiave del titolare una struttura DigestInfo PKCS#1. La carta applica
     * il padding PKCS#1 v1.5 e restituisce la firma RSA. Richiede il PIN già verificato.
     */
    fun signDigestInfo(digestInfo: ByteArray): ByteArray {
        log("Firma dell'impronta")
        val mse = Bytes.concat(Tlv.encode(0x80, byteArrayOf(0x02)), Tlv.encode(0x84, byteArrayOf(CieConstants.SIGN_KEY_ID)))
        expectOk("impostazione della chiave di firma", sendSm(byteArrayOf(0x00, 0x22, 0x41, 0xA4.toByte()), mse, null))
        val resp = sendSm(byteArrayOf(0x00, 0x88.toByte(), 0x00, 0x00), digestInfo, null)
        expectOk("firma", resp)
        if (resp.data.isEmpty()) throw CieProtocolException("La carta non ha restituito la firma")
        return resp.data
    }

    // ---------------------------------------------------------------------------------
    // Fasi di apertura del canale
    // ---------------------------------------------------------------------------------

    private fun readDhParam(tag: Int): ByteArray {
        val query = byteArrayOf(0x4D, 0x0A, 0x70, 0x08, 0xBF.toByte(), 0xA1.toByte(), 0x01, 0x04, 0xA3.toByte(), 0x02, tag.toByte(), 0x00)
        val resp = expectOk("lettura parametro DH", sendPlain(GET_DATA, query))
        return Tlv.parse(resp.data).child(0).child(0).child(0).value
    }

    private fun readDappPublicKey() {
        val raw = readFilePlain(CieConstants.DAPP_KEY_FILE_ID)
        val tlv = Tlv.parse(raw)
        dappModulus = Bytes.stripLeadingZeros(tlv.child(0).value)
        dappPubExp = Bytes.stripLeadingZeros(tlv.child(1).value)
    }

    private fun readExtAuthKeyParams() {
        val query = byteArrayOf(0x4D, 0x09, 0x70, 0x07, 0xBF.toByte(), 0xA0.toByte(), 0x04, 0x03, 0x7F, 0x49, 0x80.toByte())
        val resp = expectOk("lettura parametri di autenticazione", sendPlain(GET_DATA, query))
        val key = Tlv.parse(resp.data, reparse = true).child(0).child(0)
        caModulus = key.child(0).value
        val cha = key.childWithTag(0x5F, 0x4C).value
        val chr = key.childWithTag(0x5F, 0x20).value
        caCar = chr.copyOfRange(4, chr.size)
        caAid = cha.copyOfRange(0, 6)
    }

    private fun dhKeyExchange() {
        val q = BigInteger(1, dhQ)
        var x: BigInteger
        do {
            x = BigInteger(1, Bytes.random(dhQ.size))
        } while (x.signum() == 0 || x >= q)
        dhPrivate = Bytes.toFixedLength(x, dhQ.size)
        dhPublic = Crypto.modPow(dhG, dhPrivate, dhP)

        val mse = Bytes.concat(
            Tlv.encode(0x80, byteArrayOf(0x9B.toByte())),
            Tlv.encode(0x83, byteArrayOf(0x81.toByte())),
            Tlv.encode(0x91, dhPublic),
        )
        expectOk("invio della chiave DH", sendPlain(byteArrayOf(0x00, 0x22, 0x41, 0xA6.toByte()), mse))

        val resp = expectOk(
            "lettura della chiave DH della carta",
            sendPlain(GET_DATA, byteArrayOf(0x4D, 0x04, 0xA6.toByte(), 0x02, 0x91.toByte(), 0x00)),
        )
        dhIccPublic = Tlv.parse(resp.data, reparse = true).child(0).value
        val secret = Crypto.modPow(dhIccPublic, dhPrivate, dhP)

        val encKey = Bytes.sha256(secret, byteArrayOf(0, 0, 0, 1)).copyOfRange(0, 16)
        val macKey = Bytes.sha256(secret, byteArrayOf(0, 0, 0, 2)).copyOfRange(0, 16)
        sm = SecureMessaging(encKey, macKey, byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1))
    }

    private fun deviceAuthentication() {
        val shaSize = 32
        val snIfd = byteArrayOf(0x20, 0, 0, 0, 0, 0, 0, 0x01)
        val chr = Bytes.concat(byteArrayOf(0, 0, 0, 0), snIfd)
        val cha = Bytes.concat(caAid, byteArrayOf(0x01))
        val oid = byteArrayOf(0x2A, 0x81.toByte(), 0x22, 0xF4.toByte(), 0x2A, 0x02, 0x04, 0x01, 0x04)
        val module = CieConstants.IFD_MODULUS
        val endEntityCert = Bytes.concat(byteArrayOf(0x8A.toByte()), caCar, chr, cha, oid, module, CieConstants.IFD_PUBLIC_EXPONENT)

        // Certificato verificabile dalla carta (CVC), firmato con lo schema ISO 9796-2.
        val headLen = caModulus.size - shaSize - 2
        val toSignCert = Bytes.concat(byteArrayOf(0x6A), endEntityCert.copyOfRange(0, headLen), Bytes.sha256(endEntityCert), byteArrayOf(0xBC.toByte()))
        val certSignature = Crypto.modPow(toSignCert, caPrivateExponent, caModulus)
        val remainder = endEntityCert.copyOfRange(headLen, endEntityCert.size)
        val cvc = Tlv.encode(0x7F21, Bytes.concat(Tlv.encode(0x5F37, certSignature), Tlv.encode(0x5F38, remainder), Tlv.encode(0x42, caCar)))

        expectOk("selezione della chiave di verifica", sendSm(byteArrayOf(0x00, 0x22, 0x81.toByte(), 0xB6.toByte()),
            Bytes.concat(Tlv.encode(0x80, byteArrayOf(0x41)), Tlv.encode(0x83, byteArrayOf(CieConstants.EXT_AUTH_KEY_ID))), null))
        expectOk("verifica del certificato", sendSm(byteArrayOf(0x00, 0x2A, 0x00, 0xAE.toByte()), cvc, null))
        expectOk("impostazione del CHR", sendSm(byteArrayOf(0x00, 0x22, 0x81.toByte(), 0xA4.toByte()), Tlv.encode(0x83, chr), null))

        // Autenticazione esterna: il dispositivo dimostra alla carta di possedere la chiave IFD.
        val challenge = expectOk("richiesta del challenge", sendSm(byteArrayOf(0x00, 0x84.toByte(), 0x00, 0x00), ByteArray(0), 8)).data
        val padSize = module.size - shaSize - 2
        val prnd = Bytes.random(padSize)
        val hash = Bytes.sha256(prnd, dhPublic, snIfd, challenge, dhIccPublic, dhG, dhP, dhQ)
        val toSignAuth = Bytes.concat(byteArrayOf(0x6A), prnd, hash, byteArrayOf(0xBC.toByte()))
        val authSignature = Crypto.modPow(toSignAuth, CieConstants.IFD_PRIVATE_EXPONENT, module)
        expectOk("autenticazione esterna", sendSm(byteArrayOf(0x00, 0x82.toByte(), 0x00, 0x00), Bytes.concat(snIfd, authSignature), null))

        // Autenticazione interna: la carta dimostra al dispositivo di essere autentica.
        expectOk("impostazione dell'autenticazione interna", sendSm(byteArrayOf(0x00, 0x22, 0x41, 0xA4.toByte()),
            Bytes.concat(Tlv.encode(0x84, byteArrayOf(0x82.toByte())), Tlv.encode(0x80, byteArrayOf(0x9B.toByte()))), null))
        val rndIfd = Bytes.random(8)
        val ia = expectOk("autenticazione interna", sendSm(byteArrayOf(0x00, 0x88.toByte(), 0x00, 0x00), rndIfd, null)).data
        if (ia.size <= 8) throw CieProtocolException("Risposta di autenticazione interna troppo corta")
        val snIcc = ia.copyOfRange(0, 8)
        val recovered = Crypto.modPow(ia.copyOfRange(8, ia.size), dappPubExp, dappModulus)
        if (recovered[0] != 0x6A.toByte() || recovered[recovered.size - 1] != 0xBC.toByte()) {
            throw CieProtocolException("Autenticazione della carta non riuscita (formato)")
        }
        val prnd2 = recovered.copyOfRange(1, recovered.size - shaSize - 1)
        val hashIcc = recovered.copyOfRange(recovered.size - shaSize - 1, recovered.size - 1)
        val expected = Bytes.sha256(prnd2, dhIccPublic, snIcc, rndIfd, dhPublic, dhG, dhP, dhQ)
        if (!expected.contentEquals(hashIcc)) throw CieProtocolException("Autenticazione della carta non riuscita (impronta)")

        // Da qui il contatore riparte dai challenge scambiati.
        val current = sm ?: throw IllegalStateException("Canale sicuro non attivo")
        sm = current.withCounter(Bytes.concat(Bytes.right(challenge, 4), Bytes.right(rndIfd, 4)))
    }

    // ---------------------------------------------------------------------------------
    // Trasporto
    // ---------------------------------------------------------------------------------

    private fun transmit(apdu: ByteArray): ApduResponse = ApduResponse.parse(transport.transceive(apdu))

    /** Invia un comando in chiaro, con concatenamento oltre 255 byte e GET RESPONSE. */
    private fun sendPlain(header: ByteArray, data: ByteArray, le: Int? = null): ApduResponse {
        var offset = 0
        while (true) {
            val chunk = data.copyOfRange(offset, minOf(data.size, offset + 255))
            offset += chunk.size
            val last = offset >= data.size
            val h = header.copyOf()
            if (!last) h[0] = (h[0].toInt() or 0x10).toByte()
            var apdu = h
            if (chunk.isNotEmpty()) apdu = Bytes.concat(apdu, byteArrayOf(chunk.size.toByte()), chunk)
            if (le != null) apdu += le.toByte()
            val resp = transmit(apdu)
            if (!last) {
                if (!resp.isOk) throw CardStatusException("comando concatenato", resp.sw)
                continue
            }
            return collectGetResponse(resp)
        }
    }

    private fun collectGetResponse(first: ApduResponse): ApduResponse {
        var resp = first
        var data = first.data
        while ((resp.sw shr 8) == 0x61) {
            resp = transmit(byteArrayOf(0x00, 0xC0.toByte(), 0x00, 0x00, (resp.sw and 0xFF).toByte()))
            data += resp.data
        }
        return ApduResponse(data, resp.sw)
    }

    /** Invia un comando protetto, con concatenamento oltre 0xE7 byte. */
    private fun sendSm(header: ByteArray, data: ByteArray, le: Int?): ApduResponse {
        val channel = sm ?: throw IllegalStateException("Canale sicuro non attivo")
        var offset = 0
        while (true) {
            val chunk = data.copyOfRange(offset, minOf(data.size, offset + SecureMessaging.MAX_SM_CHUNK))
            offset += chunk.size
            val last = offset >= data.size
            val h = header.copyOf()
            if (!last) h[0] = (h[0].toInt() or 0x10).toByte()
            val raw = collectGetResponse(transmit(channel.wrap(h, chunk, if (last) le else null)))
            val resp = when (raw.sw) {
                0x9000, 0x6282, 0x6B00 -> channel.unwrap(raw.data)
                else -> throw CardStatusException(if (last) "comando protetto" else "comando protetto concatenato", raw.sw)
            }
            if (!last) {
                if (!resp.isOk) throw CardStatusException("comando protetto concatenato", resp.sw)
                continue
            }
            return resp
        }
    }

    private fun readFilePlain(fileId: Int): ByteArray {
        val select = sendPlain(byteArrayOf(0x00, 0xA4.toByte(), 0x02, 0x04), fileIdBytes(fileId))
        if (!select.isOk) log("Selezione del file %04X: SW=%04X".format(fileId, select.sw))
        var content = ByteArray(0)
        while (true) {
            var resp = sendPlain(readBinaryHeader(content.size), ByteArray(0), 0x00)
            if ((resp.sw shr 8) == 0x6C) resp = sendPlain(readBinaryHeader(content.size), ByteArray(0), resp.sw and 0xFF)
            when {
                resp.isOk && resp.data.isNotEmpty() -> content += resp.data
                resp.sw == 0x6282 -> return content + resp.data
                else -> return content
            }
        }
    }

    private fun readFileSm(fileId: Int): ByteArray {
        expectOk("selezione del file", sendSm(byteArrayOf(0x00, 0xA4.toByte(), 0x02, 0x04), fileIdBytes(fileId), null))
        var content = ByteArray(0)
        while (true) {
            var resp = sendSm(readBinaryHeader(content.size), ByteArray(0), 0x00)
            if ((resp.sw shr 8) == 0x6C) resp = sendSm(readBinaryHeader(content.size), ByteArray(0), resp.sw and 0xFF)
            when {
                resp.isOk && resp.data.isNotEmpty() -> content += resp.data
                resp.sw == 0x6282 -> return content + resp.data
                else -> return content
            }
        }
    }

    private fun readBinaryHeader(offset: Int) = byteArrayOf(0x00, 0xB0.toByte(), (offset shr 8).toByte(), offset.toByte())

    private fun fileIdBytes(id: Int) = byteArrayOf((id shr 8).toByte(), id.toByte())

    private fun expectOk(step: String, resp: ApduResponse): ApduResponse {
        if (!resp.isOk) throw CardStatusException(step, resp.sw)
        return resp
    }

    private fun checkPinStatus(sw: Int) {
        when {
            sw == 0x9000 -> return
            (sw and 0xFFF0) == 0x63C0 -> {
                val left = sw and 0x0F
                if (left == 0) throw PinBlockedException() else throw WrongPinException(left)
            }
            sw == 0x6983 -> throw PinBlockedException()
            else -> throw CardStatusException("verifica del PIN", sw)
        }
    }

    companion object {
        private val SELECT_AID = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x0C)
        private val SELECT_AID_FCI = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00)
        private val GET_DATA = byteArrayOf(0x00, 0xCB.toByte(), 0x3F, 0xFF.toByte())

        /** Elimina eventuali byte di riempimento dopo la struttura DER del certificato. */
        internal fun trimDer(raw: ByteArray): ByteArray {
            if (raw.size < 2 || raw[0] != 0x30.toByte()) return raw
            var len = raw[1].toInt() and 0xFF
            var header = 2
            if (len > 0x80) {
                val n = len - 0x80
                len = 0
                for (i in 0 until n) len = (len shl 8) or (raw[2 + i].toInt() and 0xFF)
                header += n
            }
            val total = header + len
            return if (total <= raw.size) raw.copyOfRange(0, total) else raw
        }
    }
}
