import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';

/// Intro sequence: the logo reveals, holds, then morphs into a "مرحباً"
/// greeting before handing off to onboarding/home.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const double _logoRevealEnd = 0.3;
  static const double _holdLogoEnd = 0.55;
  static const double _morphEnd = 0.82;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _runIntro();
  }

  /// Only decides where to go next — no silent login here. Whether there's
  /// a stored session or not, the user always lands on a screen that
  /// requires an explicit action (fingerprint tap or typed password) before
  /// reaching Home; see AuthScreen for that logic. This is a deliberate
  /// security choice, not a placeholder — the app must never open straight
  /// into Home without the user actively confirming it's them.
  Future<void> _runIntro() async {
    await _controller.forward();
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    final hasStoredSession = await AuthService.hasStoredSession();
    if (!mounted) return;

    context.go(hasStoredSession ? '/auth' : '/onboarding');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final v = _controller.value;

            double logoOpacity;
            double logoScale;
            double textOpacity;

            if (v < _logoRevealEnd) {
              final t = Curves.easeOutBack.transform(v / _logoRevealEnd);
              logoOpacity = t.clamp(0.0, 1.0);
              logoScale = 0.7 + 0.3 * t;
              textOpacity = 0;
            } else if (v < _holdLogoEnd) {
              logoOpacity = 1;
              logoScale = 1;
              textOpacity = 0;
            } else if (v < _morphEnd) {
              final t = Curves.easeInOut.transform(
                (v - _holdLogoEnd) / (_morphEnd - _holdLogoEnd),
              );
              logoOpacity = 1 - t;
              logoScale = 1 - 0.15 * t;
              textOpacity = t;
            } else {
              logoOpacity = 0;
              logoScale = 0.85;
              textOpacity = 1;
            }

            return Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: logoOpacity,
                  child: Transform.scale(
                    scale: logoScale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        AppLogo(size: 96, color: AppColors.white),
                        SizedBox(height: 16),
                        Text(
                          'REDLINE',
                          style: TextStyle(
                            color: AppColors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Opacity(
                  opacity: textOpacity,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * textOpacity,
                    child: const Text(
                      'مرحباً',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
