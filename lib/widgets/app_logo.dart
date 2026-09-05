import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Red Technology brand mark (`assets/logo.svg`). Single-tone by
/// design, so [color] can force it to white/black depending on whatever
/// background it sits on (white on dark surfaces, its own brand red — or
/// black — on light ones).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/logo.svg',
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
