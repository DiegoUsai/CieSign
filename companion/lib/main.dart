import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cie_bridge.dart';

void main() => runApp(const CieSignCompanionApp());

class CieSignCompanionApp extends StatelessWidget {
  const CieSignCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CIE Sign',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0066CC))),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0066CC), brightness: Brightness.dark),
      ),
      home: const PrototypePage(),
    );
  }
}

/// Schermata del prototipo: legge il certificato dalla CIE e firma un'impronta di prova.
class PrototypePage extends StatefulWidget {
  const PrototypePage({super.key});

  @override
  State<PrototypePage> createState() => _PrototypePageState();
}

class _PrototypePageState extends State<PrototypePage> {
  late final CieBridge _bridge = CieBridge(onStatus: (s) => setState(() => _status = s));
  final _pin = TextEditingController();
  final _text = TextEditingController(text: 'Prova di firma con CIE Sign');

  bool _busy = false;
  bool _sign = true;
  String? _status;
  String? _nfcWarning;
  CieResult? _result;
  CieError? _error;

  @override
  void initState() {
    super.initState();
    _checkNfc();
  }

  @override
  void dispose() {
    _pin.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _checkNfc() async {
    final s = await _bridge.nfcStatus();
    setState(() {
      _nfcWarning = !s.available
          ? 'Questo telefono non ha l\'NFC: non può leggere la CIE.'
          : !s.enabled
              ? 'L\'NFC è disattivato: attivalo nelle impostazioni e torna qui.'
              : null;
    });
  }

  Uint8List get _digest => Uint8List.fromList(sha256.convert(utf8.encode(_text.text)).bytes);

  bool get _pinValid => RegExp(r'^\d{8}$').hasMatch(_pin.text);

  Future<void> _start() async {
    await _checkNfc();
    if (_nfcWarning != null) return;
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
      _status = 'Avvicina la CIE al retro del telefono';
    });
    try {
      final r = await _bridge.start(pin: _pin.text, digest: _sign ? _digest : null);
      setState(() => _result = r);
    } on CieError catch (e) {
      setState(() => _error = e);
      // Dopo un PIN errato lo si cancella, così un secondo tentativo è sempre voluto.
      if (e.code == 'WRONG_PIN' || e.code == 'PIN_BLOCKED') _pin.clear();
    } finally {
      setState(() {
        _busy = false;
        _status = null;
      });
    }
  }

  Future<void> _cancel() async {
    await _bridge.cancel();
  }

  /// Testo con certificato, impronta e firma in Base64, utile per verificare la firma sul PC.
  String _export(CieResult r) {
    final m = {
      'certificato_der_base64': base64.encode(r.certificate),
      if (r.digest != null) 'impronta_sha256_hex': hex(r.digest!),
      if (r.signature != null) 'firma_pkcs1_base64': base64.encode(r.signature!),
      if (r.signatureValid != null) 'verifica_locale': r.signatureValid,
      'testo_firmato': _sign ? _text.text : null,
      'durata_ms': r.durationMs,
    };
    return const JsonEncoder.withIndent('  ').convert(m);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('CIE Sign · prototipo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_nfcWarning != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text(_nfcWarning!)),
              ),
            Text(
              'Prototipo: il telefono legge il certificato dalla CIE e le fa firmare l\'impronta SHA-256 '
              'del testo qui sotto. Il PIN resta sul telefono e non viene salvato.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pin,
              enabled: !_busy,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'PIN della CIE (8 cifre)',
                helperText: 'Le prime 4 cifre dalla ricevuta, le ultime 4 dalla lettera con la carta',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Firma anche un\'impronta di prova'),
              subtitle: const Text('Se disattivato legge solo il certificato'),
              value: _sign,
              onChanged: _busy ? null : (v) => setState(() => _sign = v),
            ),
            if (_sign) ...[
              TextField(
                controller: _text,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Testo di prova', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              SelectableText('Impronta SHA-256: ${hex(_digest)}', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            if (!_busy)
              FilledButton.icon(
                onPressed: _pinValid && _nfcWarning == null ? _start : null,
                icon: const Icon(Icons.nfc),
                label: Text(_sign ? 'Leggi la CIE e firma' : 'Leggi il certificato'),
              )
            else
              OutlinedButton(onPressed: _cancel, child: const Text('Annulla')),
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Text(_status ?? '', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_errorText(_error!)),
                      if (_error!.trace != null && _error!.trace!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Dettagli tecnici'),
                          children: [
                            SelectableText(
                              _error!.trace!,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                            ),
                          ],
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.copy),
                          label: const Text('Copia i dettagli tecnici'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await Clipboard.setData(ClipboardData(text: '${_error!.message}\n\n${_error!.trace}'));
                            messenger.showSnackBar(const SnackBar(content: Text('Dettagli copiati')));
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            if (_result != null) ...[const SizedBox(height: 16), _resultCard(_result!, theme)],
          ],
        ),
      ),
    );
  }

  String _errorText(CieError e) {
    switch (e.code) {
      case 'WRONG_PIN':
        final n = e.remainingAttempts;
        if (n == 1) {
          return 'PIN errato. Resta un solo tentativo: un altro errore blocca la carta e servirà il PUK.';
        }
        return 'PIN errato. Tentativi rimasti: ${n ?? '?'}.';
      case 'PIN_BLOCKED':
        return 'Il PIN è bloccato. Si sblocca con il PUK tramite l\'app CieID o il Software CIE.';
      case 'CANCELLED':
        return 'Operazione annullata.';
      default:
        return e.message;
    }
  }

  Widget _resultCard(CieResult r, ThemeData theme) {
    final valid = r.signatureValid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (valid != null)
              Row(children: [
                Icon(valid ? Icons.verified : Icons.error, color: valid ? Colors.green : theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    valid ? 'Firma creata e verificata con il certificato' : 'La firma non corrisponde al certificato',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ]),
            if (valid == null) Text('Certificato letto', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('Titolare', r.subject),
            _row('Emittente', r.issuer),
            _row('Numero di serie', r.serial),
            _row('Validità', 'dal ${r.notBefore} al ${r.notAfter}'),
            _row('SHA-256 del certificato', hex(r.certSha256)),
            if (r.signature != null) _row('Firma (${r.signature!.length} byte)', hex(r.signature!)),
            _row('Durata', '${(r.durationMs / 1000).toStringAsFixed(1)} secondi'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copia il risultato per il PC'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: _export(r)));
                messenger.showSnackBar(const SnackBar(content: Text('Risultato copiato')));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      );
}
