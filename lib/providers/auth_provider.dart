import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Identidad de cuenta para el servidor de descargas oficial (Fase 2 del
/// plan de seguridad, ver CLAUDE.md "Próxima sesión — retomar aquí"):
/// reemplaza la clave de API única compilada en el binario (A1, hallazgo
/// cerrado por esto) por una cuenta real por persona vía Firebase Auth.
///
/// Deliberadamente no toca nada del resto de la app: la biblioteca local, la
/// reproducción, la bandeja y la búsqueda local funcionan sin sesión — sólo
/// [ImportScreen]/[SearchScreen] (las dos pantallas que hablan con el
/// servidor) leen [isReady] antes de dejar descargar algo.
class HeardyAuthProvider with ChangeNotifier {
  final FirebaseAuth? _auth;
  StreamSubscription<User?>? _sub;

  /// Sólo para [HeardyAuthProvider.fake] — nunca puesto por el constructor normal.
  final bool _fakeReady;
  final String? _fakeEmail;

  HeardyAuthProvider({FirebaseAuth? auth})
      : _auth = auth ?? FirebaseAuth.instance,
        _fakeReady = false,
        _fakeEmail = null {
    _sub = _auth!.userChanges().listen((_) => notifyListeners());
  }

  /// Doble de prueba que nunca toca `FirebaseAuth.instance` — un widget test
  /// no tiene `Firebase.initializeApp()` corrido, así que el constructor
  /// normal explotaría antes de llegar a `pumpWidget`. `ImportScreen`/
  /// `SearchScreen` sólo leen [isReady]/[email] de este provider, así que eso
  /// es lo único que hace falta simular; el resto de los métodos no se
  /// invocan en esos flujos y lanzan [UnimplementedError] si algo los llama
  /// por error.
  HeardyAuthProvider.fake({bool isReady = true, String? email})
      : _auth = null,
        _fakeReady = isReady,
        _fakeEmail = email;

  bool get _isFake => _auth == null;

  User? get user => _auth?.currentUser;
  bool get isSignedIn => _isFake ? _fakeReady : user != null;

  /// Sin correo verificado, la app trata la cuenta como si no existiera de
  /// cara al servidor (D-1 del plan: la verificación por correo es el único
  /// control de alta que hace exigible la cuota de la Fase 3 — sin él,
  /// registrarse es gratis e infinito).
  bool get isEmailVerified => _isFake ? _fakeReady : (user?.emailVerified ?? false);
  bool get isReady => _isFake ? _fakeReady : (isSignedIn && isEmailVerified);
  String? get email => _isFake ? _fakeEmail : user?.email;

  /// Token de ID para `Authorization: Bearer <token>`. El SDK lo cachea y
  /// sólo lo refresca de verdad cuando hace falta (o cuando [forceRefresh]
  /// lo pide) — no hay que guardarlo a mano ni preocuparse por su expiración.
  Future<String?> idToken({bool forceRefresh = false}) async {
    if (_isFake) return _fakeReady ? 'fake-token' : null;
    final current = user;
    if (current == null) return null;
    return current.getIdToken(forceRefresh);
  }

  Future<void> register(String email, String password) async {
    final credential = await _auth!.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.sendEmailVerification();
  }

  Future<void> signIn(String email, String password) {
    return _auth!.signInWithEmailAndPassword(email: email.trim(), password: password);
  }

  Future<void> signOut() => _auth!.signOut();

  Future<void> sendPasswordReset(String email) {
    return _auth!.sendPasswordResetEmail(email: email.trim());
  }

  Future<void> resendVerificationEmail() async {
    await _auth!.currentUser?.sendEmailVerification();
  }

  /// Vuelve a leer el estado de la cuenta desde Firebase — hace falta tras
  /// verificar el correo en otra pestaña, porque el token en memoria no se
  /// entera solo.
  ///
  /// Y por eso mismo fuerza un token nuevo en cuanto el correo consta como
  /// verificado: `User.reload()` refresca el registro de la cuenta, pero
  /// **no** el token de ID cacheado, que sigue llevando
  /// `email_verified: false` hasta que caduque (una hora). El servidor mira
  /// ese claim del token, no el estado local (ver `verify_id_token` en
  /// `server/app/firebase_auth.py`), así que sin este refresco la app daría
  /// la cuenta por lista ([isReady]) y la primera descarga se comería un 403
  /// — justo en el minuto siguiente a verificar el correo, que es cuando
  /// todo el mundo lo prueba.
  Future<void> reload() async {
    await _auth!.currentUser?.reload();
    if (_auth.currentUser?.emailVerified ?? false) {
      await _auth.currentUser?.getIdToken(true);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
