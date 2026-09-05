import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// Brief interstitial shown right after a successful login — manual or via
/// fingerprint (see auth_screen.dart, which always routes here instead of
/// straight to `/home`). Fetches the user's real name via `AuthService.me()`
/// (same fallback chain as home_screen.dart's `_loadProfile`) then
/// auto-advances to Home; a slow or failed name fetch never blocks entry —
/// it just falls back to a generic greeting.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  String _name = '';
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final name = await _fetchName();
    if (!mounted) return;
    setState(() {
      _name = name;
      _visible = true;
    });

    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    context.go('/home');
  }

  Future<String> _fetchName() async {
    try {
      final me = await AuthService.me();
      final fullName = me['full_name'] ??
          me['user_full_name'] ??
          (me['first_name'] != null
              ? '${me['first_name']} ${me['last_name'] ?? ''}'.trim()
              : null);
      final name = fullName?.toString().trim();
      return (name == null || name.isEmpty) ? '' : name;
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      body: Center(
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _name.isEmpty ? 'مرحبًا' : 'مرحبًا، $_name',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.white,
                fontSize: 32,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
