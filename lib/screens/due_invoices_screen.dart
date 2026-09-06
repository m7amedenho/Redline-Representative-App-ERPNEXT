import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/cached_at_banner.dart';
import '../widgets/loading_indicator.dart';
import 'document_detail_screen.dart';

class _DueInvoice {
  const _DueInvoice({
    required this.name,
    required this.customerLabel,
    required this.outstandingAmount,
    this.dueDate,
  });

  final String name;
  final String customerLabel;
  final num outstandingAmount;
  final String? dueDate;

  bool get isOverdue {
    final due = dueDate;
    if (due == null) return false;
    final parsed = DateTime.tryParse(due);
    if (parsed == null) return false;
    final today = DateTime.now();
    return parsed.isBefore(DateTime(today.year, today.month, today.day));
  }
}

/// كالندر فواتير المستحقات — كل فاتورة مبيعات لسه عليها مبلغ، مرتبة بتاريخ
/// الاستحقاق (زي عرض تقويمي بالأيام، بس Grouped List عشان يفضل واضح وسريع
/// بدل شبكة شهرية معقّدة). النطاق حسب الدور — نفس آلية "خط السير" الموجودة
/// فعلاً في التطبيق كله: [ErpService.getUserTerritories] ثم توسيع لكل
/// المناطق الفرعية (`lft`/`rgt`، نفس منطق `team_dashboard_screen.dart`) —
/// ده بيغطي الحالتين تلقائيًا: مندوب (منطقته وحدها، مفيش فروع فتوسيعها
/// بيرجع نفسها) ومدير منطقة (كل مناديبه، لأن مناطقهم فروع تحت منطقته).
class DueInvoicesScreen extends StatefulWidget {
  const DueInvoicesScreen({super.key});

  @override
  State<DueInvoicesScreen> createState() => _DueInvoicesScreenState();
}

class _DueInvoicesScreenState extends State<DueInvoicesScreen> {
  bool _loading = true;
  String? _error;
  List<_DueInvoice> _invoices = [];
  DateTime? _cachedAt;

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
      // The whole multi-step resolution (territories → descendants →
      // customers → invoices) is cached as ONE flattened result, keyed per
      // logged-in rep — offline, `getUserTerritories` itself would fail
      // before ever reaching the invoice query, so caching only the last
      // step wouldn't help; caching the end result does.
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'DueInvoices',
        cacheKey: 'current',
        onCacheHit: (cached) {
          if (!mounted) return;
          setState(() {
            _invoices = cached.rows
                .map(
                  (r) => _DueInvoice(
                    name: r['name'] as String,
                    customerLabel: r['customerLabel'] as String,
                    outstandingAmount: r['outstandingAmount'] as num,
                    dueDate: r['dueDate'] as String?,
                  ),
                )
                .toList();
            _cachedAt = cached.cachedAt;
            _loading = false;
          });
        },
        fetch: () async {
          final territories = await ErpService.getUserTerritories();
          if (territories.isEmpty) return const [];

          final allTerritoryNames = Set<String>.from(territories);
          final territoryRows = await ErpService.getList(
            'Territory',
            filters: [
              ['name', 'in', territories],
            ],
            fields: const ['name', 'lft', 'rgt'],
            limit: territories.length,
          );
          for (final row in territoryRows) {
            final lft = row['lft'] as num?;
            final rgt = row['rgt'] as num?;
            if (lft == null || rgt == null) continue;
            final descendants = await ErpService.getList(
              'Territory',
              filters: [
                ['lft', '>', lft],
                ['rgt', '<', rgt],
              ],
              fields: const ['name'],
              limit: 200,
            );
            allTerritoryNames.addAll(
              descendants.map((d) => d['name'] as String?).whereType<String>(),
            );
          }

          final customers = await ErpService.getList(
            'Customer',
            filters: [
              ['territory', 'in', allTerritoryNames.toList()],
            ],
            fields: const ['name', 'customer_name'],
            limit: 500,
          );
          if (customers.isEmpty) return const [];
          final customerLabels = <String, String>{
            for (final c in customers)
              (c['name'] as String):
                  (c['customer_name'] as String?) ?? c['name'] as String,
          };

          final rows = await ErpService.getList(
            'Sales Invoice',
            filters: [
              ['customer', 'in', customerLabels.keys.toList()],
              ['docstatus', '=', 1],
              ['outstanding_amount', '>', 0],
            ],
            fields: const [
              'name',
              'customer',
              'due_date',
              'outstanding_amount',
            ],
            orderBy: 'due_date asc',
            limit: 500,
          );

          return rows
              .map((r) {
                final customer = r['customer'] as String?;
                final outstanding = r['outstanding_amount'] as num?;
                if (customer == null || outstanding == null) return null;
                return {
                  'name': r['name'],
                  'customerLabel': customerLabels[customer] ?? customer,
                  'outstandingAmount': outstanding,
                  'dueDate': r['due_date'],
                };
              })
              .whereType<Map<String, dynamic>>()
              .toList();
        },
      );

      final invoices = result.rows
          .map(
            (r) => _DueInvoice(
              name: r['name'] as String,
              customerLabel: r['customerLabel'] as String,
              outstandingAmount: r['outstandingAmount'] as num,
              dueDate: r['dueDate'] as String?,
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _invoices = invoices;
        _cachedAt = result.fromCache ? result.cachedAt : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_invoices.isNotEmpty) {
        setState(() => _loading = false);
        return;
      }
      final message = handleErpError(context, e);
      setState(() {
        _loading = false;
        _error = message ?? 'تعذر تحميل فواتير المستحقات';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('فواتير المستحقات')),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingIndicator();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_invoices.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد فواتير عليها مستحقات حاليًا',
          style: TextStyle(color: AppColors.midGray),
        ),
      );
    }

    // تجميع حسب تاريخ الاستحقاق — نفس فكرة الكالندر (كل يوم عنوان، تحته
    // فواتيره) بدون تعقيد شبكة شهرية.
    final byDate = <String, List<_DueInvoice>>{};
    for (final invoice in _invoices) {
      final key = invoice.dueDate ?? 'بدون تاريخ استحقاق';
      byDate.putIfAbsent(key, () => []).add(invoice);
    }
    final dateKeys = byDate.keys.toList()
      ..sort((a, b) {
        if (a == 'بدون تاريخ استحقاق') return 1;
        if (b == 'بدون تاريخ استحقاق') return -1;
        return a.compareTo(b);
      });

    final totalOutstanding = _invoices.fold<num>(
      0,
      (sum, i) => sum + i.outstandingAmount,
    );

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_cachedAt != null) CachedAtBanner(cachedAt: _cachedAt!),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.black,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'إجمالي المستحقات',
                  style: TextStyle(color: AppColors.midGray, fontSize: 12.5),
                ),
                Text(
                  '${totalOutstanding.toStringAsFixed(0)} ج.م',
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final dateKey in dateKeys) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(
                    dateKey,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                  if (byDate[dateKey]!.any((i) => i.isOverdue)) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'متأخرة',
                        style: TextStyle(
                          color: AppColors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ...byDate[dateKey]!.map(
              (invoice) => Material(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () => context.push(
                    documentDetailRoute('Sales Invoice', invoice.name),
                  ),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                invoice.customerLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                invoice.name,
                                style: const TextStyle(
                                  color: AppColors.midGray,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '${invoice.outstandingAmount.toStringAsFixed(0)} ج.م',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
