import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Full-width "slide to confirm" control for sensitive/final actions
/// (sending an invoice, submitting an order, confirming a collection).
///
/// The app is RTL, so the handle starts on the right edge and the user
/// drags it to the left to confirm — matching natural RTL reading/swipe
/// direction rather than mirroring an LTR pattern.
///
/// [onConfirmed] resolves to the REAL outcome (`true`/`false`) of whatever
/// network call it triggers — the button used to flip to its green
/// "confirmed" state the instant the swipe gesture completed, regardless
/// of whether the actual submission succeeded, which meant a real server
/// error could show as "تم التحصيل"/"تم الحفظ" with a green checkmark.
/// Confirmed live: a real "خطأ غير متوقع" during a payment collection
/// still rendered the button as fully succeeded. Now the button waits for
/// the real result and shows a red failure state (auto-resetting so the
/// rep can retry) when it comes back false/throws.
class SwipeToConfirmButton extends StatefulWidget {
  const SwipeToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.confirmedLabel = 'تم التأكيد',
    this.failedLabel = 'حدث خطأ، حاول مرة أخرى',
    this.queuedLabel = 'محفوظ محليًا — سيُرسل عند توفر الاتصال',
    this.wasQueued,
    this.height = 64,
    this.autoResetAfter,
  });

  /// Text shown behind the handle before confirmation.
  final String label;

  /// Text shown once the swipe completes AND the operation actually
  /// succeeded (sent to and confirmed by the server).
  final String confirmedLabel;

  /// Text shown briefly (red) when the operation fails.
  final String failedLabel;

  /// Text shown (gray, not green) when [onConfirmed] succeeded but
  /// [wasQueued] says it was only saved to the offline queue, not actually
  /// sent — see that callback's doc comment.
  final String queuedLabel;

  /// Called once, immediately after [onConfirmed] resolves to `true` —
  /// return `true` if that success was really "saved to the local queue
  /// offline" rather than "confirmed by the server". Distinguishes the two
  /// so a rep never mistakes a queued save for one the server has actually
  /// seen: gray+[queuedLabel] instead of green+[confirmedLabel]. The real
  /// green confirmation for a queued item happens later, on the sync queue
  /// screen, once it actually uploads — this button's own state doesn't
  /// live-track that (the form is usually already reset/reused by then).
  /// Leave null for actions that are never queued (edits, comments,
  /// workflow actions, or anything genuinely online-only).
  final bool Function()? wasQueued;

  /// Called once the handle reaches the end of the track — must resolve to
  /// `true` on real success, `false` on failure. A thrown exception is
  /// treated the same as `false`.
  final Future<bool> Function() onConfirmed;

  final double height;

  /// If set, the button returns to its idle state after this long once
  /// confirmed — useful for demo/testing. Leave null for one-shot actions
  /// that navigate away on confirm (invoices, orders, etc).
  final Duration? autoResetAfter;

  @override
  State<SwipeToConfirmButton> createState() => _SwipeToConfirmButtonState();
}

class _SwipeToConfirmButtonState extends State<SwipeToConfirmButton>
    with TickerProviderStateMixin {
  static const double _handleSize = 52;
  static const double _trackPadding = 6;
  static const double _completeThreshold = 0.82;

  late final AnimationController _snapController;
  late final AnimationController _shimmerController;
  Animation<double>? _snapAnimation;

  double _progress = 0; // 0 = handle at start (right), 1 = reached end (left)
  bool _confirmed = false;
  bool _confirmedWasQueued = false;
  bool _confirming = false;
  bool _failed = false;

  bool get _locked => _confirmed || _confirming || _failed;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _snapController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (_locked) return;
    _snapController.stop();
    HapticFeedback.selectionClick();
  }

  void _onDragUpdate(DragUpdateDetails details, double maxTravel) {
    if (_locked || maxTravel <= 0) return;
    setState(() {
      _progress = (_progress - details.delta.dx / maxTravel).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_locked) return;

    if (_progress >= _completeThreshold) {
      setState(() {
        _progress = 1;
        _confirming = true;
      });
      HapticFeedback.mediumImpact();
      _runConfirm();
    } else {
      _springBackToStart();
    }
  }

  Future<void> _runConfirm() async {
    bool success;
    try {
      success = await widget.onConfirmed();
    } catch (_) {
      success = false;
    }
    if (!mounted) return;

    if (success) {
      final queued = widget.wasQueued?.call() ?? false;
      setState(() {
        _confirming = false;
        _confirmed = true;
        _confirmedWasQueued = queued;
      });
      final resetAfter = widget.autoResetAfter;
      if (resetAfter != null) {
        Future.delayed(resetAfter, () {
          if (!mounted) return;
          setState(() {
            _confirmed = false;
            _confirmedWasQueued = false;
            _progress = 0;
          });
        });
      }
      return;
    }

    HapticFeedback.heavyImpact();
    setState(() {
      _confirming = false;
      _failed = true;
    });
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _failed = false);
    _springBackToStart();
  }

  void _springBackToStart() {
    _snapAnimation =
        Tween<double>(begin: _progress, end: 0).animate(
          CurvedAnimation(parent: _snapController, curve: Curves.elasticOut),
        )..addListener(() {
          setState(() => _progress = _snapAnimation!.value);
        });
    _snapController
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final maxTravel = trackWidth - _handleSize - _trackPadding * 2;
        final handleOffset = _trackPadding + _progress * maxTravel;
        final textOpacity = (1 - _progress * 1.6).clamp(0.0, 1.0);

        final semanticsLabel = _failed
            ? widget.failedLabel
            : (_confirmed
                  ? (_confirmedWasQueued ? widget.queuedLabel : widget.confirmedLabel)
                  : widget.label);

        return Semantics(
          label: semanticsLabel,
          hint: 'مقبض قابل للسحب من اليمين لليسار للتأكيد',
          button: true,
          enabled: !_locked,
          child: _buildTrack(handleOffset, textOpacity, maxTravel),
        );
      },
    );
  }

  Color get _trackColor {
    if (_failed) return AppColors.accent;
    if (_confirmed) {
      return _confirmedWasQueued ? AppColors.midGray : AppColors.success;
    }
    return AppColors.black;
  }

  Widget _buildTrack(
    double handleOffset,
    double textOpacity,
    double maxTravel,
  ) {
    final showIdleLabel = !_confirmed && !_confirming && !_failed;
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: _trackColor,
        borderRadius: BorderRadius.circular(widget.height / 2),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: showIdleLabel ? textOpacity : 0,
            child: Text(
              widget.label,
              style: const TextStyle(
                color: AppColors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _confirming ? 1 : 0,
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: AppColors.white,
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _confirmed ? 1 : 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _confirmedWasQueued
                        ? widget.queuedLabel
                        : widget.confirmedLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _failed ? 1 : 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_rounded,
                  color: AppColors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.failedLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!_locked)
            Positioned(
              right: handleOffset + _handleSize + 10,
              child: IgnorePointer(
                child: Opacity(
                  opacity: (1 - _progress * 2.5).clamp(0.0, 1.0),
                  child: _ShimmerChevrons(controller: _shimmerController),
                ),
              ),
            ),
          Positioned(
            right: handleOffset,
            child: GestureDetector(
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: (d) => _onDragUpdate(d, maxTravel),
              onHorizontalDragEnd: _onDragEnd,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: _handleSize,
                height: _handleSize,
                decoration: BoxDecoration(
                  color: (_confirmed || _failed) ? AppColors.white : AppColors.accent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: _confirming
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: AppColors.accent,
                        ),
                      )
                    : Icon(
                        _confirmed
                            ? Icons.check_rounded
                            : (_failed
                                  ? Icons.close_rounded
                                  : Icons.chevron_right_rounded),
                        color: _confirmed
                            ? (_confirmedWasQueued
                                  ? AppColors.midGray
                                  : AppColors.success)
                            : (_failed ? AppColors.accent : AppColors.white),
                        size: 28,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three small chevrons that light up in sequence, hinting the drag
/// direction with a continuous shimmer instead of a single static arrow.
class _ShimmerChevrons extends StatelessWidget {
  const _ShimmerChevrons({required this.controller});

  final Animation<double> controller;

  static const _chevronCount = 3;
  static const _staggerStep = 0.18;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(_chevronCount, (i) {
            // Each chevron's own pulse cycle is offset from the next so the
            // light appears to travel across all three, looping forever.
            final phase = (controller.value - i * _staggerStep) % 1.0;
            final opacity = (1 - (phase * 2 - 1).abs()).clamp(0.15, 1.0);
            return Opacity(
              opacity: opacity,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 1),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.white,
                  size: 16,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
