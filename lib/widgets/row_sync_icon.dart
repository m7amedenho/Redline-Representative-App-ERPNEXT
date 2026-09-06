import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small per-row indicator for list screens backed by [CacheService] —
/// a subtle green cloud-check when this row came from a live fetch just
/// now (confirmed fresh from the server), or an amber cloud-clock when the
/// whole list is showing a cached copy from a previous fetch (device is
/// offline right now). Same value for every row in one load — attached to
/// each row rather than a single banner because that's the reassurance
/// asked for: glance at any one customer/invoice and know its data is
/// live, not just the screen in general.
class RowSyncIcon extends StatelessWidget {
  const RowSyncIcon({required this.fromCache, super.key});

  final bool fromCache;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: fromCache ? 'بيانات محفوظة — غير محدّثة الآن' : 'محدّثة الآن من السيرفر',
      child: Icon(
        fromCache ? Icons.cloud_queue_rounded : Icons.cloud_done_rounded,
        size: 15,
        color: fromCache ? Colors.orange : AppColors.success,
      ),
    );
  }
}
