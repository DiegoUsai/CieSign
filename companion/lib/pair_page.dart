import 'package:ciesign_link/ciesign_link.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'link_service.dart';

/// Inquadra il QR code mostrato dal PC e restituisce l'offerta di abbinamento.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      try {
        final offer = PairingOffer.parse(raw);
        _done = true;
        Navigator.of(context).pop(offer);
        return;
      } on FormatException catch (e) {
        setState(() => _hint = '${e.message}. Inquadra il QR code mostrato da CIE Sign sul PC.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inquadra il QR code del PC')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: Text(
                _hint ?? 'Sul PC apri CIE Sign, scegli "Abbina smartphone" e inquadra il codice.',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Abbinamento (UC1) lato telefono: collegamento al PC, confronto del codice
/// di sei cifre e conferma.
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.link, required this.offer});

  final PhoneLink link;
  final PairingOffer offer;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  PairingAttempt? _attempt;
  String? _error;
  bool _waitingPc = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    // Uscendo senza aver concluso, il PC vede chiudersi il collegamento.
    if (!_closed) _attempt?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _attempt = null;
    });
    try {
      final a = await widget.link.startPairing(widget.offer);
      if (!mounted) {
        a.cancel();
        return;
      }
      setState(() => _attempt = a);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _explain(e));
    }
  }

  String _explain(Object e) {
    final s = '$e';
    if (e is LinkException && s.startsWith('PC non raggiungibile')) {
      return 'Il PC non risponde. Controlla che telefono e PC siano sulla stessa Wi-Fi e che il firewall '
          'di Windows consenta a CIE Sign di ricevere collegamenti sulle reti private.\n\nDettaglio: $s';
    }
    return s;
  }

  Future<void> _confirm(bool ok) async {
    final a = _attempt!;
    setState(() => _waitingPc = ok);
    try {
      final saved = await a.confirm(ok);
      _closed = true;
      if (mounted) Navigator.of(context).pop(saved);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _waitingPc = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final a = _attempt;
    Widget body;
    if (_error != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Abbinamento non riuscito', style: t.titleMedium),
          const SizedBox(height: 8),
          SelectableText(_error!),
          const SizedBox(height: 16),
          FilledButton(onPressed: _connect, child: const Text('Riprova')),
        ],
      );
    } else if (a == null) {
      body = Column(
        children: [
          const SizedBox(height: 32),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Collegamento a ${widget.offer.pcName}…', style: t.titleMedium),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Collegato a ${a.pcName}.', style: t.titleMedium),
          const SizedBox(height: 8),
          const Text('Controlla che sul PC compaia lo stesso codice:'),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '${a.sas.substring(0, 3)} ${a.sas.substring(3)}',
              style: t.displayMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 4),
            ),
          ),
          const SizedBox(height: 24),
          if (_waitingPc) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            const Text('In attesa della conferma sul PC…', textAlign: TextAlign.center),
          ] else ...[
            FilledButton(onPressed: () => _confirm(true), child: const Text('Coincide')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => _confirm(false), child: const Text('Non coincide')),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Abbina il PC')),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [body])),
    );
  }
}
