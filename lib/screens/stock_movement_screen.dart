import 'package:flutter/material.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_picker.dart';

class _MovementRow {
  const _MovementRow({
    required this.itemCode,
    required this.itemName,
    required this.warehouse,
    required this.warehouseLabel,
    required this.postingDate,
    required this.qty,
    required this.qtyAfter,
    required this.voucherType,
    required this.voucherNo,
  });

  final String itemCode;
  final String itemName;
  final String warehouse;
  final String warehouseLabel;
  final String postingDate;
  final double qty;
  final double qtyAfter;
  final String voucherType;
  final String voucherNo;
}

/// حركة المخزون — يعرض `Stock Ledger Entry` الحقيقية (نفس الدوكتايب اللي
/// فرابي بيسجل بيه كل حركة صنف/مخزن)، مقصور دايمًا على المخازن اللي
/// المندوب نفسه مسموح له بيها: `Sales Person.custom_car_warehouse`
/// (مخزن السيارة الشخصي) + `custom_transit_warehouse` (مخزن الترانزيت
/// بتاع منطقته) — نفس الحقلين المستخدمين فعليًا على السيرفر لتحديد مخازن
/// المندوب، اتأكدوا حيًا. "حركة المخزن" = كل الحركات في المخازن دي، و
/// "حركة صنف" = نفس الحركات لكن مفلترة على صنف واحد يتم اختياره.
///
/// `Stock User` role (المندوبين حاملينها فعليًا) عندها `read` على
/// `Stock Ledger Entry` — مفيش صلاحيات إضافية مطلوبة.
class StockMovementScreen extends StatefulWidget {
  const StockMovementScreen({super.key});

  @override
  State<StockMovementScreen> createState() => _StockMovementScreenState();
}

class _StockMovementScreenState extends State<StockMovementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  bool _loadingWarehouses = true;
  String? _warehousesError;
  final Map<String, String> _allowedWarehouses = {}; // name -> label
  String? _selectedWarehouse; // null = كل المخازن المسموحة

  // "حركة المخزن" tab.
  bool _loadingWarehouseMovements = false;
  List<_MovementRow> _warehouseMovements = [];
  String? _warehouseMovementsError;

  // "حركة صنف" tab.
  PickedRecord? _selectedItem;
  bool _loadingItemMovements = false;
  List<_MovementRow> _itemMovements = [];
  String? _itemMovementsError;

  final Map<String, String> _itemNameCache = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson == null) {
        setState(() {
          _loadingWarehouses = false;
          _warehousesError = 'تعذر تحديد المندوب الحالي';
        });
        return;
      }

      final spDoc = await ErpService.getDoc('Sales Person', salesPerson);
      final candidates = <String>{};
      final car = spDoc['custom_car_warehouse'] as String?;
      final transit = spDoc['custom_transit_warehouse'] as String?;
      if (car != null && car.isNotEmpty) candidates.add(car);
      if (transit != null && transit.isNotEmpty) candidates.add(transit);

      if (candidates.isEmpty) {
        setState(() {
          _loadingWarehouses = false;
          _warehousesError = 'لا يوجد مخزن مرتبط بحسابك';
        });
        return;
      }

      final rows = await ErpService.getList(
        'Warehouse',
        filters: [
          ['name', 'in', candidates.toList()],
        ],
        fields: const ['name', 'warehouse_name'],
        limit: candidates.length,
      );
      if (!mounted) return;
      setState(() {
        for (final r in rows) {
          final name = r['name'] as String;
          _allowedWarehouses[name] =
              (r['warehouse_name'] as String?) ?? name;
        }
        _loadingWarehouses = false;
      });
      await _loadWarehouseMovements();
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loadingWarehouses = false;
        _warehousesError = message ?? 'تعذر تحميل بيانات المخازن';
      });
    }
  }

  List<String> get _activeWarehouseFilter {
    final selected = _selectedWarehouse;
    if (selected != null) return [selected];
    return _allowedWarehouses.keys.toList();
  }

  Future<void> _resolveItemNames(Iterable<String> itemCodes) async {
    final missing = itemCodes.where((c) => !_itemNameCache.containsKey(c)).toSet();
    if (missing.isEmpty) return;
    try {
      final rows = await ErpService.getList(
        'Item',
        filters: [
          ['name', 'in', missing.toList()],
        ],
        fields: const ['name', 'item_name'],
        limit: missing.length,
      );
      for (final r in rows) {
        final name = r['name'] as String;
        _itemNameCache[name] = (r['item_name'] as String?) ?? name;
      }
    } catch (_) {
      // Best-effort — falls back to showing the raw item code.
    }
  }

  List<_MovementRow> _mapRows(List<Map<String, dynamic>> raw) {
    return raw.map((r) {
      final itemCode = (r['item_code'] as String?) ?? '';
      final warehouse = (r['warehouse'] as String?) ?? '';
      return _MovementRow(
        itemCode: itemCode,
        itemName: _itemNameCache[itemCode] ?? itemCode,
        warehouse: warehouse,
        warehouseLabel: _allowedWarehouses[warehouse] ?? warehouse,
        postingDate: (r['posting_date'] as String?) ?? '',
        qty: (r['actual_qty'] as num?)?.toDouble() ?? 0,
        qtyAfter: (r['qty_after_transaction'] as num?)?.toDouble() ?? 0,
        voucherType: (r['voucher_type'] as String?) ?? '',
        voucherNo: (r['voucher_no'] as String?) ?? '',
      );
    }).toList();
  }

  Future<void> _loadWarehouseMovements() async {
    if (_allowedWarehouses.isEmpty) return;
    setState(() {
      _loadingWarehouseMovements = true;
      _warehouseMovementsError = null;
    });
    try {
      final rows = await ErpService.getList(
        'Stock Ledger Entry',
        filters: [
          ['warehouse', 'in', _activeWarehouseFilter],
          ['is_cancelled', '=', 0],
        ],
        fields: const [
          'item_code',
          'warehouse',
          'posting_date',
          'actual_qty',
          'qty_after_transaction',
          'voucher_type',
          'voucher_no',
        ],
        orderBy: 'posting_datetime desc',
        limit: 100,
      );
      await _resolveItemNames(rows.map((r) => (r['item_code'] as String?) ?? ''));
      if (!mounted) return;
      setState(() {
        _warehouseMovements = _mapRows(rows);
        _loadingWarehouseMovements = false;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loadingWarehouseMovements = false;
        _warehouseMovementsError = message ?? 'تعذر تحميل حركة المخزن';
      });
    }
  }

  Future<void> _pickItem() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر صنف',
      search: (query) async {
        final list = await ErpService.getList(
          'Item',
          filters: query.isEmpty
              ? null
              : [
                  ['item_name', 'like', '%$query%'],
                ],
          fields: const ['name', 'item_name'],
          limit: 20,
        );
        return list
            .map(
              (i) => PickedRecord(
                name: i['name'] as String,
                label: (i['item_name'] as String?) ?? i['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result == null) return;
    setState(() => _selectedItem = result);
    await _loadItemMovements();
  }

  Future<void> _loadItemMovements() async {
    final item = _selectedItem;
    if (item == null || _allowedWarehouses.isEmpty) return;
    setState(() {
      _loadingItemMovements = true;
      _itemMovementsError = null;
    });
    try {
      final rows = await ErpService.getList(
        'Stock Ledger Entry',
        filters: [
          ['item_code', '=', item.name],
          ['warehouse', 'in', _activeWarehouseFilter],
          ['is_cancelled', '=', 0],
        ],
        fields: const [
          'item_code',
          'warehouse',
          'posting_date',
          'actual_qty',
          'qty_after_transaction',
          'voucher_type',
          'voucher_no',
        ],
        orderBy: 'posting_datetime desc',
        limit: 100,
      );
      _itemNameCache[item.name] = item.label;
      if (!mounted) return;
      setState(() {
        _itemMovements = _mapRows(rows);
        _loadingItemMovements = false;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loadingItemMovements = false;
        _itemMovementsError = message ?? 'تعذر تحميل حركة الصنف';
      });
    }
  }

  Future<void> _openWarehouseFilter() async {
    if (_allowedWarehouses.length <= 1) return;
    final selected = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'اختر المخزن',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              ListTile(
                title: const Text('كل المخازن المتاحة لك'),
                trailing: _selectedWarehouse == null
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.of(context).pop<String?>(null),
              ),
              ..._allowedWarehouses.entries.map(
                (e) => ListTile(
                  title: Text(e.value),
                  trailing: _selectedWarehouse == e.key
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop<String?>(e.key),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    setState(() => _selectedWarehouse = selected);
    await Future.wait([_loadWarehouseMovements(), _loadItemMovements()]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('حركة المخزون'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.midGray,
          indicatorColor: AppColors.accent,
          tabs: const [Tab(text: 'حركة المخزن'), Tab(text: 'حركة صنف')],
        ),
        actions: [
          if (_allowedWarehouses.length > 1)
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: _openWarehouseFilter,
            ),
        ],
      ),
      body: SafeArea(
        child: _loadingWarehouses
            ? const LoadingIndicator()
            : _warehousesError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _warehousesError!,
                    style: const TextStyle(color: AppColors.accent),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : TabBarView(
                controller: _tabController,
                children: [_buildWarehouseTab(), _buildItemTab()],
              ),
      ),
    );
  }

  Widget _buildWarehouseTab() {
    if (_loadingWarehouseMovements) return const LoadingIndicator();
    if (_warehouseMovementsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _warehouseMovementsError!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_warehouseMovements.isEmpty) {
      return const Center(
        child: Text('لا توجد حركات', style: TextStyle(color: AppColors.midGray)),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadWarehouseMovements,
      child: _buildMovementList(_warehouseMovements),
    );
  }

  Widget _buildItemTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(AppRadius.field),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.field),
              onTap: _pickItem,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: AppColors.midGray),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _selectedItem?.label ?? 'اختر صنف لعرض حركته',
                        style: TextStyle(
                          color: _selectedItem == null
                              ? AppColors.midGray
                              : AppColors.black,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(child: _buildItemTabBody()),
      ],
    );
  }

  Widget _buildItemTabBody() {
    if (_selectedItem == null) {
      return const Center(
        child: Text('اختر صنف عشان تشوف حركته', style: TextStyle(color: AppColors.midGray)),
      );
    }
    if (_loadingItemMovements) return const LoadingIndicator();
    if (_itemMovementsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _itemMovementsError!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_itemMovements.isEmpty) {
      return const Center(
        child: Text('لا توجد حركات لهذا الصنف', style: TextStyle(color: AppColors.midGray)),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadItemMovements,
      child: _buildMovementList(_itemMovements, showItemName: false),
    );
  }

  Widget _buildMovementList(List<_MovementRow> rows, {bool showItemName = true}) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: rows.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final row = rows[i];
        final incoming = row.qty >= 0;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (incoming ? AppColors.success : AppColors.accent)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  incoming
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  color: incoming ? AppColors.success : AppColors.accent,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      showItemName ? row.itemName : row.warehouseLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${showItemName ? row.warehouseLabel : row.itemName} • ${row.voucherType} ${row.voucherNo} • ${row.postingDate}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${incoming ? '+' : ''}${row.qty.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: incoming ? AppColors.success : AppColors.accent,
                    ),
                  ),
                  Text(
                    'الرصيد: ${row.qtyAfter.toStringAsFixed(2)}',
                    style: const TextStyle(color: AppColors.midGray, fontSize: 10.5),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
