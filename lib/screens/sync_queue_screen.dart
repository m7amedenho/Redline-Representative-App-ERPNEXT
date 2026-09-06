import 'package:drift/drift.dart' show Value, OrderingTerm;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../local_db/app_database.dart';
import '../local_db/sync_job_type.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_indicator.dart';
import 'document_detail_screen.dart';

const _jobTypeLabels = <String, String>{
  'salesOrderCreate': 'طلبية مبيعات',
  'customerVisitCreate': 'زيارة عميل',
  'materialRequestCreate': 'طلب مواد',
  'materialRequestReceiptCreate': 'استلام نقل مواد',
  'expenseClaimPersonalCreate': 'مصروف شخصي',
  'expenseClaimVehicleLogChain': 'سجل مركبة + مصروف',
  'customerRegistrationCreate': 'تسجيل عميل',
  'photoAttach': 'رفع صورة',
};

const _statusLabels = <String, String>{
  'pending': 'بانتظار الاتصال',
  'inProgress': 'جاري الإرسال...',
  'success': 'تم الإرسال',
  'failed': 'فشل',
  'needsReview': 'يحتاج مراجعة',
};

/// "قائمة الانتظار" — كل عملية اتحفظت أوفلاين وهتترسل أول ما النت يرجع.
/// حي بالكامل عبر drift's `.watch()`، مفيش أي polling يدوي.
class SyncQueueScreen extends StatefulWidget {
  const SyncQueueScreen({super.key});

  @override
  State<SyncQueueScreen> createState() => _SyncQueueScreenState();
}

class _SyncQueueScreenState extends State<SyncQueueScreen> {
  final _db = AppDatabase.instance;
  final _syncStatus = SyncStatusService();
  bool _syncingNow = false;

  Future<void> _syncNow() async {
    setState(() => _syncingNow = true);
    await _syncStatus.checkNow();
    if (mounted) setState(() => _syncingNow = false);
  }

  Future<void> _retry(SyncJob job) async {
    await (_db.update(_db.syncJobs)..where((t) => t.id.equals(job.id))).write(
      const SyncJobsCompanion(status: Value('pending'), lastError: Value(null)),
    );
  }

  Future<void> _retryAllFailed(List<SyncJob> jobs) async {
    final failed = jobs.where(
      (j) => j.status == SyncJobStatus.failed.name || j.status == SyncJobStatus.needsReview.name,
    );
    for (final job in failed) {
      await _retry(job);
    }
  }

  Future<void> _discard(SyncJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: const Text('حذف العملية'),
        content: const Text(
          'هذه العملية لسه ماترسلتش للسيرفر — لو حذفتها هتتفقد نهائيًا. متأكد؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'حذف',
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await (_db.delete(_db.syncJobs)..where((t) => t.id.equals(job.id))).go();
    }
  }

  void _openResult(SyncJob job) {
    final doctype = job.resultDoctype;
    final name = job.resultName;
    if (doctype != null && name != null) {
      context.push(documentDetailRoute(doctype, name));
    }
  }

  Color _statusColor(String status) {
    if (status == SyncJobStatus.success.name) return AppColors.success;
    if (status == SyncJobStatus.failed.name) return AppColors.accent;
    if (status == SyncJobStatus.needsReview.name) return Colors.orange;
    return AppColors.midGray;
  }

  /// A cloud base for every state, with a small overlay marking the actual
  /// outcome — success (green check) / failed or needs-review (red/orange
  /// X) / still pending or sending (a spinner) — so the queue reads at a
  /// glance without needing the text label at all.
  Widget _statusIcon(String status) {
    final color = _statusColor(status);
    if (status == SyncJobStatus.inProgress.name) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    IconData overlay;
    if (status == SyncJobStatus.success.name) {
      overlay = Icons.check_circle_rounded;
    } else if (status == SyncJobStatus.pending.name) {
      overlay = Icons.schedule_rounded;
    } else {
      overlay = Icons.error_rounded;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.cloud_queue_rounded, color: color, size: 22),
        PositionedDirectional(
          end: -4,
          bottom: -4,
          child: Icon(overlay, color: color, size: 14),
        ),
      ],
    );
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('قائمة الانتظار'),
        actions: [
          IconButton(
            onPressed: _syncingNow ? null : _syncNow,
            icon: _syncingNow
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            tooltip: 'مزامنة الآن',
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<List<SyncJob>>(
          stream: (_db.select(_db.syncJobs)
                ..orderBy([(t) => OrderingTerm.desc(t.id)]))
              .watch(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const LoadingIndicator();
            final jobs = snapshot.data!;
            if (jobs.isEmpty) {
              return const Center(
                child: Text(
                  'لا توجد عمليات معلّقة — كل حاجة اترسلت',
                  style: TextStyle(color: AppColors.midGray),
                ),
              );
            }

            final hasFailed = jobs.any(
              (j) => j.status == SyncJobStatus.failed.name || j.status == SyncJobStatus.needsReview.name,
            );

            return Column(
              children: [
                if (hasFailed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _retryAllFailed(jobs),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('إعادة محاولة كل الفاشل'),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: jobs.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final job = jobs[i];
                      final label = _jobTypeLabels[job.jobType] ?? job.jobType;
                      final statusLabel = _statusLabels[job.status] ?? job.status;
                      final canOpen = job.status == SyncJobStatus.success.name &&
                          job.resultDoctype != null &&
                          job.resultName != null;
                      final canRetry = job.status == SyncJobStatus.failed.name ||
                          job.status == SyncJobStatus.needsReview.name;

                      return Material(
                        color: AppColors.white,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          onTap: canOpen ? () => _openResult(job) : null,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _statusIcon(job.status),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _statusColor(job.status)
                                            .withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        statusLabel,
                                        style: TextStyle(
                                          color: _statusColor(job.status),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _relativeTime(job.createdAt),
                                  style: const TextStyle(
                                    color: AppColors.midGray,
                                    fontSize: 11,
                                  ),
                                ),
                                if (job.lastError != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    job.lastError!,
                                    style: const TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                                if (canRetry || job.status != SyncJobStatus.success.name) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      if (canRetry)
                                        TextButton(
                                          onPressed: () => _retry(job),
                                          child: const Text('إعادة المحاولة'),
                                        ),
                                      const Spacer(),
                                      if (job.status != SyncJobStatus.success.name)
                                        TextButton(
                                          onPressed: () => _discard(job),
                                          child: const Text(
                                            'حذف',
                                            style: TextStyle(color: AppColors.midGray),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
