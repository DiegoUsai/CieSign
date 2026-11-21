import 'dart:convert';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:crypto/crypto.dart' as c;

/// Messaggi applicativi, scambiati in JSON dentro il canale cifrato.
/// Il campo `t` ne indica il tipo.
sealed class LinkMessage {
  const LinkMessage();

  String get type;
  Map<String, Object?> body();

  Map<String, Object?> toJson() => {'t': type, ...body()};

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static LinkMessage decode(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return switch (j['t']) {
      'pair_confirm' => PairConfirm(j['ok'] == true),
      'ping' => const Ping(),
      'pong' => const Pong(),
      'cert_req' => const CertificateRequest(),
      'cert' => CertificateResponse(base64.decode(j['cert'] as String)),
      'sign_req' => SignRequest.fromJson(j),
      'sign_ok' => SignResponse(
        j['id'] as String,
        base64.decode(j['sig'] as String),
        base64.decode(j['cert'] as String),
      ),
      'sign_no' => SignRejected(j['id'] as String, j['reason'] as String? ?? 'user'),
      'sign_err' => SignError(j['id'] as String, j['code'] as String, j['msg'] as String? ?? '', j['left'] as int?),
      'cancel' => Cancel(j['id'] as String),
      'doc_req' => DocumentRequest(j['id'] as String),
      'doc' => DocumentChunk(j['id'] as String, j['off'] as int, base64.decode(j['data'] as String), j['last'] as bool),
      _ => UnknownMessage(j),
    };
  }
}

/// Conferma, data dall'utente, che il codice di sei cifre coincide sui due
/// dispositivi. L'abbinamento si salva solo quando entrambi hanno confermato.
class PairConfirm extends LinkMessage {
  const PairConfirm(this.ok);
  final bool ok;
  @override
  String get type => 'pair_confirm';
  @override
  Map<String, Object?> body() => {'ok': ok};
}

class Ping extends LinkMessage {
  const Ping();
  @override
  String get type => 'ping';
  @override
  Map<String, Object?> body() => {};
}

class Pong extends LinkMessage {
  const Pong();
  @override
  String get type => 'pong';
  @override
  Map<String, Object?> body() => {};
}

/// Il PC chiede il certificato della CIE registrata sullo smartphone, per
/// comporre gli attributi firmati e il riquadro della firma visibile.
class CertificateRequest extends LinkMessage {
  const CertificateRequest();
  @override
  String get type => 'cert_req';
  @override
  Map<String, Object?> body() => {};
}

class CertificateResponse extends LinkMessage {
  const CertificateResponse(this.certificate);
  final Uint8List certificate;
  @override
  String get type => 'cert';
  @override
  Map<String, Object?> body() => {'cert': base64.encode(certificate)};
}

enum SignFormat { pades, cades }

/// Richiesta di firma. Il PC non manda una semplice impronta ma gli
/// **attributi firmati** (poche centinaia di byte): lo smartphone ne calcola
/// da sé l'impronta da far firmare alla CIE e può controllare che l'impronta
/// del documento contenuta al loro interno sia quella dichiarata, e, se scarica
/// il documento (UC10), ricalcolarla in modo indipendente dal PC.
class SignRequest extends LinkMessage {
  SignRequest({
    required this.id,
    required this.documentName,
    required this.documentSize,
    required this.format,
    required this.signedAttributes,
    required this.expiresAt,
    this.visiblePage,
    this.documentAvailable = false,
  });

  final String id;
  final String documentName;
  final int documentSize;
  final SignFormat format;
  final Uint8List signedAttributes;
  final DateTime expiresAt;

  /// Pagina della firma visibile, contando da 1; nullo se invisibile.
  final int? visiblePage;

  /// Vero se lo smartphone può chiedere il documento con [DocumentRequest].
  final bool documentAvailable;

  @override
  String get type => 'sign_req';

  @override
  Map<String, Object?> body() => {
    'id': id,
    'name': documentName,
    'size': documentSize,
    'fmt': format.name,
    'attrs': base64.encode(signedAttributes),
    'exp': expiresAt.toUtc().toIso8601String(),
    if (visiblePage != null) 'page': visiblePage,
    if (documentAvailable) 'doc': true,
  };

  factory SignRequest.fromJson(Map<String, Object?> j) => SignRequest(
    id: j['id'] as String,
    documentName: j['name'] as String,
    documentSize: j['size'] as int,
    format: SignFormat.values.byName(j['fmt'] as String),
    signedAttributes: base64.decode(j['attrs'] as String),
    expiresAt: DateTime.parse(j['exp'] as String),
    visiblePage: j['page'] as int?,
    documentAvailable: j['doc'] == true,
  );

  /// Impronta SHA-256 che la CIE deve firmare.
  Uint8List get digestToSign => Uint8List.fromList(c.sha256.convert(signedAttributes).bytes);

  /// Impronta del documento dichiarata negli attributi firmati (per PAdES è
  /// l'impronta dei byte coperti dal ByteRange del PDF preparato).
  Uint8List get documentDigest {
    final set = DerNode.parse(signedAttributes);
    for (final a in set.children) {
      if (a[0].asOid == Oids.messageDigest) return Uint8List.fromList(a[1][0].content);
    }
    throw const FormatException('Attributi firmati senza message-digest');
  }

  bool isExpired([DateTime? now]) => (now ?? DateTime.now()).isAfter(expiresAt);
}

class SignResponse extends LinkMessage {
  const SignResponse(this.id, this.signature, this.certificate);
  final String id;
  final Uint8List signature;
  final Uint8List certificate;
  @override
  String get type => 'sign_ok';
  @override
  Map<String, Object?> body() => {'id': id, 'sig': base64.encode(signature), 'cert': base64.encode(certificate)};
}

class SignRejected extends LinkMessage {
  const SignRejected(this.id, [this.reason = 'user']);
  final String id;

  /// `user` (rifiutata dall'utente) oppure `expired` (scaduta sullo smartphone).
  final String reason;
  @override
  String get type => 'sign_no';
  @override
  Map<String, Object?> body() => {'id': id, 'reason': reason};
}

/// Errore della carta o dell'NFC. I codici coincidono con quelli del
/// canale "ciesign/cie" dell'app companion (WRONG_PIN, PIN_BLOCKED, BAD_PIN, NOT_CIE,
/// TAG_LOST, NFC_OFF, CANCELLED, CIE_ERROR).
class SignError extends LinkMessage {
  const SignError(this.id, this.code, this.message, [this.remainingAttempts]);
  final String id;
  final String code;
  final String message;
  final int? remainingAttempts;
  @override
  String get type => 'sign_err';
  @override
  Map<String, Object?> body() => {
    'id': id,
    'code': code,
    'msg': message,
    if (remainingAttempts != null) 'left': remainingAttempts,
  };
}

class Cancel extends LinkMessage {
  const Cancel(this.id);
  final String id;
  @override
  String get type => 'cancel';
  @override
  Map<String, Object?> body() => {'id': id};
}

/// Lo smartphone chiede il documento preparato per mostrarlo (UC10).
class DocumentRequest extends LinkMessage {
  const DocumentRequest(this.id);
  final String id;
  @override
  String get type => 'doc_req';
  @override
  Map<String, Object?> body() => {'id': id};
}

class DocumentChunk extends LinkMessage {
  const DocumentChunk(this.id, this.offset, this.data, this.last);
  final String id;
  final int offset;
  final Uint8List data;
  final bool last;

  /// Dimensione dei blocchi: 48 KB in chiaro, circa 64 KB in Base64.
  static const chunkSize = 48 * 1024;

  @override
  String get type => 'doc';
  @override
  Map<String, Object?> body() => {'id': id, 'off': offset, 'data': base64.encode(data), 'last': last};
}

class UnknownMessage extends LinkMessage {
  const UnknownMessage(this.json);
  final Map<String, Object?> json;
  @override
  String get type => json['t'] as String? ?? '?';
  @override
  Map<String, Object?> body() => json;
}
