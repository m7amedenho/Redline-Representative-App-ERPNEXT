import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// Shown instead of the normal app whenever the server rejects a login or
/// silent-refresh with the licensing/seat-access `PermissionError` (see
/// `AuthException.accessRestricted`) — a registered account that isn't (or
/// is no longer) allowed to use the mobile app.
///
/// Deliberately isolated: this screen renders NOTHING about the account —
/// not the username, not any cached data, nothing pulled from the server —
/// only the block message itself and a way out. `AuthService.clearSession`
/// wipes whatever tokens might already be on disk (real for the
/// biometric/silent-refresh path where a previously-valid session just got
/// revoked; a no-op for a fresh manual login that never stored anything).
class AccessRestrictedScreen extends StatefulWidget {
  const AccessRestrictedScreen({super.key, this.message});

  final String? message;

  @override
  State<AccessRestrictedScreen> createState() =>
      _AccessRestrictedScreenState();
}

class _AccessRestrictedScreenState extends State<AccessRestrictedScreen> {
  bool _loggingOut = false;

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    await AuthService.clearSession();
    if (!mounted) return;
    context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.lock_outline_rounded,
                      color: AppColors.accent,
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'الدخول غير متاح',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.message ??
                        'حسابك غير مصرح له باستخدام تطبيق الموبايل حاليًا.\n'
                            'تواصل مع الإدارة لتفعيل الدخول.',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.midGray,
                      height: 1.6,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _loggingOut ? null : _logout,
                      icon: _loggingOut
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.white,
                              ),
                            )
                          : const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('تسجيل خروج'),
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
}
