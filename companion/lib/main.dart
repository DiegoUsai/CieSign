import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_docset/ciesign_docset.dart' show FileSource;
import 'package:ciesign_link/ciesign_link.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firmami_brand/firmami_brand.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'cie_bridge.dart';
import 'link_service.dart';
import 'local_sign.dart';
import 'pair_page.dart';
import 'recents_page.dart';
import 'settings_page.dart';
import 'request_page.dart';
import 'document_page.dart';
import 'workspace.dart';

void main() => runApp(const CieSignCompanionApp());

/// Identificativo della build, passato dal workflow con --dart-define (vedi android-prototipo.yml).
const _buildId = String.fromEnvironment('BUILD_ID', defaultValue: 'locale');

ThemeData _theme(Brightness b) =>
    ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: FirmamiColors.red, brightness: b));

class CieSignCompanionApp extends StatelessWidget {
  const CieSignCompanionApp({super.key, this.home});

  /// Pagina iniziale alternativa, usata nei test.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FirmamiColors.appName,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      // Lo splash animato parte solo nell'app vera; i test passano [home].
      home: home ?? const SplashGate(child: HomePage()),
    );
  }
}

/// Schermata principale: stato del collegamento con il PC e richieste in arrivo.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _bridge = CieBridge();
  PhoneLink? _link;
  String? _openError;
  StreamSubscription<LinkMessage>? _requests;
  Timer? _retry;
  bool _requestOpen = false;
  bool _foreground = true;
  SignedStore? _store;
  MobileWorkspace? _ws;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bridge.onLink = _onLink;
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _requests?.cancel();
    _link?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _store = SignedStore(Directory('${(await getApplicationDocumentsDirectory()).path}/firmati'));
      final ws = await MobileWorkspace.open();
      if (mounted) setState(() => _ws = ws);
      final link = await PhoneLink.open(dir, deviceName: await _bridge.deviceName());
      link.addListener(() {
        if (mounted) setState(() {});
      });
      _requests = link.requests.listen(_onRequest);
      setState(() => _link = link);
      link.connect();
      // Finché l'app è in primo piano, prova a ricollegarsi al PC ogni 10 secondi.
      _retry = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_foreground && link.state == LinkState.disconnected) link.connect();
      });
      final initial = await _bridge.initialLink();
      if (initial != null) _onLink(initial);
    } on Object catch (e) {
      setState(() => _openError = '$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _link?.connect();
  }

  /// Link ciesign://pair arrivato da fuori dell'app. Il filtro non è più
  /// BROWSABLE, quindi pagine web, email e SMS non lo aprono; resta comunque
  /// una conferma esplicita, perché un'altra app può inviarlo.
  void _onLink(String uri) {
    try {
      _pair(PairingOffer.parse(uri), fromLink: true);
    } on FormatException catch (e) {
      _snack('QR code non valido: ${e.message}');
    }
  }

  Future<void> _scan() async {
    final offer = await Navigator.of(context).push<PairingOffer>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (offer != null) await _pair(offer);
  }

  Future<void> _pair(PairingOffer offer, {bool fromLink = false}) async {
    final link = _link;
    if (link == null) return;
    final current = link.pc?.device.name;
    if (fromLink || current != null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Abbinare un nuovo PC?'),
          content: Text(
            '${fromLink ? 'Procedi solo se hai appena inquadrato il QR code sullo schermo del tuo PC. ' : ''}'
            '${current != null ? 'Il PC abbinato ora, $current, verrà sostituito da ${offer.pcName}.' : 'Il PC si presenta come ${offer.pcName}.'}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annulla')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Abbina')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PairPage(link: link, offer: offer)),
    );
    if (ok == true) _snack('PC abbinato: ${link.pc?.device.name}');
    if (ok == false) _snack('Abbinamento annullato');
  }

  Future<void> _onRequest(LinkMessage m) async {
    final link = _link!;
    if (m is Cancel) return; // gestito dalla pagina della richiesta
    if (m is CertificateRequest && link.certificate != null) {
      await link.send(CertificateResponse(link.certificate!));
      _snack('Certificato della CIE inviato al PC');
      return;
    }
    if (_requestOpen) {
      if (m is SignRequest) {
        await link.send(SignError(m.id, 'BUSY', 'Il telefono sta già gestendo un\'altra richiesta'));
      }
      return;
    }
    _requestOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RequestPage(
          link: link,
          bridge: _bridge,
          request: m,
          cancels: link.requests.where((r) => r is Cancel).cast<Cancel>(),
        ),
      ),
    );
    _requestOpen = false;
    if (mounted) setState(() {});
  }

  /// Apre uno o più documenti: uno solo va subito alla sua pagina, più di uno
  /// formano un fascicolo da scorrere, verificare e firmare uno per volta.
  Future<void> _openDocument() async {
    final ws = _ws;
    if (ws == null) return;
    final files = await FilePicker.pickFiles(dialogTitle: 'Apri uno o più documenti');
    if (files.isEmpty || !mounted) return;
    await ws.openFiles([for (final f in files) (name: f.name, read: f.readAsBytes)]);
    if (mounted) await _showWork();
  }

  Future<void> _resume() async {
    final ws = _ws;
    if (ws == null) return;
    await ws.resume();
    if (mounted) await _showWork();
  }

  Future<void> _showWork() async {
    final ws = _ws!;
    if (ws.set.items.length == 1) {
      await _openAt(0);
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DossierPage(ws: ws, openDocument: _openAt)));
    }
    if (mounted) setState(() {});
  }

  Future<void> _openAt(int index) async {
    final ws = _ws!;
    final store = _store;
    if (store == null) return;
    unawaited(ws.select(index));
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DocumentPage(ws: ws, bridge: _bridge, signedStore: store, onCertificate: _link?.rememberCertificate),
      ),
    );
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsPage(
        bridge: _bridge,
        link: _link,
        onScan: _scan,
        buildId: _buildId,
        openPrototype: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PrototypePage(bridge: _bridge, onCertificate: _link?.rememberCertificate)),
        ),
      ),
    ),
  );

  void _openRecents() {
    final ws = _ws;
    if (ws != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecentsPage(ws: ws, openFile: _openPath)));
  }

  /// Riapre un file dei Recenti nella pagina del documento.
  Future<void> _openPath(String path) async {
    final ws = _ws;
    if (ws == null || !File(path).existsSync()) return;
    ws.set.clear();
    ws.set.add([FileSource(path)]);
    await _openAt(0);
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = _link;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmami'),
        actions: [
          if (link != null) PcStatusIcon(link: link, onTap: _openSettings),
          IconButton(tooltip: 'Recenti', onPressed: _ws == null ? null : _openRecents, icon: const Icon(Icons.history)),
          IconButton(tooltip: 'Impostazioni', onPressed: _openSettings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_openError != null)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_openError!)),
                  ),
                Icon(Icons.description_outlined, size: 96, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Apri un documento per vederlo, controllare le firme che contiene e firmarlo con la CIE.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: _ws == null ? null : _openDocument,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Apri un documento'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Puoi sceglierne anche più di uno, per esempio tutti i documenti di una gara.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                if (_ws != null && _ws!.resumable.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.history_edu),
                      title: const Text('Riprendi il lavoro'),
                      subtitle: Text(
                        _ws!.resumable.length == 1 ? '1 documento aperto l\'ultima volta' : '${_ws!.resumable.length} documenti aperti l\'ultima volta',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _resume,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Schermata del prototipo: legge il certificato dalla CIE e firma un'impronta di prova.
class PrototypePage extends StatefulWidget {
  const PrototypePage({super.key, required this.bridge, this.onCertificate});

  final CieBridge bridge;

  /// Riceve il certificato letto, che il telefono ricorda per le firme dal PC.
  final void Function(Uint8List)? onCertificate;

  @override
  State<PrototypePage> createState() => _PrototypePageState();
}

class _PrototypePageState extends State<PrototypePage> {
  CieBridge get _bridge => widget.bridge;
  final _pin = TextEditingController();
  final _text = TextEditingController(text: 'Prova di firma con Firmami');

  bool _busy = false;
  bool _sign = true;
  String? _status;
  String? _nfcWarning;
  CieResult? _result;
  CieError? _error;

  @override
  void initState() {
    super.initState();
    _bridge.onStatus = (s) {
      if (mounted) setState(() => _status = s);
    };
    _checkNfc();
  }

  @override
  void dispose() {
    _bridge.onStatus = null;
    _pin.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _checkNfc() async {
    final s = await _bridge.nfcStatus();
    if (!mounted) return;
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
      widget.onCertificate?.call(r.certificate);
    } on CieError catch (e) {
      setState(() => _error = e);
      // Dopo un PIN errato lo si cancella, così un secondo tentativo è sempre voluto.
      if (e.code == 'WRONG_PIN' || e.code == 'PIN_BLOCKED') _pin.clear();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
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
      appBar: AppBar(title: const Text('Prova la carta')),
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
