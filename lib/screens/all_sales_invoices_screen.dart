import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/doc_status.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/row_sync_icon.dart';
import 'document_detail_screen.dart';

/// All Sales Invoices, newest-first — the "كل الفواتير" tab on
/// [SalesInvoiceScreen], same pattern as [AllSalesOrdersScreen]: customer
/// name as the primary line, search + live workflow-state filter chips
/// (read from the real Workflow definition, nothing hardcoded), and a
/// payment-status badge once a card's invoice is actually submitted (see
/// `invoicePaymentStatusInfo` — before that, the approval status badge
/// from `docStatusInfo` is what matters instead).
class AllSalesInvoicesScreen extends StatefulWidget {
  const AllSalesInvoicesScreen({super.key});

  @override
  State<AllSalesInvoicesScreen> createState() =>
      _AllSalesInvoicesScreenState();
}

class _AllSalesInvoicesScreenState extends State<AllSalesInvoicesScreen> {
  List<Map<String, dynamic>> _invoices = [];
  bool _loading = true;
  String? _error;

  bool _fromCache = false;
  List<String> _workflowStates = [];
  String? _stateFilter;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadWorkflowStates();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadWorkflowStates() async {
    try {
      final workflow = await ErpService.getWorkflowDefinition('Sales Invoice');
      final states = workflow?['states'];
      if (states is List) {
        final parsed = states
            .whereType<Map>()
            .map((s) => s['state']?.toString())
            .whereType<String>()
            .toList();
        if (mounted) setState(() => _workflowStates = parsed);
      }
    } catch (_) {
      // No filter chips shown — not a blocking failure.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'Sales Invoice_list',
        cacheKey: 'recent',
        onCacheHit: (cached) {
          if (!mounted) return;
          setState(() {
            _invoices = cached.rows;
            _fromCache = true;
            _loading = false;
          });
        },
        fetch: () => ErpService.getList(
          'Sales Invoice',
          fields: const [
            'name',
            'customer_name',
            'customer',
            'grand_total',
            'outstanding_amount',
            'workflow_state',
            'status',
            'docstatus',
            'modified',
          ],
          orderBy: 'modified desc',
          limit: 100,
        ),
      );
      if (!mounted) return;
      setState(() {
        _invoices = result.rows;
        _fromCache = result.fromCache;
      });
    } catch (e) {
      if (!mounted) return;
      if (_invoices.isNotEmpty) return;
      setState(() => _error = 'تعذر جلب الفواتير: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredInvoices {
    return _invoices.where((doc) {
      if (_stateFilter != null && doc['workflow_state'] != _stateFilter) {
        return false;
      }
      if (_query.isEmpty) return true;
      final haystack = [
        doc['customer_name'],
        doc['customer'],
        doc['name'],
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(_query.toLowerCase());
    }).toList();
  }

  String _formatDate(String? iso) {
    final date = DateTime.tryParse(iso ?? '');
    if (date == null) return '';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final invoices = _filteredInvoices;
    return ColoredBox(
      color: AppColors.lightGray,
      child: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () => Future.wait([_load(), _loadWorkflowStates()]),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'ابحث باسم العميل أو رقم الفاتورة...',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: AppColors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_workflowStates.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _filterChip(
                      label: 'الكل',
                      selected: _stateFilter == null,
                      onTap: () => setState(() => _stateFilter = null),
                    ),
                    for (final state in _workflowStates) ...[
                      const SizedBox(width: 6),
                      _filterChip(
                        label: state,
                        selected: _stateFilter == state,
                        onTap: () => setState(() => _stateFilter = state),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 60),
                child: LoadingIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppColors.accent),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (invoices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                  child: Text(
                    'لا توجد فواتير مطابقة',
                    style: TextStyle(color: AppColors.midGray),
                  ),
                ),
              )
            else
              ...invoices.map((doc) {
                final status = docStatusInfo(doc);
                final paymentStatus = invoicePaymentStatusInfo(doc);
                final title =
                    (doc['customer_name'] ?? doc['customer'] ?? doc['name'])
                        .toString();
                final amount = doc['grand_total'];
                final date = _formatDate(doc['modified'] as String?);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      onTap: () => context.push(
                        documentDetailRoute(
                          'Sales Invoice',
                          doc['name'] as String,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    doc['name'] as String,
                                    style: const TextStyle(
                                      color: AppColors.midGray,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  if (date.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      date,
                                      style: const TextStyle(
                                        color: AppColors.midGray,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    RowSyncIcon(fromCache: _fromCache),
                                    const SizedBox(width: 6),
                                    _statusPill(status.label, status.color),
                                  ],
                                ),
                                if (paymentStatus != null) ...[
                                  const SizedBox(height: 4),
                                  _statusPill(
                                    paymentStatus.label,
                                    paymentStatus.color,
                                  ),
                                ],
                                if (amount != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    '$amount',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accent,
      labelStyle: TextStyle(
        color: selected ? AppColors.white : AppColors.black,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      backgroundColor: AppColors.white,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
