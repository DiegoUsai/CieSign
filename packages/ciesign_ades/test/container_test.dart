import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:test/test.dart';

void main() {
  final cert = Certificate.fromDer(File('test/resources/titolare-test.der').readAsBytesSync());
  final key = RsaPrivateKey.fromPkcs8(File('test/resources/titolare-test.pk8').readAsBytesSync());
  final cert2 = Certificate.fromDer(File('test/resources/revoca/valido.der').readAsBytesSync());
  final key2 = RsaPrivateKey.fromPkcs8(File('test/resources/revoca/valido.pk8').readAsBytesSync());
  final out = Directory('build/test-output')..createSync(recursive: true);

  Uint8List wrap(Uint8List content) {
    final p = CadesPreparation.prepare(content, cert);
    return p.finish(key.signSha256(p.digestToSign));
  }

  Uint8List res(String n) => File('test/resources/$n').readAsBytesSync();

  test('riconosce il tipo dai primi byte', () {
    expect(Unwrapper.detectKind('x.bin', res('semplice.pdf')), ContentKind.pdf);
    expect(Unwrapper.detectKind('x', res('revoca/gara.zip')), ContentKind.zip);
    expect(Unwrapper.detectKind('x.docx', res('revoca/gara.zip')), ContentKind.other);
    expect(Unwrapper.detectKind('x.p7m', res('cades-t.p7m')), ContentKind.p7m);
    expect(Unwrapper.detectKind('nota.txt', Uint8List.fromList('ciao'.codeUnits)), ContentKind.text);
  });

  test('p7m annidato con zip con PDF con allegato: albero completo', () {
    final p7m = wrap(wrap(res('revoca/gara.zip')));
    final root = Unwrapper.open('gara.zip.p7m.p7m', p7m);
    expect(root.kind, ContentKind.p7m);
    expect(root.signatures, hasLength(1));
    final inner = root.children.single;
    expect(inner.name, 'gara.zip.p7m');
    expect(inner.kind, ContentKind.p7m);
    final zip = inner.children.single;
    expect(zip.name, 'gara.zip');
    expect(zip.kind, ContentKind.zip);
    expect(root.innermost, same(zip));
    expect(zip.children.map((c) => c.name), containsAll(['offerta.txt', 'con-allegato.pdf']));
    final pdf = zip.children.firstWhere((c) => c.kind == ContentKind.pdf);
    expect(pdf.children.single.name, 'capitolato.txt');
    expect(utf8.decode(pdf.children.single.bytes), 'Capitolato di prova\n');
    expect(pdf.children.single.origin, ContainedOrigin.pdfAttachment);
    // Da leggere: il txt, il PDF e il suo allegato; non le buste né lo zip.
    expect(root.readableFiles.map((f) => f.name), unorderedEquals(['offerta.txt', 'con-allegato.pdf', 'capitolato.txt']));
    expect(root.allSignatures, hasLength(2));
    // Percorsi univoci, usati come chiavi della marcatura "visualizzato".
    final paths = root.all.map((f) => f.path).toList();
    expect(paths.toSet().length, paths.length);
    expect(pdf.path, 'gara.zip.p7m.p7m/gara.zip.p7m/gara.zip/con-allegato.pdf');
  });

  test('p7m in Base64', () {
    final b64 = Uint8List.fromList(base64.encode(wrap(res('semplice.pdf'))).codeUnits);
    final root = Unwrapper.open('doc.pdf.p7m', b64);
    expect(root.kind, ContentKind.p7m);
    expect(root.children.single.kind, ContentKind.pdf);
  });

  test('busta illeggibile: errore senza eccezione', () {
    final bad = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x01]);
    final root = Unwrapper.open('rotto.p7m', bad);
    expect(root.children, isEmpty);
  });

  test('firma parallela: stessa busta, due firmatari, entrambi integri', () {
    final content = Uint8List.fromList('Offerta tecnica'.codeUnits);
    final first = wrap(content);
    final prep = CadesPreparation.cosign(first, cert2);
    final both = prep.finish(key2.signSha256(prep.digestToSign));
    File('${out.path}/firma-parallela.p7m').writeAsBytesSync(both);
    final f = CadesFile.open(both);
    expect(f.content, content);
    expect(f.reports, hasLength(2));
    expect(f.reports.every((r) => r.isIntact), isTrue);
    expect(f.reports.map((r) => r.certificate!.subject.get(Oids.commonName)), containsAll(['Titolare valido', 'ROSSI MARIO (PROVA, NON VALIDO)']));
    // Il primo firmatario resta presente (l'ordine del SET DER può cambiare).
    expect(f.reports.map((r) => r.certificate), contains(CadesFile.open(first).reports.single.certificate));
  });
}
