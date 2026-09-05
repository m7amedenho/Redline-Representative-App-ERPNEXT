import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../utils/html_text.dart';
import '../widgets/loading_indicator.dart';
import 'document_detail_screen.dart';

class _NotificationItem {
  _NotificationItem({
    required this.name,
    required this.subject,
    required this.type,
    required this.creation,
    required this.read,
    required this.documentType,
    required this.documentName,
  });

  final String name;
  final String subject;
  final String? type;
  final DateTime? creation;
  bool read;
  final String? documentType;
  final String? documentName;
}

/// Notification center backed by Frappe's built-in `Notification Log`
/// DocType — the same one every Frappe app's notification bell reads from.
/// It's a standard framework DocType (not a custom `mobile_control`/
/// `red_app` endpoint), so accessed the same way as `Customer`/`Item` via
/// the generic REST wrapper. `read` is toggled via `PUT
/// /api/resource/Notification Log/{name}`. Field names (`subject`, `type`,
/// `read`, `creation`) are Frappe framework standards but not verified
/// against this specific site's Notification Log config — see
/// docs/API_INTEGRATION_NOTES.md.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<_NotificationItem> _items = [];
  bool _loading = true;
  bool _markingAll = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ErpService.getList(
        'Notification Log',
        fields: const [
          'name',
          'subject',
          'type',
          'read',
          'creation',
          'document_type',
          'document_name',
        ],
        orderBy: 'creation desc',
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _items = list.map((n) {
          return _NotificationItem(
            name: n['name'] as String,
            subject: stripHtml((n['subject'] as String?) ?? 'إشعار'),
            type: n['type'] as String?,
            creation: DateTime.tryParse((n['creation'] as String?) ?? ''),
            read: n['read'] == 1 || n['read'] == true,
            documentType: n['document_type'] as String?,
            documentName: n['document_name'] as String?,
          );
        }).toList();
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _unreadCount => _items.where((i) => !i.read).length;

  Future<void> _markRead(_NotificationItem item) async {
    if (!item.read) {
      setState(() => item.read = true);
      try {
        await ErpService.updateDoc('Notification Log', item.name, {'read': 1});
      } catch (_) {
        // Best-effort — a failed sync just means it may show unread again on
        // next refresh; not worth blocking the UI over.
      }
    }

    final docType = item.documentType;
    final docName = item.documentName;
    if (docType != null && docName != null && mounted) {
      context.push(documentDetailRoute(docType, docName));
    }
  }

  Future<void> _markAllRead() async {
    final unread = _items.where((i) => !i.read).toList();
    if (unread.isEmpty) return;
    setState(() => _markingAll = true);
    for (final item in unread) {
      setState(() => item.read = true);
      try {
        await ErpService.updateDoc('Notification Log', item.name, {'read': 1});
      } catch (_) {
        // Best-effort, same as _markRead.
      }
    }
    if (mounted) setState(() => _markingAll = false);
  }

  IconData _iconFor(String? type) {
    switch (type) {
      case 'Alert':
        return Icons.campaign_rounded;
      case 'Assignment':
        return Icons.assignment_turned_in_rounded;
      case 'Mention':
        return Icons.alternate_email_rounded;
      case 'Energy Point':
        return Icons.bolt_rounded;
      case 'Share':
        return Icons.share_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  String _relativeTime(DateTime? time) {
    if (time == null) return '';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays < 7) return 'منذ ${diff.inDays} يوم';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('الإشعارات'),
        actions: [
          if (_unreadCount > 0)
            TextButton(
              onPressed: _markingAll ? null : _markAllRead,
              child: _markingAll
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('تحديد الكل كمقروء'),
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingIndicator();
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 24),
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.accent), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('حاول مرة أخرى')),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Text('لا توجد إشعارات حاليًا', style: TextStyle(color: AppColors.midGray)),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.accent,
      child: ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: _items.length,
        separatorBuilder: (context, i) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final item = _items[i];
          final time = _relativeTime(item.creation);
          return Semantics(
            label: '${item.subject}.$time${item.read ? '' : '. غير مقروء'}',
            button: true,
            child: Material(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.card),
                onTap: () => _markRead(item),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(_iconFor(item.type), color: AppColors.black, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.subject,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              time,
                              style: const TextStyle(color: AppColors.midGray, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      if (!item.read)
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsetsDirectional.only(top: 2, start: 4),
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
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
    );
  }
}
