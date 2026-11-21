package io.github.diegousai.ciesign.cie

/**
 * Codifica e decodifica minima di strutture BER-TLV, sufficiente per i comandi e le
 * risposte dell'applicazione IAS ECC della CIE.
 */
internal class Tlv(val tag: ByteArray, val value: ByteArray, val children: List<Tlv>) {

    val isConstructed: Boolean get() = children.isNotEmpty()

    fun child(index: Int): Tlv = children.getOrNull(index)
        ?: throw CieProtocolException("Struttura TLV inattesa: manca il figlio $index del tag ${Bytes.hex(tag)}")

    fun childWithTag(vararg tagBytes: Int): Tlv {
        val wanted = ByteArray(tagBytes.size) { tagBytes[it].toByte() }
        return children.firstOrNull { it.tag.contentEquals(wanted) }
            ?: throw CieProtocolException("Struttura TLV inattesa: manca il tag ${Bytes.hex(wanted)}")
    }

    companion object {

        /** Codifica un oggetto TLV; il tag può occupare uno o due byte. */
        fun encode(tag: Int, value: ByteArray): ByteArray {
            val tagBytes = if (tag > 0xFF) byteArrayOf((tag shr 8).toByte(), tag.toByte()) else byteArrayOf(tag.toByte())
            return Bytes.concat(tagBytes, encodeLength(value.size), value)
        }

        fun encodeLength(len: Int): ByteArray = when {
            len < 0x80 -> byteArrayOf(len.toByte())
            len <= 0xFF -> byteArrayOf(0x81.toByte(), len.toByte())
            len <= 0xFFFF -> byteArrayOf(0x82.toByte(), (len shr 8).toByte(), len.toByte())
            else -> throw IllegalArgumentException("Lunghezza TLV non supportata: $len")
        }

        /**
         * Analizza il primo oggetto TLV contenuto in [data] e ne restituisce l'albero.
         * Con [reparse] attivo tenta di analizzare come TLV anche il contenuto di
         * OCTET STRING e BIT STRING, come fa il middleware ufficiale.
         */
        fun parse(data: ByteArray, reparse: Boolean = false): Tlv =
            parseAt(data, 0, data.size, reparse).first

        private fun parseAt(data: ByteArray, start: Int, end: Int, reparse: Boolean): Pair<Tlv, Int> {
            var pos = start
            fun next(): Int {
                if (pos >= end) throw CieProtocolException("TLV troncato")
                return data[pos++].toInt() and 0xFF
            }

            val tagStart = pos
            val first = next()
            if (first and 0x1F == 0x1F) {
                while (next() and 0x80 == 0x80) { /* byte successivi del tag */ }
            }
            val tag = data.copyOfRange(tagStart, pos)

            var len = next()
            if (len > 0x80) {
                val lenLen = len - 0x80
                len = 0
                repeat(lenLen) { len = (len shl 8) or next() }
            }
            if (pos + len > end) throw CieProtocolException("Lunghezza TLV oltre i limiti")
            val valueStart = pos
            val valueEnd = pos + len
            val value = data.copyOfRange(valueStart, valueEnd)

            val tagId = tag[0].toInt() and 0xFF
            val constructed = tagId and 0x20 != 0
            val children = when {
                constructed -> parseChildren(data, valueStart, valueEnd, reparse)
                reparse && tag.size == 1 && tagId == 0x04 -> tryParseChildren(data, valueStart, valueEnd, reparse)
                reparse && tag.size == 1 && tagId == 0x03 && len > 1 -> tryParseChildren(data, valueStart + 1, valueEnd, reparse)
                else -> emptyList()
            }
            return Tlv(tag, value, children) to valueEnd
        }

        private fun parseChildren(data: ByteArray, start: Int, end: Int, reparse: Boolean): List<Tlv> {
            val list = mutableListOf<Tlv>()
            var pos = start
            while (pos < end) {
                // Coppie 00 00 di riempimento: si saltano.
                if (pos + 1 < end && data[pos] == 0.toByte() && data[pos + 1] == 0.toByte()) {
                    pos += 2
                    continue
                }
                val (child, next) = parseAt(data, pos, end, reparse)
                list.add(child)
                pos = next
            }
            return list
        }

        private fun tryParseChildren(data: ByteArray, start: Int, end: Int, reparse: Boolean): List<Tlv> =
            try {
                parseChildren(data, start, end, reparse)
            } catch (e: CieProtocolException) {
                emptyList()
            }
    }
}
