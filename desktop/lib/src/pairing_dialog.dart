import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'link_service.dart';

/// Abbinamento (UC1): QR code, poi confronto del codice di sei cifre.
class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.link});

  final LinkService link;

  static Future<bool?> show(BuildContext context, LinkService link) => showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PairingDialog(link: link),
  );

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  StreamSubscription<bool>? _done;
  bool _waitingPhone = false;

  @override
  void initState() {
    super.initState();
    widget.link.addListener(_changed);
    widget.link.startPairing();
    _done = widget.link.pairingResults.listen((ok) {
      if (mounted) Navigator.of(context).pop(ok);
    });
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.link.removeListener(_changed);
    _done?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.link.pairingOffer;
    final session = widget.link.pairingSession;
    final t = Theme.of(context).textTheme;
    Widget body;
    if (offer == null) {
      body = const SizedBox(height: 280, child: Center(child: CircularProgressIndicator()));
    } else if (session == null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Apri Firmami sullo smartphone, scegli "Abbina PC" e inquadra il codice.'),
          const SizedBox(height: 16),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: offer.toUri().toString(), size: 260),
          ),
          const SizedBox(height: 12),
          Text('Il telefono deve essere sulla stessa Wi-Fi del PC.', style: t.bodySmall),
          if (offer.addresses.isEmpty)
            Text('Nessuna rete locale trovata sul PC.', style: t.bodySmall?.copyWith(color: Colors.red)),
        ],
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Collegato a ${session.peerName}.'),
          const SizedBox(height: 8),
          const Text('Controlla che sul telefono compaia lo stesso codice:'),
          const SizedBox(height: 16),
          SelectableText(
            '${session.sas!.substring(0, 3)} ${session.sas!.substring(3)}',
            style: t.displayMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 4),
          ),
          const SizedBox(height: 16),
          if (_waitingPhone) const Text('In attesa della conferma sul telefono…'),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Abbina uno smartphone'),
      content: SizedBox(width: 360, child: body),
      actions: [
        TextButton(
          onPressed: () {
            widget.link.cancelPairing();
            Navigator.of(context).pop(false);
          },
          child: const Text('Annulla'),
        ),
        if (session != null && !_waitingPhone) ...[
          OutlinedButton(onPressed: () => widget.link.confirmPairing(false), child: const Text('Non coincide')),
          FilledButton(
            onPressed: () {
              setState(() => _waitingPhone = true);
              widget.link.confirmPairing(true);
            },
            child: const Text('Coincide'),
          ),
        ],
      ],
    );
  }
}
