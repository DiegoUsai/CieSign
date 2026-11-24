import 'dart:io';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart' show SignFormat;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;
import 'package:share_plus/share_plus.dart';

import 'cie_bridge.dart';
import 'local_sign.dart';
import 'pin_unlock.dart';

/// Firma di un documento sul telefono, senza PC (UC11): scelta del file,
/// formato, posizione della firma visibile, PIN e CIE.
class SignFilePage extends StatefulWidget {
  const SignFilePage({super.key, required this.bridge, required this.store, this.onCertificate, this.initial, this.onSigned});

  final CieBridge bridge;
  final SignedStore store;

  /// Riceve il certificato letto, che il telefono ricorda anche per le firme dal PC.
  final void Function(Uint8List)? onCertificate;

  /// Documento già scelto (dalla pagina del documento o nei test).
  final LocalDocument? initial;

  /// Chiamata dopo il salvataggio del file firmato, per le marcature e i Recenti.
  final Future<void> Function(File file, Uint8List bytes, String holder, SignFormat format)? onSigned;

  @override
  State<SignFilePage> createState() => _SignFilePageState();
}

class _SignFilePageState extends State<SignFilePage> {
  LocalDocument? _doc;
  SignFormat _format = SignFormat.pades;
  bool _visible = true;
  VisibleSignature? _box;
  int _existingSignatures = 0;
  String? _hint;

  static const _boxW = 200.0, _boxH = 64.0;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) _setDoc(widget.initial!);
  }

  void _setDoc(LocalDocument d) {
    _doc = d;
    _box = null;
    _hint = null;
    _format = d.isPdf && !d.isP7m ? SignFormat.pades : SignFormat.cades;
    _existingSignatures = 0;
    try {
      if (d.isP7m) {
        _existingSignatures = CadesFile.open(d.bytes).reports.length;
      } else if (d.isPdf) {
        _existingSignatures = PadesVerifier.verify(d.bytes).length;
      }
    } on Object {
      // Il conteggio è solo informativo: un file illeggibile si firma lo stesso in CAdES.
    }
  }

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Scegli il documento da firmare');
    if (f == null) return;
    final bytes = await f.readAsBytes();
    setState(() => _setDoc(LocalDocument(f.name, bytes)));
  }

  bool get _placing => _doc != null && _format == SignFormat.pades && _visible;

  bool _onTap(BuildContext context, rx.PdfViewerController c, rx.PdfViewerGeneralTapHandlerDetails d) {
    if (!_placing || d.type != rx.PdfViewerGeneralTapType.tap) return false;
    final hit = c.getPdfPageHitTestResult(d.documentPosition, useDocumentLayoutCoordinates: true);
    if (hit == null) return false;
    final page = hit.page;
    if (page.rotation != rx.PdfPageRotation.none) {
      setState(() => _hint = 'Su una pagina ruotata la firma visibile non è ancora supportata.');
      return true;
    }
    // Il tocco è il centro del riquadro; coordinate PDF con origine in basso a sinistra.
    final x = (hit.offset.x - _boxW / 2).clamp(0.0, page.width - _boxW);
    final y = (hit.offset.y - _boxH / 2).clamp(0.0, page.height - _boxH);
    setState(() {
      _hint = null;
      _box = VisibleSignature(pageIndex: page.pageNumber - 1, x: x, y: y, width: _boxW, height: _boxH);
    });
    return true;
  }

  /// Margine attorno al riquadro per cestino e maniglia, che sporgono dagli angoli.
  static const _pad = 18.0;
  static const _minW = 90.0, _minH = 32.0;

  /// Sposta il riquadro di [dx], [dy] pixel dello schermo, restando dentro la pagina.
  void _moveBox(rx.PdfPage page, double scale, Offset delta) {
    final b = _box;
    if (b == null) return;
    setState(() {
      _box = VisibleSignature(
        pageIndex: b.pageIndex,
        // Coordinate PDF: origine in basso a sinistra, quindi la y va al contrario.
        x: (b.x + delta.dx / scale).clamp(0.0, page.width - b.width),
        y: (b.y - delta.dy / scale).clamp(0.0, page.height - b.height),
        width: b.width,
        height: b.height,
      );
    });
  }

  /// Ridimensiona dall'angolo in basso a destra, tenendo fermo l'angolo in alto a sinistra.
  void _resizeBox(rx.PdfPage page, double scale, Offset delta) {
    final b = _box;
    if (b == null) return;
    final top = b.y + b.height;
    final w = (b.width + delta.dx / scale).clamp(_minW, page.width - b.x);
    final h = (b.height + delta.dy / scale).clamp(_minH, top);
    setState(() {
      _box = VisibleSignature(pageIndex: b.pageIndex, x: b.x, y: top - h, width: w, height: h);
    });
  }

  void _removeBox() => setState(() {
    _box = null;
    _hint = null;
  });

  List<Widget> _overlays(BuildContext context, Rect pageRect, rx.PdfPage page) {
    final box = _box;
    if (!_placing || box == null || box.pageIndex != page.pageNumber - 1) return const [];
    final scale = pageRect.width / page.width;
    return [
      Positioned(
        left: box.x * scale - _pad,
        top: (page.height - box.y - box.height) * scale - _pad,
        width: box.width * scale + 2 * _pad,
        height: box.height * scale + 2 * _pad,
        child: Stack(
          children: [
            // Il riquadro si trascina con il dito.
            Positioned.fill(
              left: _pad,
              top: _pad,
              right: _pad,
              bottom: _pad,
              child: GestureDetector(
                key: const Key('riquadro-firma'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => _moveBox(page, scale, d.delta),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0x220066CC),
                    border: Border.all(color: const Color(0xFF0066CC), width: 1.5),
                  ),
                  padding: EdgeInsets.all(3 * scale),
                  child: FittedBox(
                    alignment: Alignment.topLeft,
                    child: Text(
                      'Firmato con CIE da\nNome Cognome\nil gg/mm/aaaa alle hh:mm\nFirma elettronica avanzata',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade900, height: 1.25),
                    ),
                  ),
                ),
              ),
            ),
            // Cestino nell'angolo in alto a destra (proposta A scelta da Diego).
            Positioned(
              right: 0,
              top: 0,
              child: Semantics(
                button: true,
                label: 'Elimina il riquadro della firma',
                child: GestureDetector(
                  key: const Key('cestino-firma'),
                  onTap: _removeBox,
                  child: Container(
                    width: 2 * _pad,
                    height: 2 * _pad,
                    decoration: const BoxDecoration(
                      color: Color(0xFFD93025),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Color(0x55000000), blurRadius: 3, offset: Offset(0, 1))],
                    ),
                    child: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
            // Maniglia in basso a destra per ridimensionare.
            Positioned(
              right: _pad - 11,
              bottom: _pad - 11,
              child: GestureDetector(
                key: const Key('maniglia-firma'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => _resizeBox(page, scale, d.delta),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0066CC),
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _sign() async {
    final doc = _doc!;
    if (_placing && _box == null) {
      setState(() => _hint = 'Tocca la pagina nel punto in cui vuoi la firma, oppure disattiva la firma visibile.');
      return;
    }
    final out = await showModalBottomSheet<_Signed>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _CieSheet(
        bridge: widget.bridge,
        doc: doc,
        format: _format,
        visible: _placing ? _box : null,
      ),
    );
    if (out == null || !mounted) return;
    widget.onCertificate?.call(out.certificate);
    final file = await widget.store.save(
      LocalSigner.signedName(doc.name, _format, cosign: LocalSigner.isCosign(doc, _format)),
      out.bytes,
    );
    await widget.onSigned?.call(file, out.bytes, out.holder, _format);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => SignedPage(file: file, holder: out.holder)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: Text(doc?.name ?? 'Apri un documento', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (doc != null) IconButton(tooltip: 'Scegli un altro file', onPressed: _pick, icon: const Icon(Icons.folder_open)),
        ],
      ),
      body: SafeArea(
        child: doc == null ? _empty(theme) : _withDocument(doc, theme),
      ),
    );
  }

  Widget _empty(ThemeData theme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.description_outlined, size: 72),
          const SizedBox(height: 16),
          Text(
            'Scegli un PDF o un altro file dal telefono: lo firmi qui con la CIE, senza PC.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.folder_open), label: const Text('Scegli un file')),
        ],
      ),
    ),
  );

  Widget _withDocument(LocalDocument doc, ThemeData theme) {
    final canPades = doc.isPdf && !doc.isP7m;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                [
                  _size(doc.bytes.length),
                  if (_existingSignatures > 0)
                    _existingSignatures == 1 ? 'contiene già 1 firma' : 'contiene già $_existingSignatures firme',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              SegmentedButton<SignFormat>(
                segments: [
                  ButtonSegment(value: SignFormat.pades, label: const Text('PAdES (PDF)'), enabled: canPades),
                  const ButtonSegment(value: SignFormat.cades, label: Text('CAdES (.p7m)')),
                ],
                selected: {_format},
                onSelectionChanged: (s) => setState(() => _format = s.first),
              ),
              if (_format == SignFormat.pades)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Firma visibile'),
                  subtitle: Text(
                    !_visible
                        ? 'La firma non comparirà nella pagina.'
                        : _box == null
                            ? 'Tocca la pagina dove vuoi il riquadro.'
                            : 'Pagina ${_box!.pageIndex + 1}. Trascinalo per spostarlo, usa la maniglia per ridimensionarlo o il cestino per toglierlo.',
                  ),
                  value: _visible,
                  onChanged: (v) => setState(() => _visible = v),
                ),
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_hint!, style: TextStyle(color: theme.colorScheme.error)),
                ),
            ],
          ),
        ),
        Expanded(child: _preview(doc)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _sign,
            icon: const Icon(Icons.draw_outlined),
            label: const Text('Firma con la CIE'),
          ),
        ),
      ],
    );
  }

  Widget _preview(LocalDocument doc) {
    if (!doc.isPdf || doc.isP7m) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            LocalSigner.isCosign(doc, _format)
                ? 'La tua firma si aggiunge a quelle della busta (firma parallela CAdES): il file resta un unico .p7m.'
                : 'Anteprima non disponibile per questo tipo di file: verrà firmato in CAdES e salvato come .p7m.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ColoredBox(
      color: Colors.grey.shade300,
      child: rx.PdfViewer.data(
        doc.bytes,
        sourceName: '${doc.name}#${doc.bytes.length}',
        params: rx.PdfViewerParams(
          backgroundColor: Colors.grey.shade300,
          onGeneralTap: _onTap,
          pageOverlaysBuilder: _overlays,
        ),
      ),
    );
  }
}

class _Signed {
  _Signed(this.bytes, this.certificate, this.holder);
  final Uint8List bytes;
  final Uint8List certificate;
  final String holder;
}

/// Foglio con PIN e lettura della CIE: certificato, preparazione e firma
/// avvengono nella stessa sessione, quindi la carta si avvicina una volta.
class _CieSheet extends StatefulWidget {
  const _CieSheet({required this.bridge, required this.doc, required this.format, this.visible});

  final CieBridge bridge;
  final LocalDocument doc;
  final SignFormat format;
  final VisibleSignature? visible;

  @override
  State<_CieSheet> createState() => _CieSheetState();
}

class _CieSheetState extends State<_CieSheet> with PinUnlockMixin {
  @override
  CieBridge get pinBridge => widget.bridge;

  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.bridge.onStatus = (s) {
      if (mounted) setState(() => _status = s);
    };
  }

  @override
  void dispose() {
    widget.bridge.onStatus = null;
    super.dispose();
  }

  Future<void> _start() async {
    final nfc = await widget.bridge.nfcStatus();
    if (!nfc.available || !nfc.enabled) {
      setState(() => _error = !nfc.available
          ? 'Questo telefono non ha l\'NFC: non può leggere la CIE.'
          : 'L\'NFC è disattivato: attivalo nelle impostazioni e riprova.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Avvicina la CIE al retro del telefono';
    });
    PreparedSignature? prepared;
    try {
      final r = await widget.bridge.startWithPreparation(
        pin: takePin(),
        prepare: (cert) async {
          prepared = LocalSigner.prepare(widget.doc, widget.format, cert, visible: widget.visible);
          return prepared!.digestToSign;
        },
      );
      final p = prepared;
      if (p == null || r.signature == null) throw LocalSignException('La carta non ha restituito la firma.');
      final bytes = p.finish(r.signature!);
      final note = await rememberPinIfWanted();
      if (note != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
      if (mounted) Navigator.of(context).pop(_Signed(bytes, r.certificate, p.certificate.holderName));
    } on CieError catch (e) {
      final vaultText = vaultErrorText(e);
      if (mounted) setState(() => _error = vaultText ?? _errorText(e));
    } on LocalSignException catch (e) {
      if (mounted) setState(() => _error = e.message);
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
    'PREPARE_FAILED' => e.message,
    _ => e.message,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Firma con la CIE', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '${widget.doc.name} · ${widget.format == SignFormat.pades ? 'PAdES' : 'CAdES'}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          pinInput(context, busy: _busy),
          if (!_busy) ...[
            FilledButton.icon(
              onPressed: pinReady ? _start : null,
              icon: const Icon(Icons.nfc),
              label: const Text('Firma'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annulla')),
          ] else ...[
            const SizedBox(height: 8),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            Text(_status ?? '', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: widget.bridge.cancel, child: const Text('Annulla')),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            pinFootnote,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Esito della firma: il file è già salvato nell'app e si può condividere o
/// salvare altrove.
class SignedPage extends StatelessWidget {
  const SignedPage({super.key, required this.file, this.holder});

  final File file;
  final String? holder;

  String get _name => file.uri.pathSegments.last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Documento firmato')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              const Icon(Icons.verified, color: Colors.green, size: 32),
              const SizedBox(width: 12),
              Expanded(child: Text(_name, style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 8),
            if (holder != null) Text('Firmato con la CIE di $holder.'),
            const Text('Una copia resta nell\'elenco dei documenti firmati di questa app.'),
            const SizedBox(height: 24),
            SignedFileActions(file: file),
          ],
        ),
      ),
    );
  }
}

/// Condivisione e salvataggio di un documento firmato.
class SignedFileActions extends StatelessWidget {
  const SignedFileActions({super.key, required this.file});

  final File file;

  String get _name => file.uri.pathSegments.last;

  String get _mime => _name.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'application/pkcs7-mime';

  Future<void> _share() =>
      SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: _mime)], subject: _name));

  Future<void> _saveAs(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = await FilePicker.saveFile(fileName: _name, bytes: await file.readAsBytes(), mimeType: _mime);
    if (uri != null) messenger.showSnackBar(const SnackBar(content: Text('Documento salvato')));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FilledButton.icon(onPressed: _share, icon: const Icon(Icons.share), label: const Text('Condividi')),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => _saveAs(context),
        icon: const Icon(Icons.save_alt),
        label: const Text('Salva in…'),
      ),
    ],
  );
}

String _size(int b) =>
    b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
