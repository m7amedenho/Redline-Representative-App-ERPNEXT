import 'package:flutter/material.dart';

/// Full-page loading state — a slow network read on a plain spinner reads
/// as a frozen/hung screen, especially on the janky connections this app's
/// reps actually have in the field. Swaps in an animated GIF on a plain white 
/// background instead, so a genuine wait still looks alive.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: ShaderMask(
          shaderCallback: (Rect bounds) {
            return const RadialGradient(
              center: Alignment.center,
              radius: 0.5,
              colors: [Colors.white, Colors.transparent],
              stops: [0.6, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: Image.asset(
            'assets/Loading.gif',
            width: 190,
            height: 190,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
