import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/row_sync_icon.dart';
import 'document_detail_screen.dart';

class _CustomerRow {
  const _CustomerRow({required this.name, required this.label, this.territory});

  final String name;
  final String label;
  final String? territory;
}

/// Customer list/search — `GET /api/resource/Customer` (standard REST,
/// confirmed usage pattern from the sales screens). Credit limit is NOT
/// shown in this list — it lives in the `credit_limits` child table (not a
/// flat `credit_limit` field, see docs/API_INTEGRATION_NOTES.md "جولة
/// ثامنة"), which would need a per-row fetch this list doesn't do. Full
/// account statement is available per-customer via the bottom sheet below.
///
/// Territory filter (gear icon): the server-side Permission Query Script
/// is NOT the load-bearing restriction here (confirmed unreliable live on
/// this site — see the other Customer pickers' doc comments), so this
/// screen applies the same default client-side filter they do: every
/// territory from [ErpService.getUserTerritories] unless the user narrows
/// it further via the gear icon. An empty manual selection means "back to
/// all my territories", never "no filter at all" — see [_effectiveTerritories].
/// The gear icon itself stays hidden for anyone with zero or one territory,
/// since there's nothing meaningful to narrow.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<_CustomerRow> _results = [];
  bool _loading = true;
  String? _error;

  List<String> _availableTerritories = const [];
  Set<String> _selectedTerritories = {};
  bool _fromCache = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _availableTerritories = await ErpService.getExpandedUserTerritories();
    } catch (e) {
      // Genuinely unresolved (no cache yet AND no connection right now) —
      // must NOT fall through to `_search('')` with an empty territory
      // list, since an empty list there reads as "no filter" and would
      // show every customer in the system, not just this rep's own
      // territory (a confirmed real bug on a weak connection before this
      // was fixed at the `ErpService` layer).
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تحديد مناطقك — تحقق من الاتصال بالإنترنت وحاول مرة أخرى';
      });
      return;
    }
    if (mounted) {
      setState(() {});
      _search('');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(query));
  }

  /// المناطق المستخدمة فعليًا في الاستعلام: اختيار المستخدم اليدوي لو موجود،
  /// وإلا كل مناطقه — مفيش حالة "بلا فلتر خالص" أبدًا طالما عنده منطقة واحدة
  /// على الأقل (نفس فلسفة بيكرات العميل التانية في التطبيق).
  List<String> get _effectiveTerritories => _selectedTerritories.isNotEmpty
      ? _selectedTerritories.toList()
      : _availableTerritories;

  void _applyRows(List<Map<String, dynamic>> rows, bool fromCache) {
    if (!mounted) return;
    setState(() {
      _results = rows
          .map(
            (c) => _CustomerRow(
              name: c['name'] as String,
              label: (c['customer_name'] as String?) ?? c['name'] as String,
              territory: c['territory'] as String?,
            ),
          )
          .toList();
      _fromCache = fromCache;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final effectiveTerritories = _effectiveTerritories;
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'Customer_list',
        cacheKey: '${effectiveTerritories.join(',')}|$query',
        // Paints instantly from the last cached copy — a weak connection
        // used to mean staring at a spinner for however long the live
        // call took to time out before anything showed up at all.
        onCacheHit: (cached) => _applyRows(cached.rows, true),
        fetch: () => ErpService.getList(
          'Customer',
          filters: [
            if (effectiveTerritories.isNotEmpty)
              ['territory', 'in', effectiveTerritories],
            if (query.isNotEmpty) ['customer_name', 'like', '%$query%'],
          ],
          fields: const ['name', 'customer_name', 'territory'],
          limit: 50,
        ),
      );
      _applyRows(result.rows, result.fromCache);
    } catch (e) {
      if (!mounted) return;
      // A cache hit already painted the screen above — a failed live
      // refresh on top of that just means "still showing the cached
      // copy", not a blocking error.
      if (_results.isNotEmpty) {
        setState(() => _loading = false);
        return;
      }
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() {
        _error = message;
        _loading = false;
      });
    }
  }

  Future<void> _openTerritoryFilter() async {
    if (_availableTerritories.length <= 1) return;
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (context) {
        var localSelection = Set<String>.from(_selectedTerritories);
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'فلترة حسب المنطقة',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._availableTerritories.map(
                      (t) => CheckboxListTile(
                        value: localSelection.contains(t),
                        onChanged: (checked) {
                          setSheetState(() {
                            if (checked == true) {
                              localSelection.add(t);
                            } else {
                              localSelection.remove(t);
                            }
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppColors.accent,
                        title: Text(t),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                setSheetState(() => localSelection.clear()),
                            child: const Text('مسح الفلتر'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () =>
                                Navigator.of(context).pop(localSelection),
                            child: const Text('تطبيق'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result != null) {
      setState(() => _selectedTerritories = result);
      _search(_controller.text);
    }
  }

  /// نفس حساب "المديونية الحالية" الموجود في [CustomerStatementScreen] —
  /// مجموع GL Entry (مدين - دائن) — بس بدون تفاصيل الحركات، رقم سريع بس
  /// يظهر في شيت العميل هنا.
  Future<num?> _fetchCustomerDebt(String customer) async {
    try {
      final list = await ErpService.getList(
        'GL Entry',
        filters: [
          ['party_type', '=', 'Customer'],
          ['party', '=', customer],
          ['is_cancelled', '=', 0],
        ],
        fields: const ['debit', 'credit'],
        limit: 500,
      );
      num balance = 0;
      for (final entry in list) {
        balance +=
            ((entry['debit'] as num?) ?? 0) - ((entry['credit'] as num?) ?? 0);
      }
      return balance;
    } catch (_) {
      return null;
    }
  }

  void _openCustomerActions(_CustomerRow customer) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  customer.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                FutureBuilder<num?>(
                  future: _fetchCustomerDebt(customer.name),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    final debt = snapshot.data;
                    if (debt == null) return const SizedBox.shrink();
                    return Text(
                      'المديونية الحالية: ${debt.toStringAsFixed(2)} ج.م',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.storefront_rounded,
                    color: AppColors.accent,
                  ),
                  title: const Text('زيارة عميل'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push('/customer-visits');
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.receipt_long_outlined,
                    color: AppColors.accent,
                  ),
                  title: const Text('كشف حساب'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push(
                      '/customer-statement/${Uri.encodeComponent(customer.name)}'
                      '?label=${Uri.encodeComponent(customer.label)}',
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.badge_outlined,
                    color: AppColors.accent,
                  ),
                  title: const Text('تفاصيل / تعديل العميل'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push(
                      documentDetailRoute('Customer', customer.name),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('إدارة العملاء'),
        actions: [
          if (_availableTerritories.length > 1)
            IconButton(
              icon: Icon(
                Icons.tune_rounded,
                color: _selectedTerritories.isNotEmpty
                    ? AppColors.accent
                    : null,
              ),
              onPressed: _openTerritoryFilter,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _controller,
                onChanged: _onChanged,
                decoration: const InputDecoration(
                  hintText: 'ابحث باسم العميل...',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.accent,
                onRefresh: () => _search(_controller.text),
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // A `RefreshIndicator`'s pull gesture needs a scrollable descendant to
  // attach to — every branch below is wrapped in one (with
  // `AlwaysScrollableScrollPhysics`, since a short/empty list otherwise
  // isn't scrollable at all) so pull-to-refresh works no matter what's on
  // screen: loading, an error, an empty result, or the real list.
  Widget _buildBody() {
    if (_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(padding: EdgeInsets.only(top: 80), child: LoadingIndicator()),
        ],
      );
    }

    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.accent),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    }

    if (_results.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(
              child: Text(
                'لا يوجد عملاء',
                style: TextStyle(color: AppColors.midGray),
              ),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _results.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final customer = _results[i];
        return Material(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => _openCustomerActions(customer),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.lightGray,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: AppColors.black,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customer.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                        if (customer.territory != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            customer.territory!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  RowSyncIcon(fromCache: _fromCache),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_left_rounded,
                    color: AppColors.midGray,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
