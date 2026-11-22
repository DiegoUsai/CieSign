import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:crypto/crypto.dart';
import 'package:firmami_brand/firmami_brand.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'cie_bridge.dart';
import 'link_service.dart';
import 'local_sign.dart';
import 'pair_page.dart';
import 'request_page.dart';
import 'sign_file_page.dart';

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
  List<File> _signed = const [];

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
      _refreshSigned();
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

  Future<void> _refreshSigned() async {
    final list = await _store?.list() ?? const <File>[];
    if (mounted) setState(() => _signed = list);
  }

  Future<void> _signFile() async {
    final store = _store;
    if (store == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SignFilePage(bridge: _bridge, store: store, onCertificate: _link?.rememberCertificate),
      ),
    );
    await _refreshSigned();
  }

  void _openSigned(File f) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(f.uri.pathSegments.last, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              SignedFileActions(file: f),
            ],
          ),
        ),
      ),
    );
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
        title: const Text('Firmami · prototipo $_buildId'),
        actions: [
          if (link?.pc != null)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'pair') _scan();
                if (v == 'forget') link!.unpair();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pair', child: Text('Abbina un altro PC')),
                PopupMenuItem(value: 'forget', child: Text('Dimentica il PC')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_openError != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text(_openError!)),
              )
            else if (link == null)
              const Center(child: CircularProgressIndicator())
            else
              _linkCard(link, theme),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.draw_outlined),
                title: const Text('Firma un documento'),
                subtitle: const Text('Scegli un file dal telefono e firmalo con la CIE, senza PC'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _store == null ? null : _signFile,
              ),
            ),
            if (_signed.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Firmati sul telefono', style: theme.textTheme.titleSmall),
              for (final f in _signed.take(10))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(f.path.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf : Icons.description),
                  title: Text(f.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_when(f.lastModifiedSync())),
                  onTap: () => _openSigned(f),
                ),
            ],
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.badge),
                title: const Text('Prova la carta'),
                subtitle: Text(
                  link?.certificate != null
                      ? 'Certificato della CIE registrato sul telefono'
                      : 'Legge il certificato e lo registra per le firme dal PC',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PrototypePage(bridge: _bridge, onCertificate: link?.rememberCertificate),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkCard(PhoneLink link, ThemeData theme) {
    final pcName = link.pc?.device.name;
    final (IconData icon, Color? color, String title, String text) = switch (link.state) {
      LinkState.notPaired => (
        Icons.qr_code_scanner,
        null,
        'Nessun PC abbinato',
        'Sul PC apri Firmami, scegli "Abbina smartphone" e inquadra il QR code con il pulsante qui sotto'
            '.${link.remoteEnabled ? '' : ' Telefono e PC devono essere sulla stessa Wi-Fi.'}',
      ),
      LinkState.connected => (
        Icons.link,
        Colors.green,
        'Collegato a $pcName',
        '${link.viaInternet ? 'Via internet. ' : ''}In attesa di richieste dal PC. Tieni aperta l\'app durante la firma.',
      ),
      LinkState.connecting => (Icons.sync, null, 'Collegamento a $pcName…', ''),
      LinkState.disconnected => (
        Icons.link_off,
        theme.colorScheme.error,
        '$pcName non raggiungibile',
        link.remoteEnabled
            ? 'Controlla che Firmami sia aperto sul PC e che PC e telefono siano collegati a internet.'
            : 'Controlla che Firmami sia aperto sul PC e che i due dispositivi siano sulla stessa Wi-Fi.',
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ]),
            if (text.isNotEmpty) ...[const SizedBox(height: 8), Text(text)],
            if (link.state == LinkState.disconnected && link.lastError != null) ...[
              const SizedBox(height: 8),
              Text(link.lastError!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            if (link.state == LinkState.notPaired)
              FilledButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Abbina PC')),
            if (link.state == LinkState.disconnected && link.suggestInternet && !link.internetEnabled) ...[
              const Text(
                'Se il telefono non è sulla stessa rete del PC, per esempio in 4G o su un\'altra Wi-Fi, '
                'puoi collegarti via internet. Sul PC va attivata la stessa opzione.',
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  link.setInternetEnabled(true);
                  link.connect();
                },
                icon: const Icon(Icons.public),
                label: const Text('Non sono sulla stessa rete'),
              ),
              const SizedBox(height: 8),
            ],
            if (link.state == LinkState.disconnected)
              FilledButton.icon(onPressed: link.connect, icon: const Icon(Icons.refresh), label: const Text('Ricollega')),
            if (link.remoteAvailable && link.state != LinkState.notPaired)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Non sono sulla stessa rete'),
                subtitle: const Text('Collegamento via internet quando il PC non è sulla rete locale'),
                value: link.internetEnabled,
                onChanged: (v) {
                  link.setInternetEnabled(v);
                  if (v && link.state == LinkState.disconnected) link.connect();
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _when(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
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
