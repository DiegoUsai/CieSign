import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';
import 'oids.dart';
import 'x509.dart';

/// Stato di revoca del certificato di un firmatario.
enum RevocationStatus {
  /// Il servizio dell'emittente dichiara il certificato non revocato.
  good,

  /// Certificato revocato o sospeso: vedi [RevocationReport.revocationTime].
  revoked,

  /// Il controllo non ha dato una risposta affidabile (rete assente, servizio
  /// che non risponde, risposta con firma non valida). Non dice nulla sulla firma.
  unknown,

  /// Controllo non richiesto (per esempio verifica senza rete).
  notChecked,
}

/// Esito del controllo di revoca con **OCSP** o **CRL**.
class RevocationReport {
  const RevocationReport({
    required this.status,
    this.source,
    this.url,
    this.checkedAt,
    this.revocationTime,
    this.reason,
    this.message,
  });

  const RevocationReport.notChecked() : this(status: RevocationStatus.notChecked);

  final RevocationStatus status;

  /// "OCSP" o "CRL".
  final String? source;
  final Uri? url;

  /// Ora della risposta OCSP (producedAt) o di emissione della CRL (thisUpdate).
  final DateTime? checkedAt;
  final DateTime? revocationTime;

  /// Motivo della revoca in italiano, se dichiarato dall'emittente.
  final String? reason;

  /// Spiegazione quando lo stato è [RevocationStatus.unknown].
  final String? message;

  /// Vero se il certificato risultava revocato alla data [t]: una revoca
  /// successiva a [t] non invalida una verifica riferita a [t].
  bool revokedAt(DateTime t) => status == RevocationStatus.revoked && !(revocationTime?.isAfter(t) ?? false);

  Map<String, Object?> toJson() => {
    'status': status.name,
    'source': source,
    'url': url?.toString(),
    'checkedAt': checkedAt?.toIso8601String(),
    'revocationTime': revocationTime?.toIso8601String(),
    'reason': reason,
    'message': message,
  };

  factory RevocationReport.fromJson(Map<String, Object?> j) => RevocationReport(
    status: RevocationStatus.values.byName(j['status'] as String),
    source: j['source'] as String?,
    url: j['url'] == null ? null : Uri.parse(j['url'] as String),
    checkedAt: j['checkedAt'] == null ? null : DateTime.parse(j['checkedAt'] as String),
    revocationTime: j['revocationTime'] == null ? null : DateTime.parse(j['revocationTime'] as String),
    reason: j['reason'] as String?,
    message: j['message'] as String?,
  );
}

/// Accesso alla rete per OCSP e CRL, separato perché le app (desktop e
/// mobile) e i test possano fornire il proprio. L'implementazione standard
/// con dart:io è [HttpRevocationFetcher] in revocation_http.dart.
abstract class RevocationFetcher {
  Future<Uint8List> get(Uri url);
  Future<Uint8List> post(Uri url, Uint8List body, String contentType);
}

/// Controllo di revoca: prima OCSP (risposta aggiornata e piccola), poi la
/// CRL se OCSP manca o non risponde. Le CRL scaricate restano in memoria fino
/// alla loro scadenza (nextUpdate), così una pratica con molti documenti dello
/// stesso emittente la scarica una sola volta.
class RevocationChecker {
  RevocationChecker(this.fetcher);

  final RevocationFetcher fetcher;
  final _crls = <Uri, Crl>{};

  Future<RevocationReport> check(Certificate cert, Certificate issuer) async {
    final errors = <String>[];
    for (final url in cert.ocspUrls) {
      try {
        final r = await _ocsp(cert, issuer, url);
        if (r.status != RevocationStatus.unknown) return r;
        errors.add(r.message ?? 'OCSP: stato sconosciuto');
      } on Object catch (e) {
        errors.add('OCSP $url: ${_short(e)}');
      }
    }
    for (final url in cert.crlUrls) {
      try {
        return await _crl(cert, issuer, url);
      } on Object catch (e) {
        errors.add('CRL $url: ${_short(e)}');
      }
    }
    return RevocationReport(
      status: RevocationStatus.unknown,
      message: errors.isEmpty ? 'Il certificato non indica servizi OCSP né liste di revoca' : errors.join('; '),
    );
  }

  /// Certificato dell'emittente scaricato dall'indirizzo caIssuers (AIA),
  /// quando la firma non lo contiene. Nullo se manca o non corrisponde.
  Future<Certificate?> fetchIssuer(Certificate cert) async {
    for (final url in cert.caIssuersUrls) {
      try {
        final bytes = await fetcher.get(url);
        final issuer = Certificate.fromDer(bytes);
        if (cert.isSignedBy(issuer)) return issuer;
      } on Object {
        // Formato PKCS#7 o indirizzo non raggiungibile: si prova il successivo.
      }
    }
    return null;
  }

  Future<RevocationReport> _ocsp(Certificate cert, Certificate issuer, Uri url) async {
    final nonce = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final req = OcspRequest.build(cert, issuer, nonce: nonce);
    final body = await fetcher.post(url, req, 'application/ocsp-request');
    return OcspResponse.parse(body).evaluate(cert, issuer, url: url, nonce: nonce);
  }

  Future<RevocationReport> _crl(Certificate cert, Certificate issuer, Uri url) async {
    var crl = _crls[url];
    if (crl == null || (crl.nextUpdate != null && crl.nextUpdate!.isBefore(DateTime.now().toUtc()))) {
      crl = Crl.parse(await fetcher.get(url));
      if (!crl.isSignedBy(issuer)) throw const FormatException('firma della CRL non valida');
      _crls[url] = crl;
    }
    final e = crl.entryFor(cert.serialNumber);
    if (e == null) {
      return RevocationReport(status: RevocationStatus.good, source: 'CRL', url: url, checkedAt: crl.thisUpdate);
    }
    return RevocationReport(
      status: RevocationStatus.revoked,
      source: 'CRL',
      url: url,
      checkedAt: crl.thisUpdate,
      revocationTime: e.revocationDate,
      reason: e.reason,
    );
  }

  static String _short(Object e) {
    final s = e.toString().replaceFirst(RegExp(r'^(FormatException|SocketException|HttpException|TimeoutException):\s*'), '');
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

/// Motivo di revoca (RFC 5280, CRLReason) in italiano.
String revocationReasonText(int code) => switch (code) {
  0 => 'non specificato',
  1 => 'chiave compromessa',
  2 => 'CA compromessa',
  3 => 'cambio di affiliazione',
  4 => 'certificato sostituito',
  5 => 'cessazione dell\'attività',
  6 => 'certificato sospeso',
  8 => 'rimosso dalla lista',
  9 => 'privilegio ritirato',
  10 => 'attributo compromesso',
  _ => 'codice $code',
};

/// Richiesta **OCSP** (RFC 6960) per un certificato, con impronte SHA-1 come
/// richiesto dai profili più diffusi.
class OcspRequest {
  static Uint8List certId(Certificate cert, Certificate issuer) => Der.seq([
    Der.algorithm(Oids.sha1, withNull: true),
    Der.octets(sha1.convert(issuer.subjectDer).bytes),
    Der.octets(sha1.convert(issuer.subjectPublicKeyBits).bytes),
    cert.serialNumberDer,
  ]);

  static Uint8List build(Certificate cert, Certificate issuer, {Uint8List? nonce}) {
    final request = Der.seq([certId(cert, issuer)]);
    final tbs = Der.seq([
      Der.seq([request]),
      if (nonce != null)
        Der.explicit(
          2,
          Der.seq([
            Der.seq([Der.oid(Oids.ocspNonce), Der.octets(Der.octets(nonce))]),
          ]),
        ),
    ]);
    return Der.seq([tbs]);
  }
}

/// Risposta **OCSP** (RFC 6960).
class OcspResponse {
  OcspResponse._(this.status, this._basic);

  factory OcspResponse.parse(Uint8List der) {
    final root = DerNode.parse(der);
    final status = root[0].content.isEmpty ? -1 : root[0].content[0];
    if (status != 0 || root.length < 2) return OcspResponse._(status, null);
    final rb = root[1][0];
    if (rb[0].asOid != Oids.ocspBasic) throw const FormatException('tipo di risposta OCSP non supportato');
    return OcspResponse._(status, DerNode.parse(Uint8List.fromList(rb[1].content)));
  }

  /// 0 = successful, 1 = malformedRequest, 2 = internalError, 3 = tryLater,
  /// 5 = sigRequired, 6 = unauthorized.
  final int status;
  final DerNode? _basic;

  RevocationReport evaluate(Certificate cert, Certificate issuer, {Uri? url, Uint8List? nonce}) {
    RevocationReport unknown(String m) =>
        RevocationReport(status: RevocationStatus.unknown, source: 'OCSP', url: url, message: 'OCSP: $m');
    final b = _basic;
    if (b == null) return unknown('il servizio ha risposto con errore ($status)');
    final tbs = b[0];
    final alg = b[1][0].asOid;
    final sig = Uint8List.sublistView(b[2].content, 1);
    final certs = <Certificate>[
      if (b.length > 3 && b[3].tag == DerTag.context(0))
        for (final c in b[3][0].children) Certificate.fromDer(Uint8List.fromList(c.raw)),
    ];

    // Chi firma la risposta: l'emittente stesso o un suo delegato OCSP.
    Certificate? signer;
    if (issuer.verifies(alg, tbs.raw, sig)) {
      signer = issuer;
    } else {
      for (final c in certs) {
        if (c.allowsOcspSigning && c.isSignedBy(issuer) && c.verifies(alg, tbs.raw, sig)) {
          signer = c;
          break;
        }
      }
    }
    if (signer == null) return unknown('firma della risposta non valida o di un responder non autorizzato');

    var i = tbs[0].tag == DerTag.context(0) ? 1 : 0;
    i++; // responderID
    final producedAt = tbs[i++].asTime;
    final responses = tbs[i++];
    if (nonce != null && i < tbs.length && tbs[i].tag == DerTag.context(1)) {
      for (final ext in tbs[i][0].children) {
        if (ext[0].asOid != Oids.ocspNonce) continue;
        final v = ext[ext.length - 1].content;
        final got = _innerOctets(v);
        if (!_eq(got, nonce)) return unknown('risposta non corrispondente alla richiesta (nonce)');
      }
    }

    final wanted = OcspRequest.certId(cert, issuer);
    for (final single in responses.children) {
      if (!_sameCertId(single[0], wanted)) continue;
      final st = single[1];
      final thisUpdate = single[2].asTime;
      switch (st.tag) {
        case 0x80:
          return RevocationReport(status: RevocationStatus.good, source: 'OCSP', url: url, checkedAt: producedAt);
        case 0xa1:
          final when = st[0].asTime;
          String? reason;
          if (st.length > 1 && st[1].tag == DerTag.context(0)) {
            final r = st[1][0].content;
            if (r.isNotEmpty) reason = revocationReasonText(r[0]);
          }
          return RevocationReport(
            status: RevocationStatus.revoked,
            source: 'OCSP',
            url: url,
            checkedAt: producedAt,
            revocationTime: when,
            reason: reason,
          );
        default:
          return unknown('il servizio non conosce il certificato (aggiornato al $thisUpdate)');
      }
    }
    return unknown('la risposta non riguarda questo certificato');
  }

  static Uint8List _innerOctets(Uint8List v) {
    try {
      final n = DerNode.parse(v);
      if (n.tag == DerTag.octetString) return n.content;
    } on Object {
      // Alcuni responder mettono il nonce senza OCTET STRING interno.
    }
    return v;
  }

  /// Confronta due CertID ignorando la codifica del NULL nei parametri.
  static bool _sameCertId(DerNode a, Uint8List wanted) {
    final b = DerNode.parse(wanted);
    if (a[0][0].asOid != b[0][0].asOid) {
      return false;
    }
    return _eq(a[1].content, b[1].content) && _eq(a[2].content, b[2].content) && _eq(a[3].content, b[3].content);
  }
}

/// Lista di revoca dei certificati (**CRL**, RFC 5280), DER o PEM.
class Crl {
  Crl._(this._root);

  factory Crl.parse(Uint8List bytes) {
    var der = bytes;
    if (bytes.isNotEmpty && bytes[0] == 0x2d) {
      final text = latin1.decode(bytes);
      final m = RegExp(r'-----BEGIN X509 CRL-----([\s\S]*?)-----END X509 CRL-----').firstMatch(text);
      if (m == null) throw const FormatException('CRL in formato PEM non riconosciuta');
      der = base64.decode(m[1]!.replaceAll(RegExp(r'\s'), ''));
    }
    final root = DerNode.parse(der);
    if (root.tag != DerTag.sequence || root.length < 3) throw const FormatException('CRL non valida');
    return Crl._(root);
  }

  final DerNode _root;
  DerNode get _tbs => _root[0];
  int get _o => _tbs[0].tag == DerTag.integer ? 1 : 0;

  Uint8List get issuerDer => Uint8List.fromList(_tbs[_o + 1].raw);
  DateTime get thisUpdate => _tbs[_o + 2].asTime;
  DateTime? get nextUpdate {
    final n = _tbs.length > _o + 3 ? _tbs[_o + 3] : null;
    return n != null && (n.tag == DerTag.utcTime || n.tag == DerTag.generalizedTime) ? n.asTime : null;
  }

  bool isSignedBy(Certificate issuer) =>
      _eq(issuerDer, issuer.subjectDer) &&
      issuer.verifies(_root[1][0].asOid, _tbs.raw, Uint8List.sublistView(_root[2].content, 1));

  CrlEntry? entryFor(BigInt serial) {
    for (var i = _o + 3; i < _tbs.length; i++) {
      final n = _tbs[i];
      if (n.tag != DerTag.sequence) continue;
      for (final e in n.children) {
        if (e[0].asBigInt != serial) continue;
        String? reason;
        if (e.length > 2) {
          for (final ext in e[2].children) {
            if (ext[0].asOid != Oids.crlReason) continue;
            final v = DerNode.parse(Uint8List.fromList(ext[ext.length - 1].content)).content;
            if (v.isNotEmpty) reason = revocationReasonText(v[0]);
          }
        }
        return CrlEntry(e[1].asTime, reason);
      }
    }
    return null;
  }
}

class CrlEntry {
  CrlEntry(this.revocationDate, this.reason);
  final DateTime revocationDate;
  final String? reason;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
