import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/auth_service.dart';
import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/row_sync_icon.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';
import 'document_detail_screen.dart';

class _RequestLine {
  _RequestLine({required this.itemCode, required this.itemName});

  final String itemCode;
  final String itemName;
  double qty = 1;
}

/// Material Request screen — three tabs. Transfer is a two-leg in-transit
/// flow, not a direct move: the server already has real transit warehouses
/// provisioned and `custom_sales_rep`/`custom_is_received` custom fields on
/// Stock Entry, so this screen completes that design instead of bypassing
/// it.
/// - "طلب مواد": `POST /api/resource/Material Request` (standard REST,
///   `material_request_type`/`items[].item_code`/`qty` are standard ERPNext
///   field names, not confirmed against this specific site — see
///   docs/API_INTEGRATION_NOTES.md).
/// - "استلام" (leg 1 — warehouse keeper): `GET
///   .../material_request.make_in_transit_stock_entry` (confirmed,
///   `source_name` + `in_transit_warehouse` both required) then POST the
///   returned draft to `/api/resource/Stock Entry`, after stamping
///   `custom_sales_rep` (the Material Request owner's Sales Person, so it
///   shows up in their own "استلام النقل" tab). The receiving warehouse is
///   picked from `GET /api/resource/Warehouse` (real non-group,
///   non-disabled warehouses only) via [showSearchPicker] — deliberately
///   not free text, since sending a stock entry to a mistyped/nonexistent
///   warehouse is a real operational risk.
/// - "استلام النقل" (leg 2 — the rep themself): lists every `Stock Entry`
///   with `custom_sales_rep = me` and `custom_is_received = 0`; "تم
///   الاستلام" calls the confirmed
///   `erpnext...stock_entry.make_stock_in_entry` RPC to create the real
///   transit→destination Stock Entry, then flags the leg-1 entry received.
class MaterialRequestScreen extends StatefulWidget {
  const MaterialRequestScreen({super.key});

  @override
  State<MaterialRequestScreen> createState() => _MaterialRequestScreenState();
}

class _MaterialRequestScreenState extends State<MaterialRequestScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // "طلب مواد" tab state.
  final List<_RequestLine> _lines = [];
  DateTime _requiredByDate = DateTime.now();

  // "استلام" tab state.
  PickedRecord? _sourceRequest;
  PickedRecord? _warehouse;

  // "استلام النقل" tab state — نقلات ترانزيت وصلت لمندوب معيّن ولسه
  // محتاجة تأكيد استلام (الخطوة الثانية، `custom_is_received`).
  List<Map<String, dynamic>> _pendingTransfers = [];
  bool _loadingPending = false;
  bool _pendingFromCache = false;
  String? _pendingError;
  String? _receivingName;

  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) setState(() => _error = null);
        if (_tabController.index == 2 &&
            !_tabController.indexIsChanging &&
            _pendingTransfers.isEmpty &&
            !_loadingPending) {
          _loadPendingTransfers();
        }
      });
  }

  Future<void> _loadPendingTransfers() async {
    setState(() {
      _loadingPending = true;
      _pendingError = null;
    });
    try {
      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson == null) {
        // Same diagnostic upgrade as `StockMovementScreen` — surfaces the
        // exact user id to check against `Sales Person.custom_user` in
        // Desk instead of a dead-end "couldn't determine" message.
        final userId = await AuthService.currentUserId();
        setState(() {
          _loadingPending = false;
          _pendingError = userId != null
              ? 'لا يوجد سجل "مندوب مبيعات" (Sales Person) مرتبط بحسابك '
                    '($userId) — افتح سجل مندوبك في Sales Person وتأكد إن '
                    'حقل "مستخدم التطبيق المرتبط" (custom_user) يساوي '
                    'هذا البريد بالضبط.'
              : 'تعذر تحديد هوية المستخدم الحالي — تحقق من الاتصال '
                    'بالإنترنت وحاول تسجيل الدخول من جديد.';
        });
        return;
      }
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'Stock Entry_pending_transfers',
        cacheKey: salesPerson,
        onCacheHit: (cached) {
          if (!mounted) return;
          setState(() {
            _pendingTransfers = cached.rows;
            _pendingFromCache = true;
            _loadingPending = false;
          });
        },
        fetch: () => ErpService.getList(
          'Stock Entry',
          filters: [
            ['custom_sales_rep', '=', salesPerson],
            ['custom_is_received', '=', 0],
            ['docstatus', '=', 1],
          ],
          fields: const ['name', 'posting_date'],
          limit: 50,
        ),
      );
      if (!mounted) return;
      setState(() {
        _pendingTransfers = result.rows;
        _pendingFromCache = result.fromCache;
        _loadingPending = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_pendingTransfers.isNotEmpty) {
        setState(() => _loadingPending = false);
        return;
      }
      final message = handleErpError(context, e);
      setState(() {
        _loadingPending = false;
        _pendingError = message ?? 'تعذر تحميل النقلات بانتظار الاستلام';
      });
    }
  }

  Future<void> _receiveTransfer(String stockEntryName) async {
    setState(() => _receivingName = stockEntryName);
    try {
      final draft = await ErpService.makeStockInEntry(stockEntryName);
      final created = await ErpService.createDoc('Stock Entry', draft);
      final createdName = created['name'] as String?;
      if (createdName != null) {
        await ErpService.submitDoc('Stock Entry', createdName);
      }
      await ErpService.updateDoc('Stock Entry', stockEntryName, {
        'custom_is_received': 1,
      });
      if (!mounted) return;
      setState(() {
        _pendingTransfers = _pendingTransfers
            .where((r) => r['name'] != stockEntryName)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تسجيل استلام النقل بنجاح')),
      );
    } catch (e) {
      if (!mounted) return;
      handleErpError(context, e);
    } finally {
      if (mounted) setState(() => _receivingName = null);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر صنف',
      hintText: 'ابحث باسم الصنف...',
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
    setState(() {
      _lines.add(_RequestLine(itemCode: result.name, itemName: result.label));
    });
  }

  Future<void> _pickRequiredByDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _requiredByDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _requiredByDate = picked);
  }

  Future<void> _pickSourceRequest() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر طلب مواد',
      hintText: 'ابحث برقم الطلب...',
      search: (query) async {
        final list = await ErpService.getList(
          'Material Request',
          filters: [
            ['material_request_type', '=', 'Material Transfer'],
            ['status', '=', 'Submitted'],
            if (query.isNotEmpty) ['name', 'like', '%$query%'],
          ],
          fields: const ['name'],
          limit: 20,
        );
        return list
            .map((r) => PickedRecord(name: r['name'] as String, label: r['name'] as String))
            .toList();
      },
    );

    if (result == null) return;
    setState(() => _sourceRequest = result);
  }

  Future<void> _pickWarehouse() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر مخزن الاستلام',
      hintText: 'ابحث باسم المخزن...',
      search: (query) async {
        final list = await ErpService.getList(
          'Warehouse',
          filters: [
            ['disabled', '=', 0],
            ['is_group', '=', 0],
            if (query.isNotEmpty) ['warehouse_name', 'like', '%$query%'],
          ],
          fields: const ['name', 'warehouse_name'],
          limit: 20,
        );
        return list
            .map(
              (w) => PickedRecord(
                name: w['name'] as String,
                label: (w['warehouse_name'] as String?) ?? w['name'] as String,
              ),
            )
            .toList();
      },
    );

    if (result == null) return;
    setState(() => _warehouse = result);
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submitRequest() async {
    if (_lines.isEmpty) return false;

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    final fields = {
      'material_request_type': 'Material Transfer',
      'schedule_date': _requiredByDate.toIso8601String().split('T').first,
      'items': _lines
          .map((l) => {'item_code': l.itemCode, 'qty': l.qty})
          .toList(),
    };

    try {
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.materialRequestCreate,
          payload: fields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(() => _lines.clear());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم الحفظ وسيُرسل تلقائيًا'),
          ),
        );
        return true;
      }

      final created = await ErpService.createDoc('Material Request', fields);

      if (!mounted) return true;
      setState(() => _lines.clear());

      final createdName = created['name'] as String?;
      if (createdName != null) {
        context.push(documentDetailRoute('Material Request', createdName));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إنشاء طلب المواد بنجاح')),
        );
      }
      return true;
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await SyncEngine().enqueue(
          type: SyncJobType.materialRequestCreate,
          payload: fields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(() => _lines.clear());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم الحفظ وسيُرسل تلقائيًا'),
          ),
        );
        return true;
      }
      if (!mounted) return false;
      final message = handleErpError(context, e);
      if (message != null) setState(() => _error = message);
      return false;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submitReceipt() async {
    final source = _sourceRequest;
    final warehouse = _warehouse;
    if (source == null || warehouse == null) return false;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final draft = await ErpService.makeInTransitStockEntry(
        sourceName: source.name,
        inTransitWarehouse: warehouse.name,
      );

      // اربط النقل بالمندوب صاحب الطلب الأصلي (`custom_sales_rep`، Link →
      // Sales Person) عشان يظهر لاحقًا في تبويب "استلام النقل" بتاعه هو.
      // Best-effort — لو مقدرناش نحدده، النقل لسه يتسجل عادي، بس مش هيظهر
      // في قايمة استلام أي مندوب لحد ما حد يظبطه يدويًا من السيرفر.
      try {
        final mrDoc = await ErpService.getDoc('Material Request', source.name);
        final ownerId = mrDoc['owner'] as String?;
        if (ownerId != null) {
          final spRows = await ErpService.getList(
            'Sales Person',
            filters: [
              ['custom_user', '=', ownerId],
            ],
            fields: const ['name'],
            limit: 1,
          );
          if (spRows.isNotEmpty) {
            draft['custom_sales_rep'] = spRows.first['name'];
          }
        }
      } catch (_) {
        // Best-effort — see comment above.
      }

      final created = await ErpService.createDoc('Stock Entry', draft);

      if (!mounted) return true;
      setState(() {
        _sourceRequest = null;
        _warehouse = null;
      });

      final createdName = created['name'] as String?;
      if (createdName != null) {
        context.push(documentDetailRoute('Stock Entry', createdName));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل الاستلام بنجاح')),
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      final message = handleErpError(context, e);
      if (message != null) setState(() => _error = message);
      return false;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('طلب المواد'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.black,
          indicatorColor: AppColors.accent,
          tabs: const [
            Tab(text: 'طلب مواد'),
            Tab(text: 'استلام'),
            Tab(text: 'استلام النقل'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildRequestTab(),
            _buildReceiptTab(),
            _buildPendingTransfersTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestTab() {
    final canSubmit = _lines.isNotEmpty && !_submitting;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _sectionTitle('مطلوب بتاريخ'),
              const SizedBox(height: 8),
              Material(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: _pickRequiredByDate,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.event_rounded, color: AppColors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _requiredByDate.toIso8601String().split('T').first,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _sectionTitle('الأصناف'),
                  TextButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('إضافة صنف'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_lines.isEmpty)
                _emptyCard('لم تُضف أي أصناف بعد')
              else
                ..._lines.asMap().entries.map((entry) {
                  final index = entry.key;
                  final line = entry.value;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            line.itemName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                          color: AppColors.midGray,
                          onPressed: line.qty > 1
                              ? () => setState(() => line.qty -= 1)
                              : null,
                        ),
                        SizedBox(
                          width: 28,
                          child: Text(
                            line.qty.toStringAsFixed(0),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          color: AppColors.accent,
                          onPressed: () => setState(() => line.qty += 1),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: AppColors.midGray),
                          onPressed: () => setState(() => _lines.removeAt(index)),
                        ),
                      ],
                    ),
                  );
                }),
              if (_error != null) ...[const SizedBox(height: 12), _errorRow()],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Opacity(
            opacity: canSubmit ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !canSubmit,
              child: SwipeToConfirmButton(
                label: 'اسحب لإرسال طلب المواد',
                confirmedLabel: 'تم إرسال الطلب',
                onConfirmed: _submitRequest,
                wasQueued: () => _lastSubmitWasQueued,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReceiptTab() {
    final canSubmit = _sourceRequest != null && _warehouse != null && !_submitting;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _sectionTitle('طلب المواد المرجعي'),
              const SizedBox(height: 8),
              Material(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: _pickSourceRequest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.local_shipping_rounded, color: AppColors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _sourceRequest?.label ?? 'اختر طلب المواد',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _sectionTitle('مخزن الاستلام'),
              const SizedBox(height: 8),
              Material(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: _pickWarehouse,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.warehouse_rounded, color: AppColors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _warehouse?.label ?? 'اختر مخزن الاستلام',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
                      ],
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[const SizedBox(height: 12), _errorRow()],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Opacity(
            opacity: canSubmit ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !canSubmit,
              child: SwipeToConfirmButton(
                label: 'اسحب لتأكيد الاستلام',
                confirmedLabel: 'تم الاستلام',
                onConfirmed: _submitReceipt,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPendingTransfersTab() {
    if (_loadingPending) return const LoadingIndicator();
    if (_pendingError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _pendingError!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadPendingTransfers,
      child: _pendingTransfers.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(20),
              children: [_emptyCard('لا توجد نقلات بانتظار استلامك حاليًا')],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _pendingTransfers.length,
              itemBuilder: (context, index) {
                final row = _pendingTransfers[index];
                final name = row['name'] as String;
                final receiving = _receivingName == name;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.local_shipping_rounded,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            if (row['posting_date'] != null)
                              Text(
                                row['posting_date'].toString(),
                                style: const TextStyle(
                                  color: AppColors.midGray,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      RowSyncIcon(fromCache: _pendingFromCache),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: receiving
                            ? null
                            : () => _receiveTransfer(name),
                        child: receiving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.white,
                                ),
                              )
                            : const Text('تم الاستلام'),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Center(child: Text(text, style: const TextStyle(color: AppColors.midGray))),
    );
  }

  Widget _errorRow() {
    return Row(
      children: [
        const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.accent, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800));
  }
}
