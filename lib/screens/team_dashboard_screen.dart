import 'package:flutter/material.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';

class _RepSummary {
  const _RepSummary({
    required this.salesPerson,
    required this.label,
    required this.achieved,
    required this.target,
    required this.inFlightCount,
    required this.collections,
    required this.expenses,
    required this.debt,
    required this.visitCount,
  });

  final String salesPerson;
  final String label;
  final num achieved;
  final num? target;
  final int inFlightCount;
  final num collections;
  final num expenses;
  final num debt;
  final int visitCount;
}

/// معايير الترتيب — معروضة جنب بعض (مش رقم نهائي واحد يجمعهم) بقرار
/// صريح من المستخدم: "معايير منفصلة، أحكم أنا بنفسي مين الأفضل عمومًا".
enum _SortMetric { sales, collections, expenses, debt, visits }

/// لوحة فريقي — لمدير المنطقة بس (`WF - Region Manager`، بوابة اختيار
/// الدور موجودة في `home_screen.dart`). كل رقم هنا حقيقي من السيرفر: نفس
/// [ErpService.getMonthPerformanceForSalesPerson] المستخدمة لكارت أداء
/// المندوب نفسه في الرئيسية، مطبقة على كل مندوب تحت منطقة المدير — مفيش
/// أي endpoint مخصص لملخص الفريق، الشاشة دي بتجمّعه من نفس البيانات
/// الموجودة فعلاً. KPIs إضافية (تحصيل/مديونية/زيارات) بنفس الأسلوب —
/// تجميع حي من GL Entry/Payment Entry/Customer Visit، مش تقرير مخصص.
///
/// تحديد "مين المندوبين تحت مديري": نفس آلية `getUserTerritories` (طبقة
/// User Permission الحقيقية) لكن بالعكس — بدل "مين المناطق بتاعتي"، هنا
/// "مين اليوزرز اللي عندهم User Permission على المناطق دي" ثم تحويلهم
/// لـ Sales Person عبر `custom_user` (نفس الحقل المستخدم في
/// `resolveCurrentSalesPerson`).
class TeamDashboardScreen extends StatefulWidget {
  const TeamDashboardScreen({super.key});

  @override
  State<TeamDashboardScreen> createState() => _TeamDashboardScreenState();
}

class _TeamDashboardScreenState extends State<TeamDashboardScreen> {
  bool _loading = true;
  String? _error;
  List<_RepSummary> _reps = [];
  num _regionAchieved = 0;
  num _regionExpenses = 0;
  _SortMetric _sortMetric = _SortMetric.sales;

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
      final territories = await ErpService.getUserTerritories();
      if (territories.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'لا توجد مناطق مرتبطة بحسابك';
        });
        return;
      }

      // مهم: المندوبين مربوطين بمناطق فرعية تحت منطقة المدير (مثلاً "خط
      // رشاد سعيد" تحت "وجه بحري")، مش بنفس اسم منطقة المدير حرفيًا —
      // اتأكد ده حيًا. لازم نوسّع لكل المناطق التابعة (أي عمق، عبر حدود
      // NestedSet الحقيقية lft/rgt) قبل ما نسأل مين المستخدمين المرتبطين.
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

      final permissionRows = await ErpService.getList(
        'User Permission',
        filters: [
          ['allow', '=', 'Territory'],
          ['for_value', 'in', allTerritoryNames.toList()],
        ],
        fields: const ['user'],
        limit: 200,
      );
      final userIds = permissionRows
          .map((r) => r['user'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      if (userIds.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'لا يوجد مندوبين مرتبطين بمناطقك حتى الآن';
        });
        return;
      }

      final salesPersonRows = await ErpService.getList(
        'Sales Person',
        filters: [
          ['custom_user', 'in', userIds],
        ],
        fields: const ['name', 'sales_person_name', 'custom_user'],
        limit: 200,
      );

      final summaries = <_RepSummary>[];
      num totalAchieved = 0;
      for (final row in salesPersonRows) {
        final name = row['name'] as String?;
        final userId = row['custom_user'] as String?;
        if (name == null) continue;

        final performance = await ErpService.getMonthPerformanceForSalesPerson(
          name,
        );
        final inFlight = userId != null
            ? await _countInFlightDocuments(userId)
            : 0;

        // عملاء المندوب ده تحديدًا (خطه هو، عبر `Territory.custom_sales_person`)
        // — أساس حساب التحصيل والمديونية الشخصية بتاعته، مش المنطقة كلها.
        final repTerritories = await ErpService.getList(
          'Territory',
          filters: [
            ['custom_sales_person', '=', name],
          ],
          fields: const ['name'],
          limit: 50,
        );
        final repTerritoryNames = repTerritories
            .map((t) => t['name'] as String?)
            .whereType<String>()
            .toList();
        var repCustomers = <String>[];
        if (repTerritoryNames.isNotEmpty) {
          final customers = await ErpService.getList(
            'Customer',
            filters: [
              ['territory', 'in', repTerritoryNames],
            ],
            fields: const ['name'],
            limit: 500,
          );
          repCustomers = customers
              .map((c) => c['name'] as String?)
              .whereType<String>()
              .toList();
        }

        final repExpenses = await _fetchRegionExpensesThisMonth([name]);
        final collections = await _fetchCollectionsThisMonth(repCustomers);
        final debt = await _fetchCurrentDebt(repCustomers);
        final visitCount = await _fetchVisitCountThisMonth(name);

        final achieved = performance?.achievedAmount ?? 0;
        totalAchieved += achieved;
        summaries.add(
          _RepSummary(
            salesPerson: name,
            label: (row['sales_person_name'] as String?) ?? name,
            achieved: achieved,
            target: performance?.targetAmount,
            inFlightCount: inFlight,
            collections: collections,
            expenses: repExpenses,
            debt: debt,
            visitCount: visitCount,
          ),
        );
      }

      final expenses = await _fetchRegionExpensesThisMonth(
        salesPersonRows.map((r) => r['name'] as String?).whereType<String>().toList(),
      );

      _sortSummaries(summaries);

      if (!mounted) return;
      setState(() {
        _reps = summaries;
        _regionAchieved = totalAchieved;
        _regionExpenses = expenses;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loading = false;
        _error = message ?? 'تعذر تحميل بيانات الفريق';
      });
    }
  }

  void _sortSummaries(List<_RepSummary> summaries) {
    switch (_sortMetric) {
      case _SortMetric.sales:
        summaries.sort((a, b) => b.achieved.compareTo(a.achieved));
        break;
      case _SortMetric.collections:
        summaries.sort((a, b) => b.collections.compareTo(a.collections));
        break;
      case _SortMetric.expenses:
        // الأقل مصروفات هو الأفضل هنا — ترتيب تصاعدي.
        summaries.sort((a, b) => a.expenses.compareTo(b.expenses));
        break;
      case _SortMetric.debt:
        // الأقل مديونية على عملائه هو الأفضل — ترتيب تصاعدي.
        summaries.sort((a, b) => a.debt.compareTo(b.debt));
        break;
      case _SortMetric.visits:
        summaries.sort((a, b) => b.visitCount.compareTo(a.visitCount));
        break;
    }
  }

  void _changeSortMetric(_SortMetric metric) {
    setState(() {
      _sortMetric = metric;
      _sortSummaries(_reps);
    });
  }

  /// عدد مستندات المندوب اللي لسه في مسارها (`docstatus=0`) عبر الأربع
  /// دوكتايبس الرئيسية — مؤشر سريع لحجم الشغل اللي لسه معلّق عنده هو،
  /// مش عدد المعلّق عند المدير نفسه (ده أصلاً موجود في "بانتظار موافقتي").
  Future<int> _countInFlightDocuments(String userId) async {
    var total = 0;
    for (final doctype in const [
      'Sales Order',
      'Sales Invoice',
      'Customer',
      'Material Request',
    ]) {
      try {
        final rows = await ErpService.getList(
          doctype,
          filters: [
            ['owner', '=', userId],
            ['docstatus', '=', 0],
          ],
          fields: const ['name'],
          limit: 100,
        );
        total += rows.length;
      } catch (_) {
        // Best-effort per doctype — a permission hiccup on one doesn't
        // hide the others.
      }
    }
    return total;
  }

  Future<num> _fetchRegionExpensesThisMonth(List<String> salesPersons) async {
    if (salesPersons.isEmpty) return 0;
    try {
      final now = DateTime.now();
      final firstOfMonth = DateTime(
        now.year,
        now.month,
        1,
      ).toIso8601String().split('T').first;
      final rows = await ErpService.getList(
        'Expense Claim',
        filters: [
          ['المندوب', 'in', salesPersons],
          ['docstatus', '=', 1],
          ['posting_date', '>=', firstOfMonth],
        ],
        fields: const ['total_claimed_amount'],
        limit: 500,
      );
      num sum = 0;
      for (final r in rows) {
        sum += (r['total_claimed_amount'] as num?) ?? 0;
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  Future<num> _fetchCollectionsThisMonth(List<String> customers) async {
    if (customers.isEmpty) return 0;
    try {
      final now = DateTime.now();
      final firstOfMonth = DateTime(
        now.year,
        now.month,
        1,
      ).toIso8601String().split('T').first;
      final rows = await ErpService.getList(
        'Payment Entry',
        filters: [
          ['party_type', '=', 'Customer'],
          ['party', 'in', customers],
          ['docstatus', '=', 1],
          ['posting_date', '>=', firstOfMonth],
        ],
        fields: const ['paid_amount'],
        limit: 500,
      );
      num sum = 0;
      for (final r in rows) {
        sum += (r['paid_amount'] as num?) ?? 0;
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  Future<num> _fetchCurrentDebt(List<String> customers) async {
    if (customers.isEmpty) return 0;
    try {
      final rows = await ErpService.getList(
        'GL Entry',
        filters: [
          ['party_type', '=', 'Customer'],
          ['party', 'in', customers],
          ['is_cancelled', '=', 0],
        ],
        fields: const ['debit', 'credit'],
        limit: 1000,
      );
      num balance = 0;
      for (final r in rows) {
        balance += ((r['debit'] as num?) ?? 0) - ((r['credit'] as num?) ?? 0);
      }
      return balance;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _fetchVisitCountThisMonth(String salesPerson) async {
    try {
      final now = DateTime.now();
      final firstOfMonth = DateTime(
        now.year,
        now.month,
        1,
      ).toIso8601String().split('T').first;
      final rows = await ErpService.getList(
        'Customer Visit',
        filters: [
          ['sales_person', '=', salesPerson],
          ['visit_datetime', '>=', firstOfMonth],
        ],
        fields: const ['name'],
        limit: 500,
      );
      return rows.length;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('لوحة فريقي')),
      body: SafeArea(
        child: _loading
            ? const LoadingIndicator()
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppColors.accent),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : RefreshIndicator(
                color: AppColors.accent,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _buildRegionSummaryCard(),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'المندوبين',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildSortSelector(),
                    const SizedBox(height: 12),
                    ..._reps.map(_buildRepCard),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildSortSelector() {
    const options = [
      (_SortMetric.sales, 'الأعلى مبيعات'),
      (_SortMetric.collections, 'الأعلى تحصيل'),
      (_SortMetric.expenses, 'الأقل مصروفات'),
      (_SortMetric.debt, 'الأقل مديونية'),
      (_SortMetric.visits, 'الأكثر زيارات'),
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (metric, label) = options[i];
          final selected = _sortMetric == metric;
          return ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 12)),
            selected: selected,
            selectedColor: AppColors.accent,
            labelStyle: TextStyle(
              color: selected ? AppColors.white : AppColors.black,
              fontWeight: FontWeight.w700,
            ),
            onSelected: (_) => _changeSortMetric(metric),
          );
        },
      ),
    );
  }

  Widget _buildRegionSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مبيعات المنطقة هذا الشهر',
                  style: TextStyle(color: AppColors.midGray, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_regionAchieved.toStringAsFixed(0)} ج.م',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 32, color: AppColors.lightGray),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مصروفات المنطقة هذا الشهر',
                  style: TextStyle(color: AppColors.midGray, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_regionExpenses.toStringAsFixed(0)} ج.م',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRepCard(_RepSummary rep) {
    final target = rep.target;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  rep.label,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
              if (rep.inFlightCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${rep.inFlightCount} قيد التنفيذ',
                    style: const TextStyle(fontSize: 10.5, color: AppColors.midGray),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            target != null
                ? '${rep.achieved.toStringAsFixed(0)} / ${target.toStringAsFixed(0)} ج.م'
                : '${rep.achieved.toStringAsFixed(0)} ج.م (لا يوجد هدف محدد)',
            style: const TextStyle(color: AppColors.midGray, fontSize: 12),
          ),
          if (target != null && target > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (rep.achieved / target).clamp(0, 1),
                minHeight: 6,
                backgroundColor: AppColors.lightGray,
                color: rep.achieved >= target ? AppColors.success : AppColors.accent,
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _kpiTile(
                  'تحصيل الشهر',
                  '${rep.collections.toStringAsFixed(0)} ج.م',
                  AppColors.success,
                ),
              ),
              Expanded(
                child: _kpiTile(
                  'مصروفات الشهر',
                  '${rep.expenses.toStringAsFixed(0)} ج.م',
                  AppColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _kpiTile(
                  'مديونية عملائه',
                  '${rep.debt.toStringAsFixed(0)} ج.م',
                  AppColors.black,
                ),
              ),
              Expanded(
                child: _kpiTile(
                  'زيارات الشهر',
                  '${rep.visitCount}',
                  AppColors.black,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kpiTile(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.midGray, fontSize: 10.5),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
