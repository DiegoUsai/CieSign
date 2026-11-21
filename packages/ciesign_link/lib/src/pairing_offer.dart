import 'keys.dart';

/// Contenuto del QR code che il PC mostra per l'abbinamento.
///
/// Esempio: `ciesign://pair?v=1&id=…&n=UFFICIO-DIEGO&k=…&t=…&a=192.168.1.20:47321,[fe80::1]:47321&b=1`
///
/// - `k` è la chiave pubblica statica del PC: lo smartphone la riceve da un
///   canale che un attaccante in rete non può alterare (lo schermo).
/// - `t` è un segreto monouso: dimostra al PC che chi si collega ha visto il QR.
/// - `a` sono gli indirizzi del PC sulla rete locale, utili se **mDNS** non
///   funziona; `b=1` indica che il PC accetta anche il Bluetooth.
class PairingOffer {
  PairingOffer({
    required this.pcId,
    required this.pcName,
    required this.pcPublicKey,
    required this.token,
    required this.addresses,
    this.bluetooth = false,
    this.version = 1,
  });

  final int version;
  final String pcId;
  final String pcName;
  final List<int> pcPublicKey;
  final List<int> token;
  final List<String> addresses;
  final bool bluetooth;

  static const scheme = 'ciesign';

  Uri toUri() => Uri(
    scheme: scheme,
    host: 'pair',
    queryParameters: {
      'v': '$version',
      'id': pcId,
      'n': pcName,
      'k': b64u(pcPublicKey),
      't': b64u(token),
      if (addresses.isNotEmpty) 'a': addresses.join(','),
      if (bluetooth) 'b': '1',
    },
  );

  factory PairingOffer.parse(String text) {
    final u = Uri.parse(text.trim());
    if (u.scheme != scheme || u.host != 'pair') throw const FormatException('QR code non di CIE Sign');
    final q = u.queryParameters;
    final v = int.tryParse(q['v'] ?? '');
    if (v != 1) throw FormatException('Versione del protocollo non supportata: ${q['v']}');
    final k = unb64u(q['k']!), t = unb64u(q['t']!);
    if (k.length != 32 || t.length < 16) throw const FormatException('QR code di abbinamento non valido');
    return PairingOffer(
      version: v!,
      pcId: q['id']!,
      pcName: q['n'] ?? 'PC',
      pcPublicKey: k,
      token: t,
      addresses: (q['a'] ?? '').split(',').where((s) => s.isNotEmpty).toList(),
      bluetooth: q['b'] == '1',
    );
  }
}
