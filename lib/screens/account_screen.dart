import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// Account screen — real logout flow, plus the biometric-lock preference
/// that gates whether the fingerprint option shows up on the login screen
/// (see AuthScreen). Real profile data (name, role, photo) is Home's job,
/// once `AuthService.me()` is wired into the UI there.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _isLoggingOut = false;
  bool _biometricEnabled = true;
  bool _biometricSupported = true;
  bool _loadingBiometricSetting = true;

  @override
  void initState() {
    super.initState();
    _loadBiometricSetting();
  }

  Future<void> _loadBiometricSetting() async {
    final enabled = await AuthService.isBiometricEnabled();
    bool supported = true;
    try {
      final auth = LocalAuthentication();
      final canCheck = await auth.canCheckBiometrics;
      final deviceSupported = await auth.isDeviceSupported();
      supported = canCheck || deviceSupported;
    } catch (_) {
      supported = false;
    }
    if (!mounted) return;
    setState(() {
      _biometricEnabled = enabled;
      _biometricSupported = supported;
      _loadingBiometricSetting = false;
    });
  }

  Future<void> _toggleBiometric(bool value) async {
    setState(() => _biometricEnabled = value);
    await AuthService.setBiometricEnabled(value);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: const Text('تسجيل الخروج'),
        content: const Text('هل أنت متأكد من رغبتك في تسجيل الخروج؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'تسجيل الخروج',
              style: TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoggingOut = true);
    await AuthService.logout();
    if (!mounted) return;
    context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('الحساب')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: AppColors.black,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_rounded,
                      color: AppColors.white,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'حسابك مسجّل دخول حاليًا',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.black,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'الأمان',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SwitchListTile(
                value: _biometricEnabled,
                onChanged: (!_biometricSupported || _loadingBiometricSetting)
                    ? null
                    : _toggleBiometric,
                activeThumbColor: AppColors.accent,
                title: const Text(
                  'قفل الدخول بالبصمة',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                subtitle: Text(
                  _biometricSupported
                      ? 'يطلب تأكيد بصمتك عند فتح التطبيق'
                      : 'الجهاز لا يدعم البصمة أو لم يتم تفعيلها في إعدادات الجهاز',
                  style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                ),
                secondary: const Icon(Icons.fingerprint_rounded, color: AppColors.accent),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isLoggingOut ? null : _confirmLogout,
              icon: _isLoggingOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: AppColors.white,
                      ),
                    )
                  : const Icon(Icons.logout_rounded),
              label: const Text('تسجيل الخروج'),
            ),
          ],
        ),
      ),
    );
  }
}
