import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Full-page loading state — a slow network read on a plain spinner reads
/// as a frozen/hung screen, especially on the janky connections this app's
/// reps actually have in the field. Swaps in a vector parcel-with-parachute
/// animation on a plain white background instead, so a genuine wait still
/// looks alive. Vector (not the old 150x150 raster GIF, which pixelated
/// badly once scaled up) so it stays crisp at any size, and the sway/bob
/// motion is driven natively in Flutter since flutter_svg doesn't execute
/// the source file's own embedded SMIL animation.
class LoadingIndicator extends StatefulWidget {
  const LoadingIndicator({super.key});

  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_controller.value);
            return Transform.translate(
              offset: Offset(0, -14 * t),
              child: Transform.rotate(angle: (t - 0.5) * 0.12, child: child),
            );
          },
          child: SvgPicture.asset(
            'assets/Falling Parcel.svg',
            width: 170,
            height: 170,
          ),
        ),
      ),
    );
  }
}
