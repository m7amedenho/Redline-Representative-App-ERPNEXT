import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';

/// Wraps the whole app (via `MaterialApp.router`'s `builder:`) so a thin
/// banner shows on EVERY screen — not just the ones that create documents —
/// whenever the phone is offline or has queued operations waiting to go
/// out. Invisible (zero height) the rest of the time, so it never pushes
/// content around on the common "online, nothing pending" path.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = SyncStatusService();
    return Column(
      children: [
        ListenableBuilder(
          listenable: status,
          builder: (context, _) {
            final offline = !status.isOnline;
            final pending = status.pendingCount;
            if (!offline && pending == 0) return const SizedBox.shrink();

            final label = offline && pending > 0
                ? 'غير متصل — $pending عملية بانتظار الإرسال'
                : offline
                ? 'غير متصل بالإنترنت'
                : '$pending عملية بانتظار الإرسال';

            return SafeArea(
              bottom: false,
              child: Material(
                color: offline ? AppColors.midGray : AppColors.accent,
                child: InkWell(
                  onTap: () => context.push('/sync-queue'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          offline
                              ? Icons.cloud_off_rounded
                              : Icons.cloud_upload_rounded,
                          color: AppColors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Expanded(child: child),
      ],
    );
  }
}
