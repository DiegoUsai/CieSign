import 'dart:async';
import 'dart:typed_data';

import 'package:ciesign_ades/ciesign_ades.dart';
import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'link_service.dart';

/// Chi fa firmare l'impronta: lo smartphone con la CIE oppure, durante lo
/// sviluppo, una chiave di prova inclusa nell'app.
abstract class CardSigner {
  String get label;

  /// Vero per la firma di prova, che non ha alcun valore legale.
  bool get isTest;

  Future<Certificate> certificate();

  /// Restituisce la firma PKCS#1 v1.5 dell'impronta degli attributi firmati.
  Future<Uint8List> sign(SignRequest request);
}

class TestSigner implements CardSigner {
  Certificate? _cert;
  RsaPrivateKey? _key;

  @override
  String get label => 'Firma di prova (nessun valore legale)';

  @override
  bool get isTest => true;

  Future<void> _load() async {
    _cert ??= Certificate.fromDer((await rootBundle.load('assets/prova/certificato-prova.der')).buffer.asUint8List());
    _key ??= RsaPrivateKey.fromPkcs8((await rootBundle.load('assets/prova/chiave-prova.pk8')).buffer.asUint8List());
  }

  @override
  Future<Certificate> certificate() async {
    await _load();
    return _cert!;
  }

  @override
  Future<Uint8List> sign(SignRequest request) async {
    await _load();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return _key!.signSha256(request.digestToSign);
  }
}

/// Esito negativo dallo smartphone, con un messaggio già pronto per l'utente.
class SignFailure implements Exception {
  SignFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class PhoneSigner implements CardSigner {
  PhoneSigner(this.link);

  final LinkService link;

  @override
  String get label => 'Smartphone ${link.activeSession?.peerName ?? ''}'.trim();

  @override
  bool get isTest => false;

  SecureChannel get _session {
    final s = link.activeSession;
    if (s == null) throw SignFailure('Nessuno smartphone collegato: apri Firmami sul telefono.');
    return s;
  }

  @override
  Future<Certificate> certificate() async {
    final reply = await link.request(_session, const CertificateRequest(), (m) => m is CertificateResponse);
    return Certificate.fromDer((reply as CertificateResponse).certificate);
  }

  @override
  Future<Uint8List> sign(SignRequest request) async {
    final timeout = request.expiresAt.difference(DateTime.now()) + const Duration(seconds: 5);
    final reply = await link.request(
      _session,
      request,
      (m) =>
          (m is SignResponse && m.id == request.id) ||
          (m is SignRejected && m.id == request.id) ||
          (m is SignError && m.id == request.id),
      timeout: timeout,
    );
    return switch (reply) {
      SignResponse r => r.signature,
      SignRejected r => throw SignFailure(
        r.reason == 'expired' ? 'Richiesta scaduta, riprova dal PC.' : 'Firma rifiutata sullo smartphone.',
      ),
      SignError e => throw SignFailure(
        e.remainingAttempts != null ? '${e.message} (tentativi rimasti: ${e.remainingAttempts})' : e.message,
      ),
      _ => throw SignFailure('Risposta inattesa dallo smartphone.'),
    };
  }
}
