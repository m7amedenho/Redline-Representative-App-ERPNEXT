import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import 'dart:async';

import '../services/auth_service.dart';
import '../services/push_notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';

/// The login screen — also the app's re-entry point every time it's
/// reopened with a stored session (see SplashScreen, which always routes
/// here rather than silently logging in). Two ways in, by design:
///
/// 1. **Fingerprint** (only shown when a session is stored AND the
///    "قفل الدخول بالبصمة" setting is on AND the device supports it) —
///    an explicit button, not an automatic OS prompt on screen load. Success
///    calls `AuthService.refreshSession()` using the stored refresh token.
/// 2. **Manual form** — always available. The domain field is pre-filled
///    from `AuthService.currentDomain()` when known, so a returning user
///    only has to retype username/password, never the domain.
///
/// Either path lands on `/welcome` (not `/home` directly) — see
/// welcome_screen.dart.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _domainController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final _domainFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _autovalidate = false;
  String? _errorText;

  bool _showBiometricOption = false;
  bool _biometricBusy = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final domain = await AuthService.currentDomain();
    if (domain != null && mounted) {
      _domainController.text = domain;
    }

    final hasSession = await AuthService.hasStoredSession();
    if (!hasSession) return;

    final biometricEnabled = await AuthService.isBiometricEnabled();
    if (!biometricEnabled) return;

    bool supported = false;
    try {
      final auth = LocalAuthentication();
      supported = (await auth.canCheckBiometrics) || (await auth.isDeviceSupported());
    } catch (_) {
      supported = false;
    }

    if (!mounted) return;
    setState(() => _showBiometricOption = supported);
  }

  Future<void> _handleBiometricLogin() async {
    setState(() {
      _biometricBusy = true;
      _errorText = null;
    });

    try {
      final auth = LocalAuthentication();
      final confirmed = await auth.authenticate(
        localizedReason: 'أكّد هويتك للدخول إلى حسابك',
        persistAcrossBackgrounding: true,
      );
      if (!confirmed) {
        if (!mounted) return;
        setState(() => _biometricBusy = false);
        return;
      }

      // Fingerprint already confirmed it's really them — a network refresh
      // failing here must NOT keep them locked out. Try it, but only a
      // genuine server rejection (session actually invalid) should block
      // entry; a connectivity failure just means the existing stored
      // access token is used as-is, and `ErpService`'s own 401-refresh-retry
      // transparently catches up the moment a real request goes out once
      // back online.
      try {
        await AuthService.refreshSession();
      } on AuthException catch (e) {
        if (e.serverRejected) rethrow;
      }
      unawaited(PushNotificationService.registerForCurrentUser());
      if (!mounted) return;
      context.go('/welcome');
    } on AuthException catch (e) {
      // Only wipe the stored session when the server actually rejected it
      // (expired/invalid) — a network hiccup shouldn't cost the user their
      // saved login, and the fingerprint option should stay available to
      // retry.
      if (e.serverRejected) {
        await AuthService.clearSession();
        if (mounted) setState(() => _showBiometricOption = false);
      }
      if (!mounted) return;
      setState(() {
        _biometricBusy = false;
        _errorText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _biometricBusy = false;
        _errorText = 'تعذّر تأكيد البصمة، حاول مرة أخرى أو سجّل الدخول يدويًا.';
      });
    }
  }

  @override
  void dispose() {
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _domainFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    setState(() => _autovalidate = true);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await AuthService.login(
        domain: _domainController.text,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      unawaited(PushNotificationService.registerForCurrentUser());

      if (!mounted) return;
      context.go('/welcome');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = 'حدث خطأ غير متوقع، حاول مرة أخرى لاحقًا.';
      });
    }
  }

  void _handleForgotPassword() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('هذه الخاصية غير متاحة حاليًا، تواصل مع الدعم الفني'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            autovalidateMode: _autovalidate
                ? AutovalidateMode.onUserInteraction
                : AutovalidateMode.disabled,
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.black, Color(0xFF2A2A2A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Center(
                        child: AppLogo(size: 38, color: AppColors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'تسجيل الدخول',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppColors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'ادخل بيانات شركتك للمتابعة',
                    style: TextStyle(fontSize: 14, color: AppColors.midGray),
                  ),
                  const SizedBox(height: 28),
                  if (_showBiometricOption) ...[
                    _buildBiometricOption(),
                    const SizedBox(height: 20),
                    Row(
                      children: const [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'أو سجّل الدخول يدويًا',
                            style: TextStyle(color: AppColors.midGray, fontSize: 12),
                          ),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ] else
                    const SizedBox(height: 4),
                  TextFormField(
                    controller: _domainController,
                    focusNode: _domainFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.url],
                    onFieldSubmitted: (_) => _usernameFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'دومين الشركة',
                      hintText: 'مثال: company.redtch.com',
                      prefixIcon: Icon(
                        Icons.dns_rounded,
                        color: AppColors.midGray,
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'برجاء إدخال دومين الشركة'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _usernameController,
                    focusNode: _usernameFocus,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.username],
                    onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم',
                      prefixIcon: Icon(
                        Icons.person_outline_rounded,
                        color: AppColors.midGray,
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'برجاء إدخال اسم المستخدم'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: _obscurePassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _handleLogin(),
                    decoration: InputDecoration(
                      labelText: 'كلمة المرور',
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        color: AppColors.midGray,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: AppColors.midGray,
                        ),
                        tooltip: _obscurePassword
                            ? 'إظهار كلمة المرور'
                            : 'إخفاء كلمة المرور',
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'برجاء إدخال كلمة المرور'
                        : null,
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: AppColors.accent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _errorText!,
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppColors.white,
                            ),
                          )
                        : const Text('تسجيل الدخول'),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: _handleForgotPassword,
                      child: const Text('هل نسيت كلمة المرور؟'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBiometricOption() {
    return Material(
      color: AppColors.lightGray,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: _biometricBusy ? null : _handleBiometricLogin,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: AppColors.black,
                  shape: BoxShape.circle,
                ),
                child: _biometricBusy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: AppColors.white,
                        ),
                      )
                    : const Icon(Icons.fingerprint_rounded, color: AppColors.white),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الدخول بالبصمة',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'استخدم بصمتك للدخول بسرعة',
                      style: TextStyle(color: AppColors.midGray, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
            ],
          ),
        ),
      ),
    );
  }
}
