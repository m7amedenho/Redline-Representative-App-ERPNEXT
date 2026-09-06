import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';

/// A small cloud icon next to the notification bell — same size/circle
/// treatment, same "badge with a count" language — showing whether THIS
/// device can currently reach the ERPNext server, not whether the phone
/// has a network signal (a phone can show full bars on a dead SIM or a
/// captive portal and still not reach the site). Tapping it opens the
/// sync queue so a rep can see exactly what's pending.
///
/// Replaces the old always-on banner across every screen — a small,
/// glanceable icon in one place instead of pushing content down
/// everywhere.
class ServerStatusIcon extends StatelessWidget {
  const ServerStatusIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final status = SyncStatusService();
    return ListenableBuilder(
      listenable: status,
      builder: (context, _) {
        final online = status.isOnline;
        final pending = status.pendingCount;
        return Semantics(
          label: online
              ? (pending > 0 ? 'متصل بالسيرفر، $pending عملية بانتظار الإرسال' : 'متصل بالسيرفر')
              : 'غير متصل بالسيرفر',
          button: true,
          child: Material(
            color: AppColors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => context.push('/sync-queue'),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                      color: online ? AppColors.success : AppColors.midGray,
                    ),
                    if (pending > 0)
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$pending',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
