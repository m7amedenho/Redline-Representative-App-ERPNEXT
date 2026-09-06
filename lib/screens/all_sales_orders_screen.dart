import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/doc_status.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/row_sync_icon.dart';
import 'document_detail_screen.dart';

/// All Sales Orders, newest-first, with a live status chip on each —
/// the second tab on [SalesOrderScreen] (next to "طلبية جديدة") so a rep
/// can see every order and its current approval state without hunting for
/// it by name. No own `Scaffold`/`AppBar` — it's embedded directly inside
/// [SalesOrderScreen]'s `TabBarView`, which owns those. Same card/
/// tap-to-detail pattern as [PendingApprovalsScreen].
///
/// The customer's name is the primary line on each card (not the order
/// number, per explicit request — a rep thinks "فلان الفلاني" first, not
/// "SAL-ORD-2026-00019") with the order number as a smaller secondary line
/// still there for reference. The state filter chips are read live from
/// this DocType's actual `Workflow` definition (`ErpService
/// .getWorkflowDefinition`) — same mechanism used everywhere else in this
/// app — so nothing here is a hardcoded state name.
class AllSalesOrdersScreen extends StatefulWidget {
  const AllSalesOrdersScreen({super.key});

  @override
  State<AllSalesOrdersScreen> createState() => _AllSalesOrdersScreenState();
}

class _AllSalesOrdersScreenState extends State<AllSalesOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
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
      final workflow = await ErpService.getWorkflowDefinition('Sales Order');
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
        cacheDoctype: 'Sales Order_list',
        cacheKey: 'recent',
        onCacheHit: (cached) {
          if (!mounted) return;
          setState(() {
            _orders = cached.rows;
            _fromCache = true;
            _loading = false;
          });
        },
        fetch: () => ErpService.getList(
          'Sales Order',
          fields: const [
            'name',
            'customer_name',
            'customer',
            'grand_total',
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
        _orders = result.rows;
        _fromCache = result.fromCache;
      });
    } catch (e) {
      if (!mounted) return;
      // A cache hit already painted the list above — a failed live refresh
      // on top of that just leaves the cached copy showing, not an error.
      if (_orders.isNotEmpty) return;
      setState(() => _error = 'تعذر جلب الطلبيات: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredOrders {
    return _orders.where((doc) {
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
    final orders = _filteredOrders;
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
                hintText: 'ابحث باسم العميل أو رقم الطلبية...',
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
                    _filterChip(label: 'الكل', selected: _stateFilter == null, onTap: () => setState(() => _stateFilter = null)),
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
            else if (orders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                  child: Text(
                    'لا توجد طلبيات مطابقة',
                    style: TextStyle(color: AppColors.midGray),
                  ),
                ),
              )
            else
              ...orders.map((doc) {
                final status = docStatusInfo(doc);
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
                          'Sales Order',
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
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: status.color.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        status.label,
                                        style: TextStyle(
                                          color: status.color,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
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
