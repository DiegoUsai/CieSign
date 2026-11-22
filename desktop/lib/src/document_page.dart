import 'dart:convert';
import 'dart:io';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_docset/ciesign_docset.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import 'document_list.dart';
import 'link_service.dart';
import 'sign_workflow.dart';
import 'signature_box.dart';
import 'signers.dart';
import 'thumbnails.dart';
import 'verification_panel.dart';
import 'workspace.dart';

/// Vista del documento selezionato: miniature e anteprima al centro, a
/// destra esito della verifica, contenuto (per .p7m, zip e allegati) e firma.
class DocumentPage extends StatefulWidget {
  const DocumentPage({
    super.key,
    required this.ws,
    required this.item,
    required this.link,
    this.developerMode = false,
    this.onPair,
  });

  final Workspace ws;
  final DocItem item;
  final LinkService? link;

  /// Mostra gli strumenti di sviluppo, come la firma di prova.
  final bool developerMode;

  /// Apre l'abbinamento dello smartphone.
  final VoidCallback? onPair;

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
  bool _thumbs = true;

  /// Firma staccata (.p7s) verificata su un documento scelto dall'utente.
  List<SignatureReport>? _detachedReports;
  String? _detachedName;

  final _pdf = rx.PdfViewerController();
  final _focus = FocusNode(debugLabel: 'documento');
  int _page = 1, _pageCount = 0;

  Workspace get ws => widget.ws;
  DocItem get item => widget.item;
  ContainedFile get root => item.tree!;

  @override
  void initState() {
    super.initState();
    _format = Unwrapper.detectKind(item.name, root.bytes) == ContentKind.pdf ? SignFormat.pades : SignFormat.cades;
    _useTestSigner = widget.link?.activeSession == null;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onViewerReady(rx.PdfDocument d, rx.PdfViewerController c) => setState(() => _pageCount = d.pages.length);

  void _onPageChanged(int? n) {
    if (n != null && n != _page) setState(() => _page = n);
  }

  void _goTo(int n) {
    if (_pageCount == 0) return;
    _pdf.goToPage(pageNumber: n.clamp(1, _pageCount), anchor: rx.PdfPageAnchor.top);
  }

  bool get _isDetached => root.kind == ContentKind.p7m && root.children.isEmpty && (root.signatureError?.contains('staccata') ?? false);

  /// Firma staccata (.p7s): serve il documento originale per verificarla.
  Future<void> _pickDetachedContent() async {
    final f = await openFile();
    if (f == null) return;
    final content = await File(f.path).readAsBytes();
    setState(() {
      try {
        _detachedReports = CadesFile.open(root.bytes, detachedContent: content).reports;
        _detachedName = f.name;
        _status = null;
      } on Object catch (e) {
        _status = 'Verifica non riuscita: $e';
      }
    });
  }

  /// La firma di prova si usa solo in modalità sviluppatore.
  bool get _test => widget.developerMode && (_useTestSigner || widget.link == null);

  bool get _phoneReady => widget.link?.activeSession != null;

  CardSigner get _signer => _test ? TestSigner() : PhoneSigner(widget.link!);

  OpenedDocument get _opened => OpenedDocument(item.source.id, root.bytes);

  bool get _cosign => SignWorkflow.isCosign(_opened, _format);

  void _deleteBox() {
    if (_box == null || _busy) return;
    setState(() => _box = null);
  }

  /// Prima di firmare avvisa, senza bloccare, se ci sono file non ancora aperti.
  Future<bool> _confirmUnviewed() async {
    final unviewed = ws.set.unviewedFiles(item);
    if (unviewed.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.visibility_off_outlined),
        title: const Text('Non hai ancora aperto tutti i file'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                unviewed.length == 1
                    ? 'Questo file non è stato ancora visualizzato:'
                    : 'Questi ${unviewed.length} file non sono stati ancora visualizzati:',
              ),
              const SizedBox(height: 8),
              for (final f in unviewed.take(8)) Text('•  ${f.name}'),
              if (unviewed.length > 8) Text('… e altri ${unviewed.length - 8}'),
              const SizedBox(height: 12),
              const Text('Puoi firmare comunque, ma è consigliato leggere tutto prima.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Torna ai file')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Firma comunque')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _sign() async {
    if (_format == SignFormat.pades && _visible && _box == null) {
      setState(() => _status = 'Clicca sulla pagina dove vuoi la firma visibile.');
      return;
    }
    if (!_test && !_phoneReady) {
      setState(() => _status = 'Collega lo smartphone con l\'app CIE Sign per firmare.');
      return;
    }
    if (!await _confirmUnviewed()) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final wf = SignWorkflow(_signer, link: _test ? null : widget.link);
      final r = await wf.run(
        _opened,
        _format,
        visible: _format == SignFormat.pades && _visible ? _box : null,
        onStatus: (s) => setState(() => _status = s),
      );
      final src = File(item.source.id);
      final loc = await getSaveLocation(suggestedName: r.suggestedName, initialDirectory: src.parent.path);
      if (loc == null) {
        setState(() => _status = 'Firma completata ma non salvata.');
        return;
      }
      await File(loc.path).writeAsBytes(r.bytes, flush: true);
      if (!mounted) return;
      setState(() => _status = 'Documento firmato da ${r.holder} e salvato in ${loc.path}.');
      await ws.signed(
        item,
        loc.path,
        fingerprintOut: sha256.convert(r.bytes).toString(),
        format: _format == SignFormat.pades ? 'PAdES' : 'CAdES',
        holder: r.holder,
        test: _test,
      );
    } on Object catch (e) {
      if (mounted) setState(() => _status = 'Firma non riuscita: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCopy(ContainedFile f) async {
    final loc = await getSaveLocation(suggestedName: f.name, initialDirectory: File(item.source.id).parent.path);
    if (loc == null) return;
    await File(loc.path).writeAsBytes(f.bytes, flush: true);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Salvato in ${loc.path}')));
  }

  Future<void> _openFile(ContainedFile f) async {
    if (f.kind.hasPreview) {
      ws.view(item, f);
      setState(() {
        _page = 1;
        _pageCount = 0;
      });
    } else {
      try {
        await ws.openExternal(item, f);
      } on Object catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Impossibile aprire il file: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): _deleteBox,
        const SingleActivator(LogicalKeyboardKey.backspace): _deleteBox,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _preview(context)),
            const VerticalDivider(width: 1),
            SizedBox(width: 380, child: _sidePanel(context)),
          ],
        ),
      ),
    );
  }

  Widget _preview(BuildContext context) {
    final f = ws.viewing ?? root.innermost;
    if (f.kind == ContentKind.image) {
      return Column(
        children: [
          _fileBar(context, f),
          Expanded(child: InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(f.bytes)))),
        ],
      );
    }
    if (f.kind == ContentKind.text || f.kind == ContentKind.xml) {
      return Column(
        children: [
          _fileBar(context, f),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                utf8.decode(f.bytes, allowMalformed: true),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      );
    }
    if (f.kind != ContentKind.pdf) {
      final t = Theme.of(context).textTheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kindIcon(f.kind), size: 96),
            const SizedBox(height: 12),
            Text(f.name, style: t.titleMedium),
            Text('${(f.bytes.length / 1024).toStringAsFixed(1)} KB'),
            const SizedBox(height: 8),
            const Text('CIE Sign non mostra l\'anteprima di questo tipo di file.'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _openFile(f),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Apri con l\'app predefinita'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _saveCopy(f),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Salva una copia'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final placing = f == root && _format == SignFormat.pades && _visible;
    return Column(
      children: [
        _pageBar(context, f),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_thumbs)
                PageThumbnails(
                  key: ValueKey('miniature-${f.fingerprint}'),
                  bytes: f.bytes,
                  sourceName: '${item.source.id}/${f.path}',
                  currentPage: _page,
                  onTap: _goTo,
                ),
              if (_thumbs) const VerticalDivider(width: 1),
              Expanded(child: _viewer(f, placing)),
            ],
          ),
        ),
      ],
    );
  }

  /// Riga col nome del file mostrato, quando non è il documento principale.
  Widget _fileBar(BuildContext context, ContainedFile f) {
    if (f == root || f == root.innermost) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(kindIcon(f.kind), size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Stai guardando: ${f.path}', overflow: TextOverflow.ellipsis)),
            TextButton(onPressed: () => _openFile(root.innermost), child: const Text('Torna al documento')),
          ],
        ),
      ),
    );
  }

  /// Barra di navigazione: miniature, pagine, zoom.
  Widget _pageBar(BuildContext context, ContainedFile f) {
    final t = Theme.of(context).textTheme;
    final ready = _pageCount > 0;
    return Column(
      children: [
        _fileBar(context, f),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('mostra-miniature'),
                  tooltip: _thumbs ? 'Nascondi le miniature' : 'Mostra le miniature',
                  isSelected: _thumbs,
                  onPressed: () => setState(() => _thumbs = !_thumbs),
                  icon: const Icon(Icons.view_sidebar_outlined),
                ),
                const Spacer(),
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
                const Spacer(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _viewer(ContainedFile f, bool placing) {
    return rx.PdfViewer.data(
      f.bytes,
      key: ValueKey('anteprima-${f.fingerprint}'),
      sourceName: '${item.source.id}/${f.path}#${f.bytes.length}',
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
    _focus.requestFocus();
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
    _focus.requestFocus();
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
      if (box != null && box.pageIndex == idx) ...() {
        final r = SignatureBoxGeometry.toTopLeft(box, size);
        // Il cestino sta appena fuori dall'angolo in alto a destra del
        // riquadro, per non coprire il testo; sotto, se il riquadro è in cima.
        const bin = 30.0;
        final above = r.top * scale >= bin + 4;
        final binLeft = (r.right * scale - bin).clamp(0.0, pageRect.width - bin);
        final binTop = above ? r.top * scale - bin - 4 : r.bottom * scale + 4;
        return [
          Positioned(
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
          ),
          Positioned(
            left: binLeft,
            top: binTop,
            width: bin,
            height: bin,
            child: Tooltip(
              message: 'Togli il riquadro della firma (Canc)',
              child: Material(
                color: Colors.red.shade700,
                shape: const CircleBorder(),
                elevation: 2,
                child: InkWell(
                  key: const ValueKey('cestino-riquadro'),
                  customBorder: const CircleBorder(),
                  onTap: _deleteBox,
                  child: const Icon(Icons.delete_outline, size: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        ];
      }(),
    ];
  }

  Widget _sidePanel(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final evals = _detachedReports != null
        ? [for (final r in _detachedReports!) SignatureEvaluation(r, at: ws.reference)]
        : item.evaluationsAt(ws.reference);
    final marks = ws.set.marksOf(item);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(item.name, style: t.titleMedium),
        Text(File(item.source.id).parent.path, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (marks != null) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            children: [
              if (marks.verifiedAt != null) MarkChip(icon: Icons.fact_check_outlined, label: 'Verificato', at: marks.verifiedAt!),
              if (marks.signedAt != null) MarkChip(icon: Icons.draw_outlined, label: 'Firmato', at: marks.signedAt!),
            ],
          ),
        ],
        const SizedBox(height: 16),
        if (_isDetached && _detachedReports == null) ...[
          Text('È una firma staccata: per verificarla serve anche il documento firmato.', style: t.bodyMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickDetachedContent,
            icon: const Icon(Icons.attach_file),
            label: const Text('Scegli il documento originale'),
          ),
        ] else ...[
          if (_detachedName != null) Text('Firma staccata verificata sul documento $_detachedName.', style: t.bodySmall),
          if (root.signatureError != null && !_isDetached)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(root.signatureError!, style: t.bodySmall)),
          VerificationPanel(
            evaluations: evals,
            documentName: item.name,
            reference: ws.reference,
            checkingRevocation: item.checkingRevocation,
          ),
        ],
        if (root.all.length > 1) ...[const Divider(height: 32), _contents(context)],
        const Divider(height: 32),
        ..._signSection(context),
      ],
    );
  }

  /// Contenuto di buste, zip e allegati: un clic apre l'anteprima o l'app
  /// predefinita; accanto, quando è stato visto.
  Widget _contents(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final marks = ws.set.marksOf(item);
    final readable = root.readableFiles;
    final seen = readable.where((f) => marks?.files.containsKey(f.fingerprint) ?? false).length;
    int depth(ContainedFile f) => '/'.allMatches(f.path).length - '/'.allMatches(root.path).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Contenuto', style: t.titleSmall),
        Text('$seen di ${readable.length} file visualizzati', style: t.bodySmall),
        const SizedBox(height: 6),
        for (final f in root.all)
          if (f != root || !f.isContainer)
            _contentRow(context, f, depth(f), marks?.files[f.fingerprint]),
        for (final f in root.all)
          if (f.note != null) Text(f.note!, style: t.bodySmall?.copyWith(color: Colors.orange.shade800)),
      ],
    );
  }

  Widget _contentRow(BuildContext context, ContainedFile f, int depth, FileMark? mark) {
    final t = Theme.of(context).textTheme;
    final showing = ws.viewing == f;
    final origin = switch (f.origin) {
      ContainedOrigin.p7m => 'dalla busta .p7m',
      ContainedOrigin.zip => 'dall\'archivio zip',
      ContainedOrigin.pdfAttachment => 'allegato al PDF',
      ContainedOrigin.document => 'documento',
    };
    return Material(
      color: showing ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: f.isContainer ? null : () => _openFile(f),
        child: Padding(
          padding: EdgeInsets.fromLTRB(4.0 + 14 * (depth - 1).clamp(0, 6), 4, 0, 4),
          child: Row(
            children: [
              Icon(kindIcon(f.kind), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium),
                    if (f.isContainer)
                      Text(origin, style: t.bodySmall)
                    else if (mark != null)
                      MarkChip(
                        icon: mark.external ? Icons.open_in_new : Icons.visibility_outlined,
                        label: mark.external ? 'Aperto' : 'Visto',
                        at: mark.viewedAt,
                      )
                    else
                      Text(
                        f.kind.hasPreview ? 'Da vedere' : 'Da aprire con l\'app predefinita',
                        style: t.bodySmall?.copyWith(color: Colors.orange.shade800),
                      ),
                  ],
                ),
              ),
              if (!f.isContainer)
                IconButton(
                  tooltip: 'Salva una copia',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: () => _saveCopy(f),
                  icon: const Icon(Icons.save_alt),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _signSection(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final phoneReady = _phoneReady;
    final isPdf = root.kind == ContentKind.pdf;
    final isP7m = root.kind == ContentKind.p7m;
    return [
      Text('Firma', style: t.titleSmall),
      const SizedBox(height: 8),
      if (isP7m)
        Text(
          _isDetached
              ? 'Firma staccata: aggiungere una firma qui non è possibile.'
              : 'La tua firma si aggiunge a quelle della busta (firma parallela CAdES): il file resta un unico .p7m.',
          style: t.bodySmall,
        )
      else
        SegmentedButton<SignFormat>(
          segments: [
            ButtonSegment(value: SignFormat.pades, label: const Text('PAdES'), enabled: isPdf),
            const ButtonSegment(value: SignFormat.cades, label: Text('CAdES (.p7m)')),
          ],
          selected: {_format},
          onSelectionChanged: _busy ? null : (s) => setState(() => _format = s.first),
        ),
      if (_format == SignFormat.pades && isPdf)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Firma visibile'),
          subtitle: Text(
            _visible
                ? (_box == null
                      ? 'Clicca sulla pagina per posizionare il riquadro.'
                      : 'Pagina ${_box!.pageIndex + 1}. Trascina il riquadro per spostarlo, gli angoli per '
                            'ridimensionarlo. Per toglierlo usa il cestino o il tasto Canc.')
                : 'La firma non comparirà nella pagina.',
          ),
          value: _visible,
          onChanged: _busy ? null : (v) => setState(() => _visible = v),
        ),
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
            phoneReady ? 'Firma con la CIE tramite ${widget.link!.activeSession!.peerName}' : 'Smartphone non collegato',
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
        key: const ValueKey('firma'),
        onPressed: _busy || (!_test && !phoneReady) || _isDetached ? null : _sign,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.draw_outlined),
        label: Text(_busy ? 'Firma in corso…' : (_cosign ? 'Aggiungi la firma' : 'Firma')),
      ),
      if (_status != null) ...[const SizedBox(height: 12), Text(_status!, style: t.bodyMedium)],
      const SizedBox(height: 24),
      Text(
        'La firma con CIE è una firma elettronica avanzata (FEA): vale per la maggior parte degli usi '
        'tra privati, ma non è una firma digitale qualificata. Altri programmi di verifica la segnalano '
        'come non qualificata.',
        style: t.bodySmall,
      ),
      const SizedBox(height: 8),
      Text(verificationLimits, style: t.bodySmall),
    ];
  }
}
