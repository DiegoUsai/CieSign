import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../channel.dart' show LinkException;

/// Server ICE (STUN o TURN) da passare a WebRTC.
class IceServer {
  const IceServer(this.urls, {this.username, this.credential});

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, Object> toJson() => {'urls': urls, 'username': ?username, 'credential': ?credential};

  factory IceServer.fromJson(Map<String, Object?> j) {
    final u = j['urls'];
    return IceServer(
      u is String ? [u] : (u as List).cast<String>(),
      username: j['username'] as String?,
      credential: j['credential'] as String?,
    );
  }

  /// STUN pubblici e gratuiti: bastano quando almeno una delle due reti non
  /// usa un **NAT** simmetrico. Per gli altri casi serve un **TURN**.
  static const defaults = [
    IceServer(['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302']),
  ];
}

/// Dove trovare il servizio di **signaling** (segnalazione).
///
/// Il client parla un sottoinsieme dell'API REST del **Firebase Realtime
/// Database** (GET, PUT, DELETE su percorsi `.json` e ascolto con
/// `text/event-stream`). Il Worker di Cloudflare in `tools/signaling-worker`
/// espone la stessa API, quindi per cambiare servizio basta cambiare
/// [endpoint] e togliere [firebaseApiKey].
class SignalingConfig {
  const SignalingConfig({required this.endpoint, this.firebaseApiKey, this.authEndpoint, this.iceServers = const []});

  /// Per esempio `https://progetto-default-rtdb.europe-west1.firebasedatabase.app`
  /// oppure `https://ciesign-signal.esempio.workers.dev`.
  final Uri endpoint;

  /// Se presente, prima di ogni richiesta si ottiene un **ID token** con
  /// l'accesso anonimo di Firebase Authentication.
  final String? firebaseApiKey;

  /// Solo per l'emulatore di Firebase: base dell'API di autenticazione.
  final Uri? authEndpoint;

  /// Server ICE fissi, aggiunti a quelli che il servizio pubblica in
  /// `/v1/ice.json` e a [IceServer.defaults].
  final List<IceServer> iceServers;

  /// Configurazione letta da `--dart-define` al momento della build:
  /// `CIESIGN_SIGNALING_URL`, `CIESIGN_FIREBASE_API_KEY` e, facoltativi,
  /// `CIESIGN_TURN_URLS` (separati da virgola), `CIESIGN_TURN_USERNAME`,
  /// `CIESIGN_TURN_CREDENTIAL`. Senza URL il collegamento via internet è
  /// disattivato e resta solo la rete locale.
  static SignalingConfig? fromEnvironment() {
    const url = String.fromEnvironment('CIESIGN_SIGNALING_URL');
    if (url.isEmpty) return null;
    const key = String.fromEnvironment('CIESIGN_FIREBASE_API_KEY');
    const turn = String.fromEnvironment('CIESIGN_TURN_URLS');
    const user = String.fromEnvironment('CIESIGN_TURN_USERNAME');
    const cred = String.fromEnvironment('CIESIGN_TURN_CREDENTIAL');
    return SignalingConfig(
      endpoint: Uri.parse(url),
      firebaseApiKey: key.isEmpty ? null : key,
      iceServers: [
        if (turn.isNotEmpty)
          IceServer(turn.split(','), username: user.isEmpty ? null : user, credential: cred.isEmpty ? null : cred),
      ],
    );
  }
}

/// Accesso anonimo a Firebase con l'API REST di Identity Toolkit: nessun dato
/// dell'utente, solo un identificativo casuale che le regole del database
/// richiedono (`auth != null`).
class FirebaseAnonymousAuth {
  FirebaseAnonymousAuth(this.apiKey, this._http, {Uri? emulator})
    : _emulator = emulator; // ignore: prefer_initializing_formals

  final String apiKey;
  final HttpClient _http;
  final Uri? _emulator;
  String? _idToken;
  String? _refreshToken;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  /// Token valido per almeno cinque minuti; lo rinnova se serve.
  Future<String> token({bool force = false}) async {
    if (!force && _idToken != null && DateTime.now().isBefore(_expires.subtract(const Duration(minutes: 5)))) {
      return _idToken!;
    }
    Map<String, Object?> j;
    if (_refreshToken != null) {
      final u = _service('securetoken.googleapis.com', 'v1/token');
      j = await _postJson(u, {'grant_type': 'refresh_token', 'refresh_token': _refreshToken});
      _idToken = j['id_token'] as String;
      _refreshToken = j['refresh_token'] as String;
      _expires = DateTime.now().add(Duration(seconds: int.parse('${j['expires_in']}')));
    } else {
      final u = _service('identitytoolkit.googleapis.com', 'v1/accounts:signUp');
      j = await _postJson(u, {'returnSecureToken': true});
      _idToken = j['idToken'] as String;
      _refreshToken = j['refreshToken'] as String;
      _expires = DateTime.now().add(Duration(seconds: int.parse('${j['expiresIn']}')));
    }
    return _idToken!;
  }

  /// In produzione `https://<host>/<path>`; con l'emulatore
  /// `http://localhost:9099/<host>/<path>`.
  Uri _service(String host, String path) {
    final e = _emulator;
    final u = e == null ? Uri.https(host, path) : e.resolve('$host/$path');
    return u.replace(queryParameters: {'key': apiKey});
  }

  Future<Map<String, Object?>> _postJson(Uri u, Map<String, Object?> body) async {
    final rq = await _http.postUrl(u);
    rq.headers.contentType = ContentType.json;
    rq.write(jsonEncode(body));
    final rs = await rq.close();
    final text = await rs.transform(utf8.decoder).join();
    if (rs.statusCode != 200) {
      throw LinkException('Accesso anonimo a Firebase non riuscito (${rs.statusCode}): $text');
    }
    return jsonDecode(text) as Map<String, Object?>;
  }
}

/// Client del servizio di signaling: una casella postale di valori JSON per
/// percorso, con ascolto in tempo reale tramite **Server-Sent Events**.
class SignalingClient {
  SignalingClient(this.config, {HttpClient? http}) : _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 10);
    final key = config.firebaseApiKey;
    _auth = key == null ? null : FirebaseAnonymousAuth(key, _http, emulator: config.authEndpoint);
  }

  final SignalingConfig config;
  final HttpClient _http;
  FirebaseAnonymousAuth? _auth;
  bool _closed = false;

  Future<Uri> _url(String path, {bool forceToken = false}) async {
    final base = config.endpoint;
    final p = '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}/$path.json';
    final q = {...base.queryParameters};
    final a = _auth;
    if (a != null) q['auth'] = await a.token(force: forceToken);
    return base.replace(path: p, queryParameters: q.isEmpty ? null : q);
  }

  Future<Object?> get(String path) async {
    final rq = await _http.getUrl(await _url(path));
    return _read(await rq.close(), 'GET $path');
  }

  Future<void> put(String path, Object? value) async {
    final rq = await _http.putUrl(await _url(path));
    rq.headers.contentType = ContentType.json;
    rq.write(jsonEncode(value));
    await _read(await rq.close(), 'PUT $path');
  }

  Future<void> delete(String path) async {
    final rq = await _http.deleteUrl(await _url(path));
    await _read(await rq.close(), 'DELETE $path');
  }

  Future<Object?> _read(HttpClientResponse rs, String what) async {
    final text = await rs.transform(utf8.decoder).join();
    if (rs.statusCode < 200 || rs.statusCode > 299) {
      throw LinkException('Servizio di collegamento: $what ha risposto ${rs.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Valore di [path] ora e a ogni modifica. Si riconnette da solo dopo un
  /// errore di rete o il rinnovo del token, finché nessuno cancella
  /// l'ascolto.
  Stream<Object?> watch(String path) {
    late StreamController<Object?> out;
    HttpClientResponse? current;
    StreamSubscription<String>? sub;
    var stopped = false;
    var backoff = const Duration(seconds: 1);

    Future<void> run() async {
      var forceToken = false;
      while (!stopped && !_closed) {
        Object? value;
        try {
          final rq = await _http.getUrl(await _url(path, forceToken: forceToken));
          forceToken = false;
          rq.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          final rs = current = await rq.close();
          if (rs.statusCode == 401 || rs.statusCode == 403) {
            await rs.drain<void>();
            throw LinkException('Servizio di collegamento: accesso negato a $path (${rs.statusCode})');
          }
          if (rs.statusCode != 200) {
            await rs.drain<void>();
            throw LinkException('Servizio di collegamento: ascolto di $path, risposta ${rs.statusCode}');
          }
          backoff = const Duration(seconds: 1);
          final done = Completer<void>();
          String? event;
          final data = StringBuffer();
          sub = rs
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (line.startsWith('event:')) {
                    event = line.substring(6).trim();
                  } else if (line.startsWith('data:')) {
                    data.write(line.substring(5).trim());
                  } else if (line.isEmpty && event != null) {
                    final e = event!;
                    final d = data.toString();
                    event = null;
                    data.clear();
                    switch (e) {
                      case 'put' || 'patch':
                        final j = jsonDecode(d) as Map<String, Object?>;
                        value = applyEvent(value, e, j['path'] as String, j['data']);
                        if (!out.isClosed) out.add(value);
                      case 'auth_revoked':
                        forceToken = true;
                        if (!done.isCompleted) done.complete();
                      case 'cancel':
                        if (!done.isCompleted) done.completeError(LinkException('Ascolto di $path rifiutato: $d'));
                      default:
                        break; // keep-alive
                    }
                  }
                },
                onError: (Object e) {
                  if (!done.isCompleted) done.completeError(e);
                },
                onDone: () {
                  if (!done.isCompleted) done.complete();
                },
                cancelOnError: true,
              );
          await done.future;
          await sub?.cancel();
        } on Object catch (e) {
          if (stopped || _closed) break;
          if (e is LinkException && !out.isClosed) out.addError(e);
          await Future<void>.delayed(backoff);
          if (backoff < const Duration(seconds: 30)) backoff *= 2;
        }
      }
    }

    out = StreamController<Object?>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        stopped = true;
        await sub?.cancel();
        try {
          current?.detachSocket().then((s) => s.destroy()).ignore();
        } on Object {
          // già chiusa
        }
      },
    );
    return out.stream;
  }

  /// Server ICE: quelli del servizio (`/v1/ice.json`, dove il Worker di
  /// Cloudflare mette credenziali **TURN** temporanee), poi quelli fissi
  /// della configurazione, poi gli STUN pubblici.
  Future<List<IceServer>> iceServers() async {
    final list = <IceServer>[];
    try {
      final j = await get('v1/ice').timeout(const Duration(seconds: 5));
      if (j is Map && j['iceServers'] is List) {
        for (final s in (j['iceServers'] as List).cast<Map<String, Object?>>()) {
          list.add(IceServer.fromJson(s));
        }
      }
    } on Object {
      // Nessun server ICE pubblicato: si usano quelli predefiniti.
    }
    return [...list, ...config.iceServers, ...IceServer.defaults];
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }

  /// Applica un evento `put` o `patch` del Realtime Database al valore
  /// locale; [path] è relativo al nodo ascoltato.
  static Object? applyEvent(Object? root, String kind, String path, Object? data) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    Object? setAt(Object? node, int i, Object? Function(Object? old) f) {
      if (i == parts.length) return f(node);
      final m = node is Map ? Map<String, Object?>.from(node) : <String, Object?>{};
      final v = setAt(m[parts[i]], i + 1, f);
      if (v == null) {
        m.remove(parts[i]);
      } else {
        m[parts[i]] = v;
      }
      return m.isEmpty ? null : m;
    }

    if (kind == 'put') return setAt(root, 0, (_) => data);
    return setAt(root, 0, (old) {
      final m = old is Map ? Map<String, Object?>.from(old) : <String, Object?>{};
      (data as Map).forEach((k, v) {
        if (v == null) {
          m.remove(k);
        } else {
          m[k as String] = v;
        }
      });
      return m.isEmpty ? null : m;
    });
  }
}
