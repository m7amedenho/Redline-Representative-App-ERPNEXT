import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
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

class MaterialRequestScreen extends StatefulWidget {
  const MaterialRequestScreen({super.key});

  @override
  State<MaterialRequestScreen> createState() => _MaterialRequestScreenState();
}

class _MaterialRequestScreenState extends State<MaterialRequestScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final List<_RequestLine> _lines = [];
  DateTime _requiredByDate = DateTime.now();

  List<Map<String, dynamic>> _pendingTransfers = [];
  bool _loadingPending = false;
  bool _pendingFromCache = false;
  String? _pendingError;
  String? _receivingName;
  String? _justReceivedName;
  
  final Map<String, Map<String, double>> _transferQuantities = {};

  List<Map<String, dynamic>> _completedTransfers = [];
  bool _loadingCompleted = false;
  String? _completedError;

  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) setState(() => _error = null);
        if (_tabController.index == 1 &&
            !_tabController.indexIsChanging &&
            _pendingTransfers.isEmpty &&
            !_loadingPending) {
          _loadPendingTransfers();
        }
        if (_tabController.index == 2 &&
            !_tabController.indexIsChanging &&
            _completedTransfers.isEmpty &&
            !_loadingCompleted) {
          _loadCompletedTransfers();
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
        setState(() {
          _loadingPending = false;
          _pendingError = 'لا يوجد سجل مندوب مرتبط بحسابك';
        });
        return;
      }
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'Stock Entry_pending_transfers',
        cacheKey: salesPerson,
        onCacheHit: (cached) {
          if (!mounted) return;
          _updateTransfers(cached.rows, cached.fromCache);
        },
        fetch: () async {
          final list = await ErpService.callMethodList(
            '/api/method/red_app.api.get_pending_transfers',
            params: {'sales_person': salesPerson},
          );
          return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        },
      );
      if (!mounted) return;
      _updateTransfers(result.rows, result.fromCache);
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

  void _updateTransfers(List<Map<String, dynamic>> rows, bool fromCache) {
    setState(() {
      _pendingTransfers = rows;
      _pendingFromCache = fromCache;
      _loadingPending = false;
      
      for (final row in rows) {
        final name = row['name'] as String;
        if (!_transferQuantities.containsKey(name)) {
          final items = row['items'] as List? ?? [];
          final qtys = <String, double>{};
          for (final item in items) {
             if (item is Map) {
               final itemCode = item['item_code']?.toString() ?? '';
               final qty = (item['qty'] as num?)?.toDouble() ?? 0.0;
               if (itemCode.isNotEmpty) qtys[itemCode] = qty;
             }
          }
          _transferQuantities[name] = qtys;
        }
      }
    });
  }

  Future<void> _loadCompletedTransfers() async {
    setState(() {
      _loadingCompleted = true;
      _completedError = null;
    });
    try {
      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson == null) {
        setState(() {
          _loadingCompleted = false;
          _completedError = 'لا يوجد سجل مندوب مرتبط بحسابك';
        });
        return;
      }
      final result = await CacheService.getListStaleWhileRevalidate(
        cacheDoctype: 'Stock Entry_completed_transfers',
        cacheKey: salesPerson,
        onCacheHit: (cached) {
          if (!mounted) return;
          setState(() {
            _completedTransfers = cached.rows;
            _loadingCompleted = false;
          });
        },
        fetch: () async {
          final list = await ErpService.callMethodList(
            '/api/method/red_app.api.get_completed_transfers',
            params: {'sales_person': salesPerson},
          );
          return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        },
      );
      if (!mounted) return;
      setState(() {
        _completedTransfers = result.rows;
        _loadingCompleted = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_completedTransfers.isNotEmpty) {
        setState(() => _loadingCompleted = false);
        return;
      }
      final message = handleErpError(context, e);
      setState(() {
        _loadingCompleted = false;
        _completedError = message ?? 'تعذر تحميل الشحنات السابقة';
      });
    }
  }

  Future<bool> _receiveTransfer(String stockEntryName) async {
    setState(() => _receivingName = stockEntryName);
    
    try {
      final qtys = _transferQuantities[stockEntryName] ?? {};
      final itemsToSubmit = qtys.entries
          .where((e) => e.value > 0)
          .map((e) => {'item_code': e.key, 'qty': e.value})
          .toList();
          
      if (itemsToSubmit.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يمكن استلام كمية صفر لجميع الأصناف')),
        );
        setState(() => _receivingName = null);
        return false;
      }

      await ErpService.confirmMaterialReceipt(
        stockEntryName: stockEntryName,
        items: itemsToSubmit,
      );
      
      if (!mounted) return false;
      
      setState(() {
        _justReceivedName = stockEntryName;
        _receivingName = null;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم تحديث حالة المخزون بنجاح ✅', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: AppColors.success,
        ),
      );
      
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return true;
      
      setState(() {
        final idx = _pendingTransfers.indexWhere((r) => r['name'] == stockEntryName);
        if (idx != -1) {
          final confirmed = _pendingTransfers[idx];
          _pendingTransfers.removeAt(idx);
          _completedTransfers.insert(0, confirmed);
        }
        _justReceivedName = null;
      });
      
      return true;
    } catch (e) {
      if (!mounted) return false;
      handleErpError(context, e);
      setState(() => _receivingName = null);
      return false;
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
          filters: query.isEmpty ? null : [['item_name', 'like', '%$query%']],
          fields: const ['name', 'item_name'],
          limit: 20,
        );
        return list.map((i) => PickedRecord(name: i['name'] as String, label: (i['item_name'] as String?) ?? i['name'] as String)).toList();
      },
    );

    if (result == null) return;
    setState(() => _lines.add(_RequestLine(itemCode: result.name, itemName: result.label)));
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
      'items': _lines.map((l) => {'item_code': l.itemCode, 'qty': l.qty}).toList(),
    };

    try {
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(type: SyncJobType.materialRequestCreate, payload: fields);
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(() => _lines.clear());
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا يوجد اتصال — تم الحفظ وسيُرسل تلقائيًا')));
        return true;
      }
      final created = await ErpService.createDoc('Material Request', fields);
      if (!mounted) return true;
      setState(() => _lines.clear());
      final createdName = created['name'] as String?;
      if (createdName != null) {
        context.push(documentDetailRoute('Material Request', createdName));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إنشاء طلب المواد بنجاح')));
      }
      return true;
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await SyncEngine().enqueue(type: SyncJobType.materialRequestCreate, payload: fields);
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(() => _lines.clear());
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الاتصال — تم الحفظ وسيُرسل تلقائيًا')));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('المخزون'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.black,
          indicatorColor: AppColors.accent,
          tabs: const [
            Tab(text: 'طلب مواد'),
            Tab(text: 'شحنات في طريقي'),
            Tab(text: 'شحنات سابقة'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildRequestTab(),
            _buildPendingTransfersTab(),
            _buildCompletedTransfersTab(),
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
                          onPressed: line.qty > 1 ? () => setState(() => line.qty -= 1) : null,
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

  Widget _buildPendingTransfersTab() {
    if (_loadingPending) return const LoadingIndicator();
    if (_pendingError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_pendingError!, style: const TextStyle(color: AppColors.accent), textAlign: TextAlign.center),
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
                final justReceived = _justReceivedName == name;
                final items = row['items'] as List? ?? [];
                
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: justReceived ? Colors.green.shade50 : AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(
                      color: justReceived ? Colors.green : Colors.transparent,
                      width: justReceived ? 2 : 0,
                    ),
                  ),
                  child: Card(
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
                    clipBehavior: Clip.antiAlias,
                    elevation: 0,
                    color: Colors.transparent,
                    child: ExpansionTile(
                      title: Row(
                        children: [
                          Icon(
                            justReceived ? Icons.check_circle : Icons.local_shipping_rounded,
                            color: justReceived ? Colors.green : AppColors.accent,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700, 
                                    fontSize: 15,
                                    color: justReceived ? Colors.green.shade700 : AppColors.black,
                                  ),
                                ),
                                if (row['posting_date'] != null)
                                  Text(
                                    row['posting_date'].toString(),
                                    style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                          if (!justReceived) RowSyncIcon(fromCache: _pendingFromCache),
                        ],
                      ),
                      children: [
                        const Divider(height: 1),
                        Container(
                          padding: const EdgeInsets.all(16),
                          color: AppColors.lightGray.withValues(alpha: 0.3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'الأصناف المستلمة (تأكد من الكمية في حالة النواقص):',
                                style: TextStyle(fontSize: 13, color: AppColors.midGray, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 12),
                              ...items.map((item) {
                                if (item is! Map) return const SizedBox();
                                final itemCode = item['item_code']?.toString() ?? '';
                                final itemName = item['item_name']?.toString() ?? itemCode;
                                final originalQty = (item['qty'] as num?)?.toDouble() ?? 0.0;
                                final uom = item['uom']?.toString() ?? '';
                                final currentQty = _transferQuantities[name]?[itemCode] ?? 0.0;
                                
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          itemName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        decoration: BoxDecoration(
                                          color: AppColors.white,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: AppColors.lightGray),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.remove, size: 18, color: AppColors.midGray),
                                              onPressed: currentQty > 0 ? () {
                                                setState(() => _transferQuantities[name]?[itemCode] = currentQty - 1);
                                              } : null,
                                              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                              padding: EdgeInsets.zero,
                                            ),
                                            Container(
                                              width: 40,
                                              alignment: Alignment.center,
                                              child: Text(
                                                currentQty.toStringAsFixed(currentQty.truncateToDouble() == currentQty ? 0 : 2),
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.add, size: 18, color: AppColors.accent),
                                              onPressed: currentQty < originalQty ? () {
                                                setState(() => _transferQuantities[name]?[itemCode] = currentQty + 1);
                                              } : null,
                                              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                              padding: EdgeInsets.zero,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                              const SizedBox(height: 16),
                              if (justReceived)
                                const Center(
                                  child: Text('تم تأكيد الاستلام بنجاح ✅', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16)),
                                )
                              else
                                Opacity(
                                  opacity: receiving ? 0.5 : 1.0,
                                  child: IgnorePointer(
                                    ignoring: receiving,
                                    child: SwipeToConfirmButton(
                                      label: 'اسحب لتأكيد الاستلام',
                                      confirmedLabel: 'تم التأكيد',
                                      onConfirmed: () => _receiveTransfer(name),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildCompletedTransfersTab() {
    if (_loadingCompleted) return const LoadingIndicator();
    if (_completedError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_completedError!, style: const TextStyle(color: AppColors.accent), textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadCompletedTransfers,
      child: _completedTransfers.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(20),
              children: [_emptyCard('لم تقم باستلام أي شحنات سابقة')],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _completedTransfers.length,
              itemBuilder: (context, index) {
                final row = _completedTransfers[index];
                final name = row['name'] as String;
                final items = row['items'] as List? ?? [];
                
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    side: BorderSide(color: Colors.green.shade200, width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  elevation: 0,
                  color: AppColors.white,
                  child: ExpansionTile(
                    title: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.green.shade800),
                              ),
                              if (row['posting_date'] != null)
                                Text(
                                  row['posting_date'].toString(),
                                  style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    children: [
                      const Divider(height: 1),
                      Container(
                        padding: const EdgeInsets.all(16),
                        color: AppColors.lightGray.withValues(alpha: 0.3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: items.map((item) {
                            if (item is! Map) return const SizedBox();
                            final itemCode = item['item_code']?.toString() ?? '';
                            final itemName = item['item_name']?.toString() ?? itemCode;
                            final qty = (item['qty'] as num?)?.toDouble() ?? 0.0;
                            
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      itemName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                  Text(
                                    qty.toStringAsFixed(qty.truncateToDouble() == qty ? 0 : 2),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
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
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Center(child: Text(text, style: const TextStyle(color: AppColors.midGray))),
    );
  }

  Widget _errorRow() {
    return Row(
      children: [
        const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 16),
        const SizedBox(width: 6),
        Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.accent, fontSize: 13))),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800));
  }
}
