import 'cms.dart';
import 'oids.dart';
import 'revocation.dart';
import 'trust.dart';
import 'verify.dart';
import 'x509.dart';

/// Esito di una firma o marca: valida, da controllare o non valida.
enum Outcome { valid, warning, invalid }

/// Una riga del dettaglio: etichetta e valore.
typedef ReportLine = (String label, String value);

/// Data e ora locali nel formato italiano (gg/mm/aaaa hh:mm).
String formatDate(DateTime? d, {bool seconds = false}) {
  if (d == null) return 'non indicata';
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final s = seconds ? ':${two(l.second)}' : '';
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}$s';
}

String formatDay(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year}';
}

String integrityText(SignatureIntegrity i) => switch (i) {
  SignatureIntegrity.valid => 'Firma integra',
  SignatureIntegrity.contentModified => 'Documento modificato dopo la firma',
  SignatureIntegrity.signatureInvalid => 'Firma non valida',
  SignatureIntegrity.certificateMissing => 'Certificato del firmatario assente',
  SignatureIntegrity.unsupportedAlgorithm => 'Algoritmo non supportato',
};

String hexBytes(List<int> b, {String sep = ':'}) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);

/// Codice fiscale dal serialNumber del soggetto ("TINIT-RSSMRA80A01H501U").
String? fiscalCode(Certificate c) {
  final s = c.subject.get(Oids.serialNumber);
  if (s == null) return null;
  return s.startsWith('TINIT-') ? s.substring(6) : s;
}

String issuerName(Certificate c) =>
    c.issuer.get(Oids.organization) ?? c.issuer.get(Oids.commonName) ?? c.issuer.toString();

/// Valutazione di una firma a una data di riferimento ([at], di norma adesso;
/// "verifica alla data" usa una data scelta dall'utente) con l'eventuale esito
/// del controllo di revoca. È la stessa logica per l'app desktop, l'app
/// mobile e il rapporto PDF, così i tre dicono sempre la stessa cosa.
class SignatureEvaluation {
  SignatureEvaluation(
    this.report, {
    DateTime? at,
    this.revocation = const RevocationReport.notChecked(),
    this.pades = false,
    this.where,
  }) : at = at ?? DateTime.now();

  /// Dove si trova la firma quando il documento ne ha a più livelli
  /// (per esempio "busta di offerta.zip.p7m" in un .p7m annidato).
  final String? where;

  final SignatureReport report;
  final DateTime at;
  final RevocationReport revocation;
  final bool pades;

  /// Vero se la data di riferimento è stata scelta (non "adesso").
  bool get isAtPastDate => DateTime.now().difference(at).inMinutes > 1;

  CertificateTime get certificateTime => report.certificateTimeAt(at);

  /// Prova di esistenza della firma: l'ora di una marca temporale integra.
  DateTime? get _poe {
    final t = report.timestamp;
    return !report.isDocumentTimestamp && t != null && t.isValid ? t.genTime : null;
  }

  /// Revoca che conta alla data di riferimento: revocato entro [at] e senza
  /// una marca temporale che provi la firma prima della revoca.
  bool get isRevokedAtReference {
    if (!revocation.revokedAt(at)) return false;
    final poe = _poe, rt = revocation.revocationTime;
    return !(poe != null && rt != null && poe.isBefore(rt));
  }

  Outcome get outcome {
    final r = report;
    if (!r.isIntact) return Outcome.invalid;
    final time = certificateTime;
    if (r.isDocumentTimestamp) return time == CertificateTime.valid ? Outcome.valid : Outcome.warning;
    if (time == CertificateTime.expired || time == CertificateTime.notYetValid) return Outcome.invalid;
    final chain = r.chain?.status;
    if (chain == ChainStatus.brokenChain || chain == ChainStatus.cieExpired) return Outcome.invalid;
    if (isRevokedAtReference) return Outcome.invalid;
    if (revocation.status == RevocationStatus.unknown) return Outcome.warning;
    return Outcome.valid;
  }

  /// Esito in una parola, come in Aruba Sign.
  String get verdict => switch (outcome) {
    Outcome.valid => 'VALIDA',
    Outcome.warning => 'DA CONTROLLARE',
    Outcome.invalid => 'NON VALIDA',
  };

  /// Motivo in chiaro quando la firma non è valida o va controllata; nullo se valida.
  String? get reason {
    final r = report;
    if (!r.isIntact) return integrityText(r.integrity);
    final time = certificateTime;
    if (r.isDocumentTimestamp) return time == CertificateTime.valid ? null : certificateTimeText;
    if (time == CertificateTime.expired) {
      return 'Certificato scaduto il ${formatDate(r.certificate!.notAfter)}'
          '${isAtPastDate ? ' (rispetto al ${formatDate(at)})' : ''}';
    }
    if (time == CertificateTime.notYetValid) return 'Certificato non ancora valido';
    if (r.chain?.status == ChainStatus.brokenChain) return 'Catena di certificazione non valida';
    if (r.chain?.status == ChainStatus.cieExpired) return 'Certificato CIE scaduto alla data della firma';
    if (isRevokedAtReference) return revocationText;
    if (revocation.status == RevocationStatus.unknown) return 'Impossibile verificare se il certificato è stato revocato';
    return null;
  }

  /// Prima riga della scheda: l'esito in poche parole.
  String get headline {
    if (report.isDocumentTimestamp) {
      return outcome == Outcome.valid ? 'Marca temporale integra' : (reason ?? 'Marca temporale');
    }
    final why = reason;
    return switch (outcome) {
      Outcome.valid => 'Firma integra, certificato valido',
      Outcome.warning => 'Da controllare: $why',
      Outcome.invalid => 'Non valida: ${why![0].toLowerCase()}${why.substring(1)}',
    };
  }

  /// Validità del certificato in una frase.
  String get certificateTimeText {
    final c = report.certificate;
    if (c == null) return 'Certificato assente';
    final scad = formatDate(c.notAfter);
    final rif = isAtPastDate ? ' al ${formatDate(at)}' : '';
    return switch (certificateTime) {
      CertificateTime.valid => isAtPastDate ? 'Certificato valido$rif (scade il $scad)' : 'Certificato valido fino al $scad',
      CertificateTime.validAtTimestamp =>
        'Certificato scaduto il $scad, ma la marca temporale prova che la firma è stata apposta prima',
      CertificateTime.expired =>
        report.isDocumentTimestamp
            ? 'Certificato della TSA scaduto il $scad'
            : 'Certificato scaduto il $scad: nessuna marca temporale prova che la firma sia stata apposta prima della scadenza',
      CertificateTime.notYetValid =>
        'Certificato non ancora valido${rif.isEmpty ? ' alla data della firma' : rif} (valido dal ${formatDate(c.notBefore)})',
      CertificateTime.unknown => 'Certificato assente',
    };
  }

  /// Stato di revoca in una frase.
  String get revocationText {
    final rv = revocation;
    final via = rv.source == null ? '' : ' (${rv.source}${rv.checkedAt == null ? '' : ' del ${formatDate(rv.checkedAt)}'})';
    switch (rv.status) {
      case RevocationStatus.notChecked:
        return 'Revoca non controllata';
      case RevocationStatus.unknown:
        return 'Revoca non verificabile: ${rv.message ?? 'nessuna risposta'}';
      case RevocationStatus.good:
        return 'Certificato non revocato$via';
      case RevocationStatus.revoked:
        final when = formatDate(rv.revocationTime);
        final why = rv.reason == null ? '' : ', motivo: ${rv.reason}';
        if (!rv.revokedAt(at)) return 'Certificato revocato il $when$why, dopo la data di verifica$via';
        if (!isRevokedAtReference) {
          return 'Certificato revocato il $when$why, ma la marca temporale prova che la firma è anteriore$via';
        }
        return 'Certificato revocato il $when$why$via';
    }
  }

  /// Valore della firma secondo la catena.
  String get chainText {
    final chain = report.chain!;
    if (chain.status == ChainStatus.unknownIssuer && report.certificate != null) {
      return 'Certificato di ${issuerName(report.certificate!)}, non CIE: qualificazione non ancora verificata dall\'app';
    }
    return chain.label;
  }

  /// Testo breve sulla marca temporale.
  String get timestampText {
    final t = report.timestamp;
    if (t == null) return report.hasTimestamp ? 'Marca temporale presente ma non leggibile' : 'Nessuna marca temporale';
    final who = t.tsaName == null ? '' : ' da ${t.tsaName}';
    final esito = t.isValid
        ? 'integra'
        : !t.imprintMatches
        ? 'non corrisponde ai dati marcati'
        : 'non integra (${integrityText(t.integrity).toLowerCase()})';
    return 'Marca temporale del ${formatDate(t.genTime, seconds: true)}$who, $esito';
  }

  String get title => report.isDocumentTimestamp
      ? 'Marca temporale del documento'
      : report.certificate?.holderName ?? 'Firmatario sconosciuto';

  String get typeText => report.isDocumentTimestamp
      ? 'Marca temporale del documento (PAdES, DocTimeStamp)'
      : pades
      ? 'Firma PAdES${report.subFilter == null ? '' : ' (${report.subFilter})'}'
      : 'Firma CAdES (.p7m)';

  /// Proprietà della firma ("Mostra proprietà firma").
  List<ReportLine> get signatureLines {
    final r = report;
    return [
      ('Esito', headline),
      ('Integrità', r.isDocumentTimestamp && r.isIntact ? 'Marca temporale integra' : integrityText(r.integrity)),
      ('Validità del certificato', certificateTimeText),
      if (!r.isDocumentTimestamp) ('Revoca', revocationText),
      if (r.chain != null) ...[
        ('Valore della firma', chainText),
        if (r.chain!.note != null) ('Nota', r.chain!.note!),
      ],
      ('Tipo', typeText),
      if (where != null) ('Posizione', where!),
      if (!r.isDocumentTimestamp) ...[
        ('Data dichiarata', '${formatDate(r.signingTime, seconds: true)} (orologio di chi firma, non certificata)'),
        ('Marca temporale', timestampText),
      ] else
        ('Data certificata', formatDate(r.signingTime, seconds: true)),
      if (r.coversWholeDocument != null)
        (
          'Copertura',
          r.coversWholeDocument!
              ? 'Copre l\'intero documento'
              : 'Il documento ha aggiunte successive a questa firma (per esempio altre firme o marche)',
        ),
      if (r.fieldName != null && r.fieldName!.isNotEmpty) ('Campo firma', r.fieldName!),
      ('Verificata alla data', formatDate(at)),
    ];
  }

  /// Dati del certificato ("Mostra certificato").
  List<ReportLine> get certificateLines {
    final r = report;
    final c = r.certificate;
    if (c == null) return [('Certificato', 'non presente nella firma')];
    return [
      (r.isDocumentTimestamp ? 'Autorità di marcatura' : 'Titolare', c.holderName),
      if (!r.isDocumentTimestamp && fiscalCode(c) != null) ('Codice fiscale', fiscalCode(c)!),
      ('Emittente', issuerName(c)),
      ('Valido', 'dal ${formatDate(c.notBefore)} al ${formatDate(c.notAfter)}'),
      ('Numero di serie', c.serialNumber.toRadixString(16).toUpperCase()),
      ('Impronta SHA-256', hexBytes(c.sha256Fingerprint)),
      if (r.chain != null && r.chain!.path.length > 1)
        ('Catena di certificazione', r.chain!.path.map((c) => c.subject.get(Oids.commonName) ?? c.holderName).join(' → ')),
      if (c.ocspUrls.isNotEmpty) ('Servizio OCSP', c.ocspUrls.join(', ')),
      if (c.crlUrls.isNotEmpty) ('Lista di revoca (CRL)', c.crlUrls.join(', ')),
    ];
  }

  /// Tutto il dettaglio, per il rapporto.
  List<ReportLine> get allLines => [...signatureLines, ...certificateLines];
}

/// Esito peggiore fra più firme; [Outcome.valid] se non ce ne sono.
Outcome worstOutcome(Iterable<SignatureEvaluation> e) {
  final o = e.map((x) => x.outcome).toSet();
  if (o.contains(Outcome.invalid)) return Outcome.invalid;
  if (o.contains(Outcome.warning)) return Outcome.warning;
  return Outcome.valid;
}

/// Esito complessivo in una frase.
String overallText(List<SignatureEvaluation> evals) {
  if (evals.isEmpty) return 'Il documento non contiene firme';
  final firme = evals.where((e) => !e.report.isDocumentTimestamp).length;
  final marche = evals.length - firme;
  final invalid = evals.where((e) => e.outcome == Outcome.invalid).length;
  final warning = evals.where((e) => e.outcome == Outcome.warning).length;
  String n(int k, String s, String p) => k == 1 ? '1 $s' : '$k $p';
  final parts = [
    if (firme > 0) n(firme, 'firma', 'firme'),
    if (marche > 0) n(marche, 'marca temporale del documento', 'marche temporali del documento'),
  ].join(' e ');
  if (invalid > 0) return '$parts: ${n(invalid, 'non è valida', 'non sono valide')}';
  if (warning > 0) return '$parts: ${n(warning, 'da controllare', 'da controllare')}';
  return evals.length == 1 ? '$parts, valida' : '$parts, tutte valide';
}

const verificationLimits =
    'CIE Sign verifica l\'integrità delle firme e delle marche temporali, la validità dei certificati alla '
    'data di verifica, la revoca del certificato del firmatario (OCSP o CRL, se raggiungibili) e riconosce '
    'i certificati della CIE emessi dal Ministero dell\'Interno. Non controlla ancora l\'elenco europeo dei '
    'prestatori qualificati (EUTL).';

/// Rapporto di verifica in testo semplice, da copiare negli appunti.
String verificationReportText(String documentName, List<SignatureEvaluation> evals, {DateTime? at}) {
  final b = StringBuffer()
    ..writeln('Rapporto di verifica CIE Sign')
    ..writeln('Documento: $documentName')
    ..writeln('Verificato il: ${formatDate(DateTime.now(), seconds: true)}')
    ..writeln('Data di riferimento della verifica: ${formatDate(at ?? DateTime.now())}')
    ..writeln('Esito: ${overallText(evals)}')
    ..writeln();
  for (var i = 0; i < evals.length; i++) {
    final e = evals[i];
    b.writeln(e.report.isDocumentTimestamp ? '${i + 1}. Marca temporale del documento' : '${i + 1}. Firma');
    for (final (l, v) in e.allLines) {
      b.writeln('   $l: $v');
    }
    b.writeln();
  }
  b.writeln(verificationLimits);
  return b.toString();
}

/// Revoca di tutte le firme di un documento, in parallelo: per ogni firma usa
/// il certificato dell'emittente trovato nella catena. Le marche del documento
/// e le firme senza catena restano [RevocationStatus.notChecked].
Future<List<RevocationReport>> checkRevocations(List<SignatureReport> reports, RevocationChecker checker) {
  return Future.wait([
    for (final r in reports)
      () async {
        final c = r.certificate, path = r.chain?.path;
        if (r.isDocumentTimestamp || c == null) return const RevocationReport.notChecked();
        try {
          final issuer = path != null && path.length > 1 ? path[1] : await checker.fetchIssuer(c);
          if (issuer == null) {
            return const RevocationReport(
              status: RevocationStatus.unknown,
              message: 'certificato dell\'emittente non disponibile',
            );
          }
          return await checker.check(c, issuer);
        } on Object catch (e) {
          return RevocationReport(status: RevocationStatus.unknown, message: '$e');
        }
      }(),
  ]);
}
