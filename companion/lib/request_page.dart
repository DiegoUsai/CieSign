import 'dart:async';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cie_bridge.dart';
import 'link_service.dart';

/// Richiesta arrivata dal PC: firma di un documento (UC3) oppure lettura del
/// certificato, quando il telefono non lo conosce ancora.
///
/// L'utente vede il nome del documento e l'impronta dichiarata, inserisce il
/// PIN e avvicina la CIE; il telefono fa firmare alla carta l'impronta degli
/// attributi firmati ricevuti dal PC e risponde sul canale cifrato.
class RequestPage extends StatefulWidget {
  const RequestPage({super.key, required this.link, required this.bridge, required this.request, this.cancels});

  final PhoneLink link;
  final CieBridge bridge;

  /// [SignRequest] oppure [CertificateRequest].
  final LinkMessage request;

  /// Annullamenti inviati dal PC.
  final Stream<Cancel>? cancels;

  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends State<RequestPage> {
  final _pin = TextEditingController();
  bool _busy = false;
  bool _answered = false;
  String? _error;
  String? _status;
  Timer? _ticker;
  StreamSubscription<Cancel>? _cancelSub;

  SignRequest? get _sign => widget.request is SignRequest ? widget.request as SignRequest : null;

  @override
  void initState() {
    super.initState();
    widget.bridge.onStatus = (s) {
      if (mounted) setState(() => _status = s);
    };
    final s = _sign;
    if (s != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (s.isExpired() && !_busy && !_answered) {
          _reply(SignRejected(s.id, 'expired'), close: false);
          setState(() => _error = 'La richiesta è scaduta: riprova dal PC.');
        } else {
          setState(() {});
        }
      });
    }
    _cancelSub = widget.cancels?.listen((c) async {
      if (s == null || c.id != s.id) return;
      _answered = true;
      if (_busy) await widget.bridge.cancel();
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _cancelSub?.cancel();
    widget.bridge.onStatus = null;
    _pin.dispose();
    // Chiudendo la pagina senza rispondere, il PC riceve un rifiuto.
    final s = _sign;
    if (!_answered && s != null) widget.link.send(SignRejected(s.id)).ignore();
    super.dispose();
  }

  bool get _pinValid => RegExp(r'^\d{8}$').hasMatch(_pin.text);

  Future<void> _reply(LinkMessage m, {bool close = true}) async {
    _answered = true;
    try {
      await widget.link.send(m);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Risposta non inviata al PC: $e');
      return;
    }
    if (close && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _start() async {
    final s = _sign;
    if (s != null && s.isExpired()) {
      await _reply(SignRejected(s.id, 'expired'), close: false);
      setState(() => _error = 'La richiesta è scaduta: riprova dal PC.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Avvicina la CIE al retro del telefono';
    });
    try {
      final r = await widget.bridge.start(pin: _pin.text, digest: s?.digestToSign);
      final known = widget.link.certificate;
      widget.link.rememberCertificate(r.certificate);
      if (s == null) {
        await _reply(CertificateResponse(r.certificate));
      } else if (known != null && !listEquals(known, r.certificate)) {
        // Il PC ha preparato gli attributi firmati con il certificato di un'altra carta.
        await _reply(
          SignError(s.id, 'CERT_CHANGED', 'La CIE avvicinata non è quella registrata sul telefono: riprova dal PC'),
          close: false,
        );
        setState(() => _error = 'Hai avvicinato una CIE diversa da quella registrata. Ora è registrata questa: riprova dal PC.');
      } else if (r.signatureValid != true) {
        await _reply(SignError(s.id, 'CIE_ERROR', 'La firma della carta non corrisponde al certificato'), close: false);
        setState(() => _error = 'La firma della carta non corrisponde al certificato.');
      } else {
        await _reply(SignResponse(s.id, r.signature!, r.certificate));
      }
    } on CieError catch (e) {
      _pin.clear();
      if (e.code == 'CANCELLED' && _answered) return;
      final retry = e.code == 'WRONG_PIN' || e.code == 'TAG_LOST' || e.code == 'CANCELLED';
      if (s != null && !retry) await _reply(SignError(s.id, e.code, e.message, e.remainingAttempts), close: false);
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  String _errorText(CieError e) => switch (e.code) {
    'WRONG_PIN' => e.remainingAttempts == 1
        ? 'PIN errato. Resta un solo tentativo: un altro errore blocca la carta.'
        : 'PIN errato. Tentativi rimasti: ${e.remainingAttempts ?? '?'}.',
    'PIN_BLOCKED' => 'Il PIN è bloccato. Si sblocca con il PUK tramite l\'app CieID o il Software CIE.',
    'TAG_LOST' => 'La carta si è allontanata: tienila ferma e riprova.',
    'CANCELLED' => 'Operazione annullata.',
    _ => e.message,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sign;
    final pcName = widget.link.pc?.device.name ?? 'PC';
    final left = s?.expiresAt.difference(DateTime.now()).inSeconds;
    return Scaffold(
      appBar: AppBar(title: Text(s != null ? 'Richiesta di firma' : 'Richiesta del certificato')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (s != null) ...[
              Text('$pcName chiede di firmare:', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(s.documentName, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              _row('Formato', s.format == SignFormat.pades ? 'PAdES (PDF firmato)' : 'CAdES (file .p7m)'),
              _row('Dimensione', _size(s.documentSize)),
              if (s.visiblePage != null) _row('Firma visibile', 'pagina ${s.visiblePage}'),
              _row('Impronta del documento', _digest(s)),
              if (left != null && !_answered)
                _row('Scade tra', left > 0 ? '$left secondi' : 'scaduta'),
            ] else
              Text(
                '$pcName chiede il certificato della tua CIE, che serve a preparare la firma. '
                'Inserisci il PIN e avvicina la carta: il telefono lo ricorderà per le prossime firme.',
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 16),
            if (!_answered) ...[
              TextField(
                controller: _pin,
                enabled: !_busy,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'PIN della CIE (8 cifre)', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              if (!_busy) ...[
                FilledButton.icon(
                  onPressed: _pinValid ? _start : null,
                  icon: const Icon(Icons.nfc),
                  label: Text(s != null ? 'Firma con la CIE' : 'Leggi il certificato'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => s != null ? _reply(SignRejected(s.id)) : Navigator.of(context).pop(false),
                  child: Text(s != null ? 'Rifiuta' : 'Annulla'),
                ),
              ] else ...[
                OutlinedButton(onPressed: widget.bridge.cancel, child: const Text('Annulla')),
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Text(_status ?? '', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
              ),
              if (_answered) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Chiudi')),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static String _size(int b) => b < 1024 * 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';

  static String _digest(SignRequest s) {
    try {
      final h = hex(s.documentDigest);
      // Gruppi di quattro caratteri, per confrontarla a occhio con quella mostrata dal PC.
      return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join(' ');
    } on Object {
      return 'non leggibile';
    }
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        SelectableText(value),
      ],
    ),
  );
}
