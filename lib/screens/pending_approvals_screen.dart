import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import 'document_detail_screen.dart';

/// Transition action names this app never wants to auto-pick for bulk
/// approval — a "reject"/"request edit" action always contains one of
/// these Arabic substrings across every workflow built this session
/// (Customer/Sales Order/Sales Invoice/Material Request all use "رفض" and
/// "تعديل" consistently). Bulk approve only ever fires the one remaining
/// "forward" action for each document — never guesses between multiple
/// forward options, and never touches a document whose only options are
/// reject/request-edit.
const _bulkSkipActionSubstrings = ['رفض', 'تعديل'];

class _DoctypeConfig {
  const _DoctypeConfig(this.label, this.subtitleFields, this.amountField);

  final String label;

  /// Tried in order — first non-empty one wins. Only doctypes this app
  /// already relies on elsewhere (Sales Order/Invoice, Payment Entry) get
  /// real field names here; the rest stay empty rather than guess an
  /// unconfirmed field name that could make the whole query error out.
  final List<String> subtitleFields;
  final String? amountField;
}

const _doctypeConfigs = <String, _DoctypeConfig>{
  'Customer': _DoctypeConfig('عميل', ['customer_name'], null),
  'Sales Order': _DoctypeConfig('طلبية مبيعات', ['customer_name', 'customer'], 'grand_total'),
  'Sales Invoice': _DoctypeConfig('فاتورة مبيعات', ['customer_name', 'customer'], 'grand_total'),
  'Payment Entry': _DoctypeConfig('تحصيل', ['party_name', 'party'], 'paid_amount'),
  'Material Request': _DoctypeConfig('طلب مواد', [], null),
  'Stock Entry': _DoctypeConfig('حركة مخزون', [], null),
  'Expense Claim': _DoctypeConfig('مصروف', [], null),
  'Vehicle Log': _DoctypeConfig('صيانة/وقود سيارة', [], null),
};

/// Generic "pending my approval" browser: pick a DocType → pick one of its
/// *real*, live-fetched workflow states (via `ErpService.getWorkflowDefinition`,
/// same call already used for the workflow stepper on
/// [DocumentDetailScreen]) → list documents currently in that state.
///
/// Deliberately doesn't hardcode any workflow state name or role (e.g.
/// "WF - Region Manager") — state names differ per site/DocType and aren't
/// known here. Whoever opens this screen only ever sees what the server's
/// own permissions actually return; a rep with no approval role just gets
/// empty lists, same fail-open behavior as everywhere else in this app.
class PendingApprovalsScreen extends StatefulWidget {
  const PendingApprovalsScreen({super.key});

  @override
  State<PendingApprovalsScreen> createState() => _PendingApprovalsScreenState();
}

class _PendingApprovalsScreenState extends State<PendingApprovalsScreen> {
  String? _doctype;
  List<String> _states = [];
  bool _loadingStates = false;

  String? _selectedState;
  List<Map<String, dynamic>> _results = [];
  bool _loadingResults = false;

  String? _error;

  final Set<String> _selectedNames = {};
  bool _bulkApproving = false;

  Future<void> _pickDoctype(String doctype) async {
    setState(() {
      _doctype = doctype;
      _states = [];
      _selectedState = null;
      _results = [];
      _selectedNames.clear();
      _error = null;
      _loadingStates = true;
    });
    try {
      final workflow = await ErpService.getWorkflowDefinition(doctype);
      final states = workflow?['states'];
      final parsed = states is List
          ? states
                .whereType<Map>()
                .map((s) => s['state']?.toString())
                .whereType<String>()
                .toList()
          : <String>[];
      if (!mounted) return;
      setState(() {
        _states = parsed;
        if (parsed.isEmpty) {
          _error = 'لا يوجد Workflow نشط لهذا النوع من المستندات على السيرفر';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر جلب حالات الاعتماد: $e');
    } finally {
      if (mounted) setState(() => _loadingStates = false);
    }
  }

  Future<void> _pickState(String state) async {
    final doctype = _doctype;
    if (doctype == null) return;

    setState(() {
      _selectedState = state;
      _results = [];
      _selectedNames.clear();
      _error = null;
      _loadingResults = true;
    });

    try {
      final config = _doctypeConfigs[doctype]!;
      final list = await ErpService.getList(
        doctype,
        filters: [
          ['workflow_state', '=', state],
        ],
        fields: [
          'name',
          'workflow_state',
          'modified',
          ...config.subtitleFields,
          if (config.amountField != null) config.amountField!,
        ],
        orderBy: 'modified desc',
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _results = list;
        if (list.isEmpty) {
          _error = 'لا توجد مستندات بهذه الحالة حاليًا';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر جلب المستندات: $e');
    } finally {
      if (mounted) setState(() => _loadingResults = false);
    }
  }

  /// Applies the one real "forward" action for each selected document, in
  /// sequence — same underlying `get_transitions`/`apply_workflow` RPCs
  /// [DocumentDetailScreen] already uses for a single document, just
  /// looped. A document whose only available actions are reject/request-
  /// edit (see [_bulkSkipActionSubstrings]) is deliberately left alone —
  /// bulk approve only ever approves, never guesses at rejecting on the
  /// manager's behalf. Reports exactly how many succeeded/were skipped/
  /// failed rather than a generic "done", since a silent partial failure
  /// on real approval documents would be a real problem to miss.
  Future<void> _bulkApprove() async {
    final doctype = _doctype;
    if (doctype == null || _selectedNames.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
        title: const Text('موافقة جماعية'),
        content: Text('هل أنت متأكد من الموافقة على ${_selectedNames.length} مستند؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('تأكيد', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _bulkApproving = true);
    var succeeded = 0;
    var skipped = 0;
    var failed = 0;

    for (final name in List<String>.from(_selectedNames)) {
      try {
        final doc = await ErpService.getDoc(doctype, name);
        final transitions = await ErpService.callMethodListPost(
          '/api/method/frappe.model.workflow.get_transitions',
          params: {'doc': jsonEncode(doc)},
        );
        final actions = transitions
            .whereType<Map>()
            .map((t) => t['action']?.toString())
            .whereType<String>()
            .toList();
        final forwardAction = actions
            .where((a) => !_bulkSkipActionSubstrings.any(a.contains))
            .cast<String?>()
            .firstWhere((a) => a != null, orElse: () => null);

        if (forwardAction == null) {
          skipped++;
          continue;
        }

        await ErpService.callMethodPost(
          '/api/method/frappe.model.workflow.apply_workflow',
          params: {'doc': jsonEncode(doc), 'action': forwardAction},
        );
        succeeded++;
      } catch (_) {
        failed++;
      }
    }

    if (!mounted) return;
    setState(() {
      _bulkApproving = false;
      _selectedNames.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تم: $succeeded — تجاهل: $skipped — فشل: $failed'),
      ),
    );
    final state = _selectedState;
    if (state != null) await _pickState(state);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('بانتظار موافقتي')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('نوع المستند', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _doctypeConfigs.entries.map((entry) {
                final selected = entry.key == _doctype;
                return ChoiceChip(
                  label: Text(entry.value.label),
                  selected: selected,
                  onSelected: (_) => _pickDoctype(entry.key),
                  selectedColor: AppColors.accent,
                  labelStyle: TextStyle(
                    color: selected ? AppColors.white : AppColors.black,
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: AppColors.white,
                );
              }).toList(),
            ),
            if (_loadingStates) ...[
              const SizedBox(height: 20),
              const Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            ] else if (_states.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text('الحالة', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _states.map((state) {
                  final selected = state == _selectedState;
                  return ChoiceChip(
                    label: Text(state),
                    selected: selected,
                    onSelected: (_) => _pickState(state),
                    selectedColor: AppColors.accent,
                    labelStyle: TextStyle(
                      color: selected ? AppColors.white : AppColors.black,
                      fontWeight: FontWeight.w700,
                    ),
                    backgroundColor: AppColors.white,
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 24),
            if (_loadingResults)
              const Center(child: CircularProgressIndicator(color: AppColors.accent))
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppColors.midGray),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              if (_results.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => setState(() {
                          if (_selectedNames.length == _results.length) {
                            _selectedNames.clear();
                          } else {
                            _selectedNames
                              ..clear()
                              ..addAll(_results.map((d) => d['name'] as String));
                          }
                        }),
                        icon: Icon(
                          _selectedNames.length == _results.length
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 18,
                        ),
                        label: Text('تحديد الكل (${_results.length})'),
                      ),
                      const Spacer(),
                      if (_selectedNames.isNotEmpty)
                        FilledButton.icon(
                          onPressed: _bulkApproving ? null : _bulkApprove,
                          icon: _bulkApproving
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.white,
                                  ),
                                )
                              : const Icon(Icons.done_all_rounded, size: 16),
                          label: Text(
                            _bulkApproving
                                ? 'جاري التنفيذ...'
                                : 'موافقة على المحدد (${_selectedNames.length})',
                          ),
                        ),
                    ],
                  ),
                ),
              ..._results.map((doc) {
                final doctype = _doctype!;
                final config = _doctypeConfigs[doctype]!;
                final name = doc['name'] as String;
                String subtitle = doctype;
                for (final field in config.subtitleFields) {
                  final value = doc[field] as String?;
                  if (value != null && value.isNotEmpty) {
                    subtitle = value;
                    break;
                  }
                }
                final amount = config.amountField != null ? doc[config.amountField] : null;
                final selected = _selectedNames.contains(name);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      onTap: () => context.push(documentDetailRoute(doctype, name)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Checkbox(
                              value: selected,
                              activeColor: AppColors.accent,
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _selectedNames.add(name);
                                } else {
                                  _selectedNames.remove(name);
                                }
                              }),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (amount != null)
                              Text(
                                '$amount',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                            const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
