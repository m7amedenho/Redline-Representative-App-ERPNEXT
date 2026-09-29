import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_picker.dart';
import 'document_detail_screen.dart';

class IssuesScreen extends StatefulWidget {
  const IssuesScreen({super.key});

  @override
  State<IssuesScreen> createState() => _IssuesScreenState();
}

class _IssuesScreenState extends State<IssuesScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _issues = [];

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
      final rows = await ErpService.getList(
        'Issue',
        fields: const [
          'name',
          'subject',
          'customer',
          'status',
          'priority',
          'issue_type',
          'opening_date',
          'owner',
          'modified',
        ],
        orderBy: 'modified desc',
        limit: 200,
      );
      if (mounted) setState(() => _issues = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = handleErpError(context, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createIssue() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.white,
      builder: (context) => const _CreateIssueSheet(),
    );
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('المذكرات')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createIssue,
        icon: const Icon(Icons.add_comment_rounded),
        label: const Text('مذكرة جديدة'),
      ),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
          ? Center(child: Text(_error!, textAlign: TextAlign.center))
          : RefreshIndicator(
              onRefresh: _load,
              child: _issues.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 180),
                        Center(child: Text('لا توجد مذكرات مسجلة')),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _issues.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final issue = _issues[index];
                        final closed = issue['status'] == 'Closed';
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              closed
                                  ? Icons.check_circle_rounded
                                  : Icons.report_problem_rounded,
                              color: closed
                                  ? AppColors.success
                                  : AppColors.accent,
                            ),
                            title: Text(
                              (issue['subject'] ?? issue['name']).toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              [
                                if (issue['customer'] != null)
                                  issue['customer'],
                                _statusLabel(issue['status']?.toString()),
                                if (issue['priority'] != null)
                                  issue['priority'],
                              ].join(' • '),
                            ),
                            onTap: () => context.push(
                              documentDetailRoute(
                                'Issue',
                                issue['name'].toString(),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

String _statusLabel(String? status) => switch (status) {
  'Open' => 'مفتوحة',
  'Replied' => 'تم الرد',
  'On Hold' => 'معلقة',
  'Resolved' => 'تم الحل',
  'Closed' => 'مغلقة',
  _ => status ?? '—',
};

class _CreateIssueSheet extends StatefulWidget {
  const _CreateIssueSheet();

  @override
  State<_CreateIssueSheet> createState() => _CreateIssueSheetState();
}

class _CreateIssueSheetState extends State<_CreateIssueSheet> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  PickedRecord? _customer;
  PickedRecord? _priority;
  PickedRecord? _issueType;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<PickedRecord?> _pickLink({
    required String doctype,
    required String title,
  }) {
    return showSearchPicker(
      context: context,
      title: title,
      search: (query) async {
        final rows = await ErpService.getList(
          doctype,
          filters: query.isEmpty
              ? null
              : [
                  ['name', 'like', '%$query%'],
                ],
          fields: const ['name'],
          limit: 30,
        );
        return rows
            .map(
              (row) => PickedRecord(
                name: row['name'].toString(),
                label: row['name'].toString(),
              ),
            )
            .toList();
      },
    );
  }

  Future<void> _pickCustomer() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر العميل',
      search: (query) async {
        final rows = await ErpService.getList(
          'Customer',
          filters: [
            if (query.isNotEmpty) ['customer_name', 'like', '%$query%'],
          ],
          fields: const ['name', 'customer_name', 'disabled', 'is_frozen'],
          limit: 30,
        );
        return rows
            .map(
              (row) => PickedRecord(
                name: row['name'].toString(),
                label: (row['customer_name'] ?? row['name']).toString(),
                subtitle: ErpService.customerPickerSubtitle(row),
                enabled: ErpService.isCustomerSelectable(row),
              ),
            )
            .toList();
      },
    );
    if (result != null) setState(() => _customer = result);
  }

  Future<void> _submit() async {
    if (_subject.text.trim().isEmpty) {
      setState(() => _error = 'موضوع المذكرة مطلوب.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'subject': _subject.text.trim(),
      if (_customer != null) 'customer': _customer!.name,
      if (_priority != null) 'priority': _priority!.name,
      if (_issueType != null) 'issue_type': _issueType!.name,
      if (_description.text.trim().isNotEmpty)
        'description': _description.text.trim(),
      'status': 'Open',
    };
    try {
      if (SyncStatusService().isOnline) {
        await ErpService.createDoc('Issue', body);
      } else {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {'operation': 'create', 'doctype': 'Issue', 'data': body},
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = handleErpError(context, e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'تسجيل مذكرة',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _subject,
                decoration: const InputDecoration(labelText: 'موضوع المذكرة *'),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_customer?.label ?? 'اختر العميل (اختياري)'),
                trailing: const Icon(Icons.search_rounded),
                onTap: _pickCustomer,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_priority?.label ?? 'الأولوية'),
                trailing: const Icon(Icons.expand_more_rounded),
                onTap: () async {
                  final value = await _pickLink(
                    doctype: 'Issue Priority',
                    title: 'اختر الأولوية',
                  );
                  if (value != null) setState(() => _priority = value);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_issueType?.label ?? 'نوع المذكرة'),
                trailing: const Icon(Icons.expand_more_rounded),
                onTap: () async {
                  final value = await _pickLink(
                    doctype: 'Issue Type',
                    title: 'اختر نوع المذكرة',
                  );
                  if (value != null) setState(() => _issueType = value);
                },
              ),
              TextField(
                controller: _description,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'تفاصيل المذكرة'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppColors.accent)),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: const Text('إرسال المذكرة'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
