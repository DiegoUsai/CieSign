import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import 'link_service.dart';
import 'sign_workflow.dart';
import 'signature_box.dart';
import 'signed_history.dart';
import 'signers.dart';
import 'verification_panel.dart';

/// Vista di un documento: anteprima a sinistra, firma e verifica a destra.
class DocumentPage extends StatefulWidget {
  const DocumentPage({
    super.key,
    required this.doc,
    required this.link,
    required this.onOpen,
    this.history,
    this.developerMode = false,
    this.onPair,
  });

  /// Elenco dei documenti firmati, aggiornato a ogni firma salvata.
  final SignedHistory? history;

  /// Mostra gli strumenti di sviluppo, come la firma di prova.
  final bool developerMode;

  /// Apre l'abbinamento dello smartphone.
  final VoidCallback? onPair;

  final OpenedDocument doc;
  final LinkService? link;
  final void Function(OpenedDocument) onOpen;

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  late SignFormat _format;
  bool _visible = true;

  /// Riquadro della firma visibile in punti PDF, origine in basso a sinistra.
  VisibleSignature? _box;
  bool _useTestSigner = false;
  String? _status;
  bool _busy = false;
  List<SignatureReport>? _reports;
  CadesFile? _cades;
  String? _verifyError;
  bool _detached = false;
  String? _detachedName;

  final _pdf = rx.PdfViewerController();
  int _page = 1, _pageCount = 0;

  void _onViewerReady(rx.PdfDocument d, rx.PdfViewerController c) => setState(() => _pageCount = d.pages.length);

  void _onPageChanged(int? n) {
    if (n != null && n != _page) setState(() => _page = n);
  }

  void _goTo(int n) {
    if (_pageCount == 0) return;
    _pdf.goToPage(pageNumber: n.clamp(1, _pageCount), anchor: rx.PdfPageAnchor.top);
  }

  OpenedDocument get doc => widget.doc;

  @override
  void initState() {
    super.initState();
    _format = doc.kind == DocumentKind.pdf ? SignFormat.pades : SignFormat.cades;
    _useTestSigner = widget.link?.activeSession == null;
    _verify();
  }

  void _verify() {
    try {
      if (doc.kind == DocumentKind.pdf) {
        _reports = PadesVerifier.verify(doc.bytes);
      } else if (doc.kind == DocumentKind.p7m) {
        if (CmsSignedData.parse(doc.bytes).isDetached) {
          _detached = true;
          return;
        }
        _cades = CadesFile.open(doc.bytes);
        _reports = _cades!.reports;
      }
    } on Object catch (e) {
      _verifyError = '$e';
    }
  }

  /// Firma staccata (.p7s): serve il documento originale per verificarla.
  Future<void> _pickDetachedContent() async {
    final f = await openFile();
    if (f == null) return;
    final content = await File(f.path).readAsBytes();
    setState(() {
      _verifyError = null;
      try {
        _reports = CadesFile.open(doc.bytes, detachedContent: content).reports;
        _detachedName = f.name;
      } on Object catch (e) {
        _verifyError = '$e';
      }
    });
  }

  /// La firma di prova si usa solo in modalità sviluppatore.
  bool get _test => widget.developerMode && (_useTestSigner || widget.link == null);

  bool get _phoneReady => widget.link?.activeSession != null;

  CardSigner get _signer => _test ? TestSigner() : PhoneSigner(widget.link!);

  Future<void> _sign() async {
    if (_format == SignFormat.pades && _visible && _box == null) {
      setState(() => _status = 'Clicca sulla pagina dove vuoi la firma visibile.');
      return;
    }
    if (!_test && !_phoneReady) {
      setState(() => _status = 'Collega lo smartphone con l\'app CIE Sign per firmare.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final wf = SignWorkflow(_signer, link: _test ? null : widget.link);
      final r = await wf.run(
        doc,
        _format,
        visible: _format == SignFormat.pades && _visible ? _box : null,
        onStatus: (s) => setState(() => _status = s),
      );
      final dir = File(doc.path).parent.path;
      final loc = await getSaveLocation(suggestedName: r.suggestedName, initialDirectory: dir);
      if (loc == null) {
        setState(() => _status = 'Firma completata ma non salvata.');
        return;
      }
      await File(loc.path).writeAsBytes(r.bytes, flush: true);
      setState(() => _status = 'Documento firmato da ${r.holder} e salvato in ${loc.path}.');
      await widget.history?.add(
        SignedEntry(
          path: loc.path,
          signedAt: DateTime.now(),
          format: _format == SignFormat.pades ? 'PAdES' : 'CAdES',
          holder: r.holder,
          source: doc.path,
          test: _test,
        ),
      );
      widget.onOpen(OpenedDocument(loc.path, r.bytes));
    } on Object catch (e) {
      setState(() => _status = 'Firma non riuscita: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extract() async {
    final content = _cades!.content!;
    final name = CadesFile.unwrappedName(doc.name);
    final loc = await getSaveLocation(suggestedName: name, initialDirectory: File(doc.path).parent.path);
    if (loc == null) return;
    await File(loc.path).writeAsBytes(content, flush: true);
    widget.onOpen(OpenedDocument(loc.path, Uint8List.fromList(content)));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _preview()),
        const VerticalDivider(width: 1),
        SizedBox(width: 360, child: _sidePanel(context)),
      ],
    );
  }

  Widget _preview() {
    final bytes = doc.kind == DocumentKind.p7m ? _cades?.content : doc.bytes;
    final isPdf = bytes != null && bytes.length > 5 && String.fromCharCodes(bytes.sublist(0, 5)) == '%PDF-';
    if (!isPdf) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined, size: 96),
            const SizedBox(height: 12),
            Text(doc.name),
            Text('${(doc.bytes.length / 1024).toStringAsFixed(1)} KB'),
            const SizedBox(height: 8),
            const Text('Anteprima non disponibile per questo tipo di file.'),
          ],
        ),
      );
    }
    final placing = doc.kind == DocumentKind.pdf && _format == SignFormat.pades && _visible;
    return Column(
      children: [
        _pageBar(context),
        Expanded(child: _viewer(bytes, placing)),
      ],
    );
  }

  /// Barra di navigazione: numero di pagina, pagina precedente e successiva,
  /// prima e ultima, zoom. Lo scorrimento con rotellina e trascinamento resta.
  Widget _pageBar(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ready = _pageCount > 0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Prima pagina',
              onPressed: ready && _page > 1 ? () => _goTo(1) : null,
              icon: const Icon(Icons.first_page),
            ),
            IconButton(
              tooltip: 'Pagina precedente',
              onPressed: ready && _page > 1 ? () => _goTo(_page - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                ready ? 'Pagina $_page di $_pageCount' : 'Caricamento…',
                key: const ValueKey('numero-pagina'),
                style: t.bodyMedium,
              ),
            ),
            IconButton(
              tooltip: 'Pagina successiva',
              onPressed: ready && _page < _pageCount ? () => _goTo(_page + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: 'Ultima pagina',
              onPressed: ready && _page < _pageCount ? () => _goTo(_pageCount) : null,
              icon: const Icon(Icons.last_page),
            ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: 'Riduci',
              onPressed: ready ? () => _pdf.zoomDown() : null,
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              tooltip: 'Ingrandisci',
              onPressed: ready ? () => _pdf.zoomUp() : null,
              icon: const Icon(Icons.zoom_in),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewer(Uint8List bytes, bool placing) {
    return rx.PdfViewer.data(
      bytes,
      sourceName: '${doc.path}#${bytes.length}',
      controller: _pdf,
      params: rx.PdfViewerParams(
        backgroundColor: Colors.grey.shade300,
        pageOverlaysBuilder: placing ? _overlays : null,
        onViewerReady: _onViewerReady,
        onPageChanged: _onPageChanged,
      ),
    );
  }

  static const _previewLines = [
    'Firmato con CIE da',
    'Nome Cognome',
    'il gg/mm/aaaa alle hh:mm',
    'Firma elettronica avanzata',
  ];

  /// La rotellina sopra il riquadro va comunque al visualizzatore.
  void _forwardWheel(PointerSignalEvent e) =>
      GestureBinding.instance.pointerSignalResolver.register(e, _pdf.handlePointerSignalEvent);

  void _placeAt(int pageIndex, Size page, Offset center) {
    final prev = _box;
    setState(
      () => _box = SignatureBoxGeometry.centeredAt(
        center,
        pageIndex: pageIndex,
        page: page,
        width: prev?.width ?? SignatureBoxGeometry.defaultWidth,
        height: prev?.height ?? SignatureBoxGeometry.defaultHeight,
      ),
    );
  }

  void _editBox(Size page, Offset delta, Alignment? corner) {
    final b = _box;
    if (b == null || _busy) return;
    final r = SignatureBoxGeometry.toTopLeft(b, page);
    final next = corner == null
        ? SignatureBoxGeometry.move(r, delta, page)
        : SignatureBoxGeometry.resize(r, corner, delta, page);
    setState(() => _box = SignatureBoxGeometry.fromTopLeft(next, pageIndex: b.pageIndex, page: page));
  }

  /// Sovrapposizioni della pagina. Il clic sulla pagina passa da
  /// PdfOverlayInteractionRegion, che lascia al visualizzatore rotellina e
  /// trascinamento: un normale GestureDetector a tutta pagina bloccava lo
  /// scorrimento dell'anteprima.
  List<Widget> _overlays(BuildContext context, Rect pageRect, rx.PdfPage page) {
    final scale = pageRect.width / page.width;
    final idx = page.pageNumber - 1;
    final size = Size(page.width, page.height);
    final box = _box;
    final rotated = page.rotation != rx.PdfPageRotation.none;
    return [
      Positioned.fill(
        child: MouseRegion(
          opaque: false,
          cursor: rotated ? SystemMouseCursors.forbidden : SystemMouseCursors.precise,
          child: rx.PdfOverlayInteractionRegion(
            onTap: (d) {
              if (rotated || _busy) return false;
              _placeAt(idx, size, d.localPosition / scale);
              return true;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
      if (box != null && box.pageIndex == idx)
        Builder(
          builder: (context) {
            final r = SignatureBoxGeometry.toTopLeft(box, size);
            return Positioned(
              left: r.left * scale,
              top: r.top * scale,
              width: r.width * scale,
              height: r.height * scale,
              child: SignatureBoxEditor(
                rect: r,
                scale: scale,
                lines: _previewLines,
                onChanged: (delta, corner) => _editBox(size, delta, corner),
                onPointerSignal: _forwardWheel,
              ),
            );
          },
        ),
    ];
  }

  Widget _sidePanel(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final phoneReady = widget.link?.activeSession != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(doc.name, style: t.titleMedium),
        const SizedBox(height: 16),
        Text('Verifica delle firme', style: t.titleSmall),
        const SizedBox(height: 8),
        if (_detached) ...[
          Text(
            _detachedName == null
                ? 'È una firma staccata: per verificarla serve anche il documento firmato.'
                : 'Firma staccata verificata sul documento $_detachedName.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickDetachedContent,
            icon: const Icon(Icons.attach_file),
            label: Text(_detachedName == null ? 'Scegli il documento originale' : 'Scegli un altro documento'),
          ),
          const SizedBox(height: 8),
        ],
        if (_verifyError != null)
          Text('Impossibile leggere le firme: $_verifyError', style: t.bodySmall)
        else if (!_detached || _reports != null)
          VerificationPanel(reports: _reports ?? const [], documentName: doc.name, pades: doc.kind == DocumentKind.pdf),
        if (_cades?.content != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _extract,
            icon: const Icon(Icons.unarchive_outlined),
            label: const Text('Estrai il documento originale'),
          ),
        ],
        const Divider(height: 32),
        Text('Firma', style: t.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<SignFormat>(
          segments: [
            ButtonSegment(value: SignFormat.pades, label: const Text('PAdES'), enabled: doc.kind == DocumentKind.pdf),
            const ButtonSegment(value: SignFormat.cades, label: Text('CAdES (.p7m)')),
          ],
          selected: {_format},
          onSelectionChanged: _busy ? null : (s) => setState(() => _format = s.first),
        ),
        if (_format == SignFormat.pades) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Firma visibile'),
            subtitle: Text(
              _visible
                  ? (_box == null
                        ? 'Clicca sulla pagina per posizionare il riquadro.'
                        : 'Pagina ${_box!.pageIndex + 1}. Trascina il riquadro per spostarlo, '
                              'trascina gli angoli per ridimensionarlo, clicca su un\'altra pagina per portarlo lì.')
                  : 'La firma non comparirà nella pagina.',
            ),
            value: _visible,
            onChanged: _busy ? null : (v) => setState(() => _visible = v),
          ),
        ],
        const SizedBox(height: 8),
        if (widget.developerMode)
          RadioGroup<bool>(
            groupValue: _useTestSigner,
            onChanged: (v) => _busy ? null : setState(() => _useTestSigner = v ?? false),
            child: Column(
              children: [
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  enabled: phoneReady,
                  title: const Text('CIE tramite smartphone'),
                  subtitle: Text(
                    phoneReady ? 'Collegato: ${widget.link!.activeSession!.peerName}' : 'Nessuno smartphone collegato',
                  ),
                ),
                const RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  value: true,
                  title: Text('Firma di prova (sviluppo)'),
                  subtitle: Text('Chiave inclusa nell\'app, nessun valore legale. Serve solo a provare il flusso.'),
                ),
              ],
            ),
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              phoneReady ? Icons.smartphone : Icons.phonelink_off,
              color: phoneReady ? Colors.green.shade700 : null,
            ),
            title: Text(
              phoneReady
                  ? 'Firma con la CIE tramite ${widget.link!.activeSession!.peerName}'
                  : 'Smartphone non collegato',
            ),
            subtitle: Text(
              phoneReady
                  ? 'Alla pressione di Firma, il telefono chiede il PIN e la CIE.'
                  : 'Apri CIE Sign sul telefono, sulla stessa rete Wi-Fi, oppure abbinalo.',
            ),
            trailing: phoneReady || widget.onPair == null
                ? null
                : TextButton(onPressed: widget.onPair, child: const Text('Abbina')),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy || (!_test && !phoneReady) ? null : _sign,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.draw_outlined),
          label: Text(_busy ? 'Firma in corso…' : 'Firma'),
        ),
        if (_status != null) ...[const SizedBox(height: 12), Text(_status!, style: t.bodyMedium)],
        const SizedBox(height: 24),
        Text(
          'La firma con CIE è una firma elettronica avanzata (FEA): vale per la maggior parte degli usi '
          'tra privati, ma non è una firma digitale qualificata. Altri programmi di verifica la segnalano '
          'come non qualificata.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}
