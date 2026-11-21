import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import 'link_service.dart';
import 'sign_workflow.dart';
import 'signers.dart';
import 'verification_panel.dart';

/// Vista di un documento: anteprima a sinistra, firma e verifica a destra.
class DocumentPage extends StatefulWidget {
  const DocumentPage({super.key, required this.doc, required this.link, required this.onOpen});

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

  static const _boxW = 200.0, _boxH = 64.0;

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
        _cades = CadesFile.open(doc.bytes);
        _reports = _cades!.reports;
      }
    } on Object catch (e) {
      _verifyError = '$e';
    }
  }

  CardSigner get _signer => _useTestSigner || widget.link == null ? TestSigner() : PhoneSigner(widget.link!);

  Future<void> _sign() async {
    if (_format == SignFormat.pades && _visible && _box == null) {
      setState(() => _status = 'Clicca sulla pagina dove vuoi la firma visibile.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final wf = SignWorkflow(_signer, link: _useTestSigner ? null : widget.link);
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
    return rx.PdfViewer.data(
      bytes,
      sourceName: '${doc.path}#${bytes.length}',
      params: rx.PdfViewerParams(
        backgroundColor: Colors.grey.shade300,
        pageOverlaysBuilder: placing ? _overlays : null,
      ),
    );
  }

  List<Widget> _overlays(BuildContext context, Rect pageRect, rx.PdfPage page) {
    final scale = pageRect.width / page.width;
    final idx = page.pageNumber - 1;
    final box = _box;
    final rotated = page.rotation != rx.PdfPageRotation.none;
    return [
      Positioned.fill(
        child: MouseRegion(
          cursor: rotated ? SystemMouseCursors.forbidden : SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: rotated
                ? null
                : (d) {
                    // Il clic è il centro del riquadro; coordinate PDF con y verso l'alto.
                    final x = (d.localPosition.dx / scale - _boxW / 2).clamp(0.0, page.width - _boxW);
                    final yTop = d.localPosition.dy / scale - _boxH / 2;
                    final y = (page.height - yTop - _boxH).clamp(0.0, page.height - _boxH);
                    setState(() => _box = VisibleSignature(pageIndex: idx, x: x, y: y, width: _boxW, height: _boxH));
                  },
          ),
        ),
      ),
      if (box != null && box.pageIndex == idx)
        Positioned(
          left: box.x * scale,
          top: (page.height - box.y - box.height) * scale,
          width: box.width * scale,
          height: box.height * scale,
          child: IgnorePointer(
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
        Text('Firme presenti', style: t.titleSmall),
        const SizedBox(height: 8),
        if (_verifyError != null)
          Text('Impossibile leggere le firme: $_verifyError', style: t.bodySmall)
        else
          VerificationPanel(reports: _reports ?? const []),
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
                        : 'Pagina ${_box!.pageIndex + 1}. Clicca altrove per spostarlo.')
                  : 'La firma non comparirà nella pagina.',
            ),
            value: _visible,
            onChanged: _busy ? null : (v) => setState(() => _visible = v),
          ),
        ],
        const SizedBox(height: 8),
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
                title: Text('Firma di prova'),
                subtitle: Text('Chiave inclusa nell\'app, nessun valore legale. Serve solo a provare il flusso.'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _sign,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.draw_outlined),
          label: Text(_busy ? 'Firma in corso…' : 'Firma'),
        ),
        if (_status != null) ...[const SizedBox(height: 12), Text(_status!, style: t.bodyMedium)],
        const SizedBox(height: 24),
        Text(
          'La firma con CIE è una firma elettronica avanzata (FEA): vale come forma scritta, '
          'ma non basta per gli atti che richiedono la firma qualificata, come le compravendite immobiliari.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}
