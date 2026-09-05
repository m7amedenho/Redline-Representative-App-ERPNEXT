import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shown at the top of any screen reading through [CacheService] whenever
/// the data on screen came from a previous fetch, not a live one just now
/// — so a rep never mistakes a stale offline view (e.g. a customer's
/// balance) for a current one.
class CachedAtBanner extends StatelessWidget {
  const CachedAtBanner({required this.cachedAt, super.key});

  final DateTime cachedAt;

  @override
  Widget build(BuildContext context) {
    final label =
        '${cachedAt.year}-${cachedAt.month.toString().padLeft(2, '0')}-'
        '${cachedAt.day.toString().padLeft(2, '0')} '
        '${cachedAt.hour.toString().padLeft(2, '0')}:${cachedAt.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.lightGray,
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, size: 16, color: AppColors.midGray),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'بيانات غير محدّثة (لا يوجد اتصال) — آخر تحديث: $label',
              style: const TextStyle(
                color: AppColors.midGray,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
