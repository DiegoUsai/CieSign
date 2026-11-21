package io.github.diegousai.ciesign.cie

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PrimitivesTest {

    @Test
    fun `padding ISO 9797-1 metodo 2`() {
        assertEquals("0102038000000000", Bytes.hex(Bytes.isoPad(Bytes.fromHex("010203"))))
        assertEquals("01020304050607088000000000000000", Bytes.hex(Bytes.isoPad(Bytes.fromHex("0102030405060708"))))
        assertContentEquals(Bytes.fromHex("010203"), Bytes.isoUnpad(Bytes.fromHex("0102038000000000")))
        assertFailsWith<SecureMessagingException> { Bytes.isoUnpad(Bytes.fromHex("0102030000000000")) }
    }

    @Test
    fun `incremento del contatore con riporto`() {
        val c = Bytes.fromHex("00000000000000FF")
        Bytes.increment(c)
        assertEquals("0000000000000100", Bytes.hex(c))
    }

    @Test
    fun `Retail MAC secondo il vettore di prova ICAO 9303`() {
        // ICAO Doc 9303 parte 11, appendice D.4: KSmac e comando SELECT protetto.
        val ksMac = Bytes.fromHex("F1CB1F1FB5ADF208806B89DC579DC1F8")
        val n = Bytes.fromHex("887022120C06C2270CA4020C800000008709016375432908C044F68000000000")
        assertEquals("BF8B92D635FF24F8", Bytes.hex(Crypto.retailMac(ksMac, n)))
    }

    @Test
    fun `cifratura 3DES secondo il vettore di prova ICAO 9303`() {
        val ksEnc = Bytes.fromHex("979EC13B1CBFE9DCD01AB0FED307EAE5")
        val data = Bytes.isoPad(Bytes.fromHex("011E"))
        assertEquals("6375432908C044F6", Bytes.hex(Crypto.tdesEncrypt(ksEnc, data)))
    }

    @Test
    fun `codifica e analisi TLV`() {
        val long = Tlv.encode(0x91, ByteArray(256))
        assertEquals("91820100", Bytes.hex(long.copyOfRange(0, 4)))
        val nested = Tlv.encode(0x70, Tlv.encode(0x7F49, Tlv.encode(0x81, byteArrayOf(1, 2)) + Tlv.encode(0x5F20, byteArrayOf(3))))
        val root = Tlv.parse(nested)
        assertContentEquals(byteArrayOf(1, 2), root.child(0).child(0).value)
        assertContentEquals(byteArrayOf(3), root.child(0).childWithTag(0x5F, 0x20).value)
    }

    @Test
    fun `DigestInfo SHA-256`() {
        val di = CieSigner.digestInfoSha256(ByteArray(32))
        assertEquals(51, di.size)
        assertEquals("3031300D060960864801650304020105000420", Bytes.hex(di.copyOfRange(0, 19)))
    }

    @Test
    fun `rimozione del riempimento dopo il certificato`() {
        val der = Tlv.encode(0x30, ByteArray(300) { 7 })
        assertContentEquals(der, CieCard.trimDer(der + ByteArray(50)))
    }
}
