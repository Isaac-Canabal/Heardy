import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../services/firebase_rest_auth.dart';
import '../../theme/app_theme.dart';

/// Pantalla de cuenta: login/registro, recuperación de contraseña y el
/// estado intermedio "verificá tu correo" — las tres las resuelve el SDK de
/// Firebase, ver Fase 2 del plan de seguridad en CLAUDE.md.
///
/// Se llega acá desde el botón "Iniciar sesión" de [ImportScreen]/
/// [SearchScreen] cuando hace falta descargar sin sesión lista, o desde la
/// sección "Cuenta" de Ajustes. No hace de gate global de la app: la
/// biblioteca local funciona sin pasar nunca por acá.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { signIn, register }

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _errorText(AppLocalizations l10n, Object error) {
    // El error crudo al log SIEMPRE, antes de traducirlo. Sin esto, cualquier
    // código no contemplado abajo se ve como "no se pudo completar la
    // operación" y no queda rastro de cuál era: así fue como un APK de debug
    // rechazado por la restricción de la clave de Firebase costó una sesión
    // entera de diagnóstico, con un síntoma que no se parecía en nada a la
    // causa (y arrastrando de paso a las descargas, que sin sesión reciben
    // 401 del servidor).
    print('LoginScreen: fallo de autenticación -> $error');

    // La restricción de la clave de API (paquete + SHA-1 no autorizados) no
    // llega como un código propio en ninguno de los dos caminos: el SDK la
    // envuelve y la API REST la manda como texto. Se reconoce por el mensaje,
    // que es feo pero es lo único que hay, y evita que el caso más confuso de
    // todos se vea igual que un fallo cualquiera.
    final raw = error.toString().toUpperCase();
    if (raw.contains('API_KEY_ANDROID_APP_BLOCKED') ||
        raw.contains('APP_NOT_AUTHORIZED') ||
        raw.contains('ARE BLOCKED')) {
      return l10n.authErrorAppNotAuthorized;
    }

    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-email':
        case 'malformed-email':
          return l10n.authErrorInvalidEmail;
        case 'weak-password':
          return l10n.authErrorWeakPassword;
        case 'email-already-in-use':
          return l10n.authErrorEmailInUse;
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return l10n.authErrorWrongCredentials;
        case 'user-disabled':
          return l10n.authErrorUserDisabled;
        case 'too-many-requests':
          return l10n.authErrorTooManyRequests;
      }
    }
    // Escritorio (W5): la API REST de Identity Toolkit usa sus propios
    // códigos, en MAYÚSCULAS_CON_GUIONES_BAJOS — vocabulario distinto al del
    // SDK móvil de arriba, no una variación de formato del mismo código.
    if (error is FirebaseRestAuthException) {
      final code = error.code;
      if (code == 'EMAIL_EXISTS') return l10n.authErrorEmailInUse;
      if (code.startsWith('WEAK_PASSWORD')) return l10n.authErrorWeakPassword;
      if (code == 'INVALID_EMAIL') return l10n.authErrorInvalidEmail;
      if (code == 'EMAIL_NOT_FOUND' ||
          code == 'INVALID_PASSWORD' ||
          code == 'INVALID_LOGIN_CREDENTIALS') {
        return l10n.authErrorWrongCredentials;
      }
      if (code == 'USER_DISABLED') return l10n.authErrorUserDisabled;
      if (code == 'TOO_MANY_ATTEMPTS_TRY_LATER') return l10n.authErrorTooManyRequests;
    }
    return l10n.authErrorGeneric;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<HeardyAuthProvider>();
    try {
      if (_mode == _Mode.register) {
        await auth.register(email, password);
      } else {
        await auth.signIn(email, password);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final l10n = AppLocalizations.of(context)!;
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<HeardyAuthProvider>().sendPasswordReset(email);
      if (mounted) _showSnack(l10n.authForgotPasswordSentSnack);
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<HeardyAuthProvider>();

    // Sesión lista (con correo verificado): no hay nada más que hacer acá,
    // volver a donde sea que se abrió esta pantalla. Un post-frame callback
    // porque esto puede pasar en medio de un build (p. ej. justo después de
    // que _buildVerifyEmail recargó el usuario).
    if (auth.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.authScreenTitle)),
      body: SafeArea(
        child: auth.isSignedIn && !auth.isEmailVerified
            ? _buildVerifyEmail(l10n, auth)
            : _buildForm(l10n),
      ),
    );
  }

  Widget _buildForm(AppLocalizations l10n) {
    final isRegister = _mode == _Mode.register;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(labelText: l10n.authEmailLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autocorrect: false,
            onSubmitted: (_) => _busy ? null : _submit(),
            decoration: InputDecoration(labelText: l10n.authPasswordLabel),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(isRegister ? l10n.authRegisterButton : l10n.authSignInButton),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _mode = isRegister ? _Mode.signIn : _Mode.register;
                      _error = null;
                    }),
            child: Text(isRegister ? l10n.authToggleToSignInPrompt : l10n.authToggleToRegisterPrompt),
          ),
          if (!isRegister)
            TextButton(
              onPressed: _busy ? null : _forgotPassword,
              child: Text(l10n.authForgotPasswordLink),
            ),
        ],
      ),
    );
  }

  Widget _buildVerifyEmail(AppLocalizations l10n, HeardyAuthProvider auth) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_email_unread_rounded, size: 56, color: AppTheme.primaryLight),
            const SizedBox(height: 16),
            Text(
              l10n.authVerifyEmailTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.authVerifyEmailBody(auth.email ?? ''),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      await auth.reload();
                      if (!mounted) return;
                      setState(() => _busy = false);
                      if (!auth.isEmailVerified) _showSnack(l10n.authStillNotVerifiedSnack);
                    },
              child: Text(l10n.authIveVerifiedButton),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await auth.resendVerificationEmail();
                      if (mounted) _showSnack(l10n.authResendEmailSentSnack);
                    },
              child: Text(l10n.authResendEmailButton),
            ),
            TextButton(
              onPressed: _busy ? null : () => auth.signOut(),
              child: Text(l10n.authWrongAccountHint),
            ),
          ],
        ),
      ),
    );
  }
}
