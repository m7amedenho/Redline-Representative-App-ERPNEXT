import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../utils/html_text.dart';
import '../widgets/log_visit_prompt.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';
import 'all_sales_invoices_screen.dart';
import 'document_detail_screen.dart';

class _InvoiceLine {
  _InvoiceLine({
    required this.itemCode,
    required this.itemName,
    this.sourceRow,
  });

  final String itemCode;
  final String itemName;
  double qty = 1;

  /// Best-effort — see the class doc comment on pricing. Null means
  /// "unavailable", not zero.
  num? unitPrice;

  /// Set whenever [unitPrice] stays null, explaining exactly why — shown
  /// instead of a generic "unavailable" so the real cause is visible.
  String? priceStatus;

  /// Explicit override only — same rationale as `_OrderLine.warehouse` in
  /// SalesOrderScreen: null lets the server auto-default it (the rep's own
  /// vehicle warehouse), only set when the rep deliberately picks a
  /// different one via [SearchPicker] on the `Warehouse` DocType. Also the
  /// warehouse actually deducted from (or credited back to, for a return)
  /// once stock is updated — see `_SalesInvoiceScreenState._submit`'s
  /// `update_stock` field.
  String? warehouse;

  /// Set only for items with `Item.has_batch_no = 1` — the specific batch
  /// this line is drawn from, and how much of it is actually available
  /// (real-time, via `ErpService.getAvailableBatches`) and when it expires
  /// (if `has_expiry_date` is also set). A batch-tracked item can never be
  /// added to the invoice without one — see `_pickBatchForLine`. [warehouse]
  /// is set alongside this to the exact warehouse the chosen batch is
  /// sitting in (not the rep's default), since a batch only means anything
  /// in the specific warehouse the goods were actually transferred into.
  String? batchNo;
  double? batchAvailableQty;
  String? batchExpiryDate;

  /// The original item row from a source Sales Order/Sales Invoice draft
  /// (`make_sales_invoice`/`make_sales_return`) — carried through so
  /// submit can send its linking fields (`sales_order`/`so_detail`/etc.)
  /// back untouched instead of losing them by rebuilding a bare
  /// `{item_code, qty}` row, which would silently break the source
  /// document's own billing-status tracking. Null for a line the rep
  /// added by hand — that one just becomes a plain new row.
  Map<String, dynamic>? sourceRow;
}

/// Sales Invoice screen — one shared, fully editable form for every entry
/// point (issuing directly, billing an approved order, or crediting a
/// return), plus a "كل الفواتير" tab. Explicit design choice per direct
/// feedback: a rep must always see and be able to change every field
/// (items/qty/warehouse/dates/terms) regardless of how the invoice
/// started, GPS is always required, and a return must never be forced to
/// link back to an original invoice — linking one in is always optional.
///
/// `تحويل من طلبية`: `GET .../sales_order.make_sales_invoice` (confirmed,
/// `source_name` required) — the returned draft prefills this same form,
/// nothing more.
/// `مرتجع` (`_isReturn`): either prefilled from
/// `GET .../sales_invoice.make_sales_return` (confirmed, `source_name`
/// required) when the rep chooses to link one, or built from scratch —
/// quantities are shown positive in the UI either way and only negated at
/// submit time (`_isReturn` flips the sign), matching how ERPNext expects
/// a credit note's `items[].qty`.
class SalesInvoiceScreen extends StatefulWidget {
  const SalesInvoiceScreen({super.key, this.editDoc});

  /// When set, this screen edits an existing (still-Draft) Sales Invoice
  /// instead of creating a new one — same pattern as
  /// `SalesOrderScreen.editDoc`: the form is prefilled from it, "كل
  /// الفواتير" is hidden, and saving `PUT`s back to it.
  final Map<String, dynamic>? editDoc;

  @override
  State<SalesInvoiceScreen> createState() => _SalesInvoiceScreenState();
}

class _SalesInvoiceScreenState extends State<SalesInvoiceScreen>
    with SingleTickerProviderStateMixin {
  bool get _isEditing => widget.editDoc != null;

  late final TabController _tabController;

  PickedRecord? _customer;
  final List<_InvoiceLine> _lines = [];
  String? _priceList;
  num? _creditLimit;
  num? _currentOutstanding;
  bool _loadingPartyDetails = false;
  DateTime? _deliveryDate;
  PickedRecord? _paymentTerms;
  List<Map<String, dynamic>> _paymentScheduleTerms = [];
  bool _loadingPaymentSchedule = false;

  PickedRecord? _termsTemplate;
  bool _loadingTermsText = false;
  final _termsController = TextEditingController();

  /// رقم الفاتورة الورقية — لازم يتسجل مع كل فاتورة عشان تفضل قابلة
  /// للمطابقة مع الدفتر الورقي بتاع المندوب. مش `reqd` على مستوى السيرفر
  /// عمدًا (تجنبًا لكسر أي مسار إنشاء تاني للفاتورة، زي سكريبت تخطي
  /// الـWorkflow لغير المناديب) — الإلزام هنا في التطبيق نفسه بس.
  final _paperInvoiceNumberController = TextEditingController();

  /// Diagnostic reason strings — see SalesOrderScreen for the rationale.
  String? _creditLimitStatus;
  String? _priceListStatus;
  String? _paymentScheduleStatus;
  String? _outstandingStatus;
  String? _locationStatus;
  Future<void> Function()? _locationFix;

  /// Optional link only — set when this invoice is billing a source order
  /// or crediting against a source invoice. Never required for either
  /// path; clearing it just stops showing which document it came from,
  /// the already-populated form stays exactly as it is.
  PickedRecord? _sourceDoc;
  bool _loadingDraft = false;

  /// Return/credit-note mode — negates every line's quantity at submit
  /// and lets (never forces) linking [_sourceDoc] as `return_against`.
  bool _isReturn = false;

  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _isEditing ? 1 : 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) setState(() {});
      });

    final editDoc = widget.editDoc;
    if (editDoc != null) _prefillFromExistingDoc(editDoc);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _termsController.dispose();
    _paperInvoiceNumberController.dispose();
    super.dispose();
  }

  /// Loads an existing (still-Draft) Sales Invoice's fields into the form
  /// — same rationale as `SalesOrderScreen._prefillFromExistingDoc`.
  void _prefillFromExistingDoc(Map<String, dynamic> doc) {
    final customerName = doc['customer'] as String?;
    if (customerName != null) {
      unawaited(
        _loadCustomerDetails(
          PickedRecord(
            name: customerName,
            label: (doc['customer_name'] as String?) ?? customerName,
          ),
        ),
      );
    }
    _isReturn = doc['is_return'] == 1;
    _applyItemsDatesAndTerms(doc, negateQtyForDisplay: _isReturn);
  }

  /// Shared between [_prefillFromExistingDoc] and [_pickSourceDoc] — reads
  /// items/dates/payment-terms/terms-text out of any doc-shaped map
  /// (an existing invoice being edited, or a fresh `make_sales_invoice`/
  /// `make_sales_return` draft) into this form's state.
  void _applyItemsDatesAndTerms(
    Map<String, dynamic> doc, {
    required bool negateQtyForDisplay,
  }) {
    final items = doc['items'];
    if (items is List) {
      _lines.clear();
      for (final raw in items.whereType<Map>()) {
        final map = Map<String, dynamic>.from(raw);
        final itemCode = map['item_code']?.toString();
        if (itemCode == null) continue;
        final rawQty = (map['qty'] as num?)?.toDouble() ?? 1;
        final line =
            _InvoiceLine(
                itemCode: itemCode,
                itemName: (map['item_name'] as String?) ?? itemCode,
                sourceRow: map,
              )
              ..qty = negateQtyForDisplay ? rawQty.abs() : rawQty
              ..unitPrice = map['rate'] as num?
              ..warehouse = map['warehouse'] as String?;
        _lines.add(line);
      }
    }

    final deliveryDate = doc['delivery_date'] as String?;
    if (deliveryDate != null) _deliveryDate = DateTime.tryParse(deliveryDate);

    final paymentTermsTemplate = doc['payment_terms_template'] as String?;
    if (paymentTermsTemplate != null) {
      _paymentTerms = PickedRecord(
        name: paymentTermsTemplate,
        label: paymentTermsTemplate,
      );
    }

    final tcName = doc['tc_name'] as String?;
    if (tcName != null) {
      _termsTemplate = PickedRecord(name: tcName, label: tcName);
    }
    final terms = doc['terms'] as String?;
    if (terms != null) _termsController.text = stripHtml(terms);

    final paperInvoiceNumber = doc['custom_رقم_الفاتورة_الورقية'] as String?;
    if (paperInvoiceNumber != null) {
      _paperInvoiceNumberController.text = paperInvoiceNumber;
    }
  }

  /// Deliberately no client-side `account_manager` filter — see
  /// SalesOrderScreen._pickCustomer for why.
  Future<void> _pickCustomer() async {
    List<String> territories;
    try {
      territories = await ErpService.getExpandedUserTerritories();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر تحديد مناطقك — تحقق من الاتصال بالإنترنت'),
        ),
      );
      return;
    }
    if (!mounted) return;
    String? territoryFilter;

    final result = await showSearchPicker(
      context: context,
      title: 'اختر العميل',
      hintText: 'ابحث باسم العميل...',
      search: (query) async {
        final filters = <List<dynamic>>[
          if (query.isNotEmpty) ['customer_name', 'like', '%$query%'],
          if (territoryFilter != null)
            ['territory', '=', territoryFilter]
          else if (territories.length == 1)
            ['territory', '=', territories.first]
          else if (territories.isNotEmpty)
            ['territory', 'in', territories],
        ];

        final list = await ErpService.getList(
          'Customer',
          filters: filters.isEmpty ? null : filters,
          fields: const ['name', 'customer_name', 'territory'],
          limit: 20,
        );
        return list
            .map(
              (c) => PickedRecord(
                name: c['name'] as String,
                label: (c['customer_name'] as String?) ?? c['name'] as String,
                subtitle: c['territory'] as String?,
              ),
            )
            .toList();
      },
      actionsBuilder: territories.length <= 1
          ? null
          : (pickerContext, refresh) => [
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: territoryFilter == null
                    ? 'فلترة بخط السير'
                    : 'خط السير: $territoryFilter',
                onPressed: () async {
                  final picked = await showSearchPicker(
                    context: pickerContext,
                    title: 'اختر خط السير',
                    search: (q) async => territories
                        .where((t) => q.isEmpty || t.contains(q))
                        .map((t) => PickedRecord(name: t, label: t))
                        .toList(),
                  );
                  if (picked == null) return;
                  territoryFilter = picked.name;
                  refresh();
                },
              ),
            ],
    );
    if (result == null) return;
    await _loadCustomerDetails(result);
  }

  /// Shared between [_pickCustomer] and the edit-mode prefill.
  Future<void> _loadCustomerDetails(PickedRecord result) async {
    setState(() {
      _customer = result;
      _priceList = null;
      _creditLimit = null;
      _creditLimitStatus = null;
      _priceListStatus = null;
      _currentOutstanding = null;
      _outstandingStatus = null;
      _loadingPartyDetails = true;
    });

    // Best-effort only — every branch sets a specific status string
    // instead of a generic "unavailable" so the real cause is visible.
    try {
      final customerDoc = await ErpService.getDoc('Customer', result.name);
      if (customerDoc.isEmpty) {
        _creditLimitStatus = 'تعذر جلب بيانات العميل من السيرفر';
        _priceListStatus = _creditLimitStatus;
      } else {
        // Credit limit lives in the `credit_limits` child table (rows of
        // Customer Credit Limit: company + credit_limit), NOT a plain
        // `credit_limit` field on Customer.
        final creditLimitRows = customerDoc['credit_limits'];
        if (creditLimitRows is List && creditLimitRows.isNotEmpty) {
          final rows = creditLimitRows
              .whereType<Map>()
              .map((r) => Map<String, dynamic>.from(r))
              .toList();
          final company = await ErpService.resolveDefaultCompany();
          Map<String, dynamic>? matchedRow;
          if (company != null) {
            for (final row in rows) {
              if (row['company'] == company) {
                matchedRow = row;
                break;
              }
            }
          }
          matchedRow ??= rows.first;
          final limit = matchedRow['credit_limit'] as num?;
          if (limit == null || limit == 0) {
            _creditLimitStatus =
                'سقف الدين لهذا العميل مسجّل بقيمة صفر أو فارغة';
          } else {
            _creditLimit = limit;
          }
        } else if (creditLimitRows is List) {
          _creditLimitStatus =
              'لا يوجد سقف دين مسجّل لهذا العميل (جدول الحدود فارغ)';
        } else {
          _creditLimitStatus =
              'حقل حدود الائتمان غير ظاهر لحسابك (على الأغلب محمي بصلاحية على السيرفر)';
        }

        _priceList = customerDoc['default_price_list'] as String?;
        if (_priceList == null || _priceList!.isEmpty) {
          _priceList = await ErpService.getSellingSettingsPriceList();
        }
        if (_priceList == null) {
          _priceListStatus =
              'لا توجد قائمة أسعار افتراضية للعميل ولا في إعدادات البيع';
        }
      }
    } catch (e) {
      _creditLimitStatus = 'فشل الاتصال بالسيرفر أثناء جلب بيانات العميل: $e';
      _priceListStatus = _creditLimitStatus;
    }

    final outstanding = await _fetchCurrentOutstanding(result.name);
    if (outstanding == null) {
      _outstandingStatus = 'تعذر جلب المديونية الحالية لهذا العميل';
    } else {
      _currentOutstanding = outstanding;
    }

    if (mounted) setState(() => _loadingPartyDetails = false);
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

    final line = _InvoiceLine(itemCode: result.name, itemName: result.label);

    bool hasBatchNo = false;
    try {
      final itemRows = await ErpService.getList(
        'Item',
        filters: [
          ['name', '=', result.name],
        ],
        fields: const ['has_batch_no'],
        limit: 1,
      );
      hasBatchNo = itemRows.isNotEmpty && itemRows.first['has_batch_no'] == 1;
    } catch (_) {
      // فشل التحقق يترك الصنف عاديًا (بدون لوط) بدل ما يوقف الإضافة بالكامل.
    }

    if (hasBatchNo) {
      final picked = await _pickBatchForLine(line);
      if (!picked)
        return; // الصنف ده لازم لوط — من غير ما يختار واحد، مش بيتضاف خالص.
    }

    setState(() => _lines.add(line));
    await _fetchPriceForLine(line);
  }

  /// يجمع كل اللوطات المتاحة فعليًا (كمية > 0) لـ[line.itemCode] في كل
  /// مخازن المندوب نفسه (السيارة + الترانزيت — نفس المخازن اللي أمين
  /// المخزن بيحوّل عليها فعليًا)، ويجبره يختار واحد قبل ما الصنف يتضاف.
  /// بيرجع true لو المندوب اختار لوط فعلاً، false لو ألغى أو مفيش أي لوط
  /// متاح خالص (رسالة خطأ واضحة في الحالة التانية بدل صف صامت بلا لوط).
  Future<bool> _pickBatchForLine(_InvoiceLine line) async {
    final warehouses = await ErpService.getCurrentRepWarehouses();
    if (warehouses.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'هذا الصنف يتطلب رقم لوط، ولا يوجد مخزن مسجل على حسابك',
            ),
          ),
        );
      }
      return false;
    }

    final batches = <Map<String, dynamic>>[];
    for (final wh in warehouses) {
      try {
        final rows = await ErpService.getAvailableBatches(
          itemCode: line.itemCode,
          warehouse: wh,
        );
        batches.addAll(rows.where((r) => ((r['qty'] as num?) ?? 0) > 0));
      } catch (_) {
        // يتجاهل فشل مخزن واحد — يفضل يجرب الباقي.
      }
    }

    if (batches.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'لا يوجد رصيد من أي لوط لصنف "${line.itemName}" في مخزنك',
            ),
          ),
        );
      }
      return false;
    }

    if (!mounted) return false;
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'اختر رقم اللوط — ${line.itemName}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              ...batches.map((b) {
                final expiry = b['expiry_date'] as String?;
                return ListTile(
                  leading: const Icon(
                    Icons.inventory_2_outlined,
                    color: AppColors.accent,
                  ),
                  title: Text(b['batch_no'] as String? ?? '—'),
                  subtitle: Text(
                    'الكمية المتاحة: ${((b['qty'] as num?) ?? 0).toStringAsFixed(0)}'
                    '${expiry != null ? ' • صلاحية حتى $expiry' : ''}',
                  ),
                  onTap: () => Navigator.of(context).pop(b),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (selected == null) return false;

    line.batchNo = selected['batch_no'] as String?;
    line.warehouse = selected['warehouse'] as String?;
    line.batchAvailableQty = (selected['qty'] as num?)?.toDouble();
    line.batchExpiryDate = selected['expiry_date'] as String?;
    // Cap rather than reset — a line converted from a source order/return
    // already carries a real quantity that must survive this step; a
    // freshly hand-added line is always 1 already at this point.
    if (line.batchAvailableQty != null && line.qty > line.batchAvailableQty!) {
      line.qty = line.batchAvailableQty!;
    }
    return true;
  }

  /// Runs [_pickBatchForLine] for every current line whose item needs a
  /// batch and doesn't already have one — used after converting a source
  /// order/return into an invoice draft, since that draft's rows never
  /// went through [_addItem]'s own check. A line the rep declines to
  /// assign a batch to is dropped rather than left silently invalid.
  Future<void> _ensureBatchesForLines() async {
    if (_lines.isEmpty) return;
    final itemCodes = _lines.map((l) => l.itemCode).toSet().toList();
    Set<String> batchTrackedCodes = {};
    try {
      final rows = await ErpService.getList(
        'Item',
        filters: [
          ['name', 'in', itemCodes],
          ['has_batch_no', '=', 1],
        ],
        fields: const ['name'],
        limit: itemCodes.length,
      );
      batchTrackedCodes = rows.map((r) => r['name'] as String).toSet();
    } catch (_) {
      return; // Best-effort — see class doc comments elsewhere in this file.
    }
    if (batchTrackedCodes.isEmpty) return;

    final toRemove = <_InvoiceLine>[];
    for (final line in List<_InvoiceLine>.from(_lines)) {
      if (!batchTrackedCodes.contains(line.itemCode) || line.batchNo != null) {
        continue;
      }
      final picked = await _pickBatchForLine(line);
      if (!picked) toRemove.add(line);
    }
    if (toRemove.isEmpty) return;
    setState(() => _lines.removeWhere(toRemove.contains));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${toRemove.length} صنف يتطلب رقم لوط اتشال من الفاتورة لعدم اختيار لوط له',
          ),
        ),
      );
    }
  }

  Future<void> _fetchPriceForLine(_InvoiceLine line) async {
    final priceList = _priceList;
    if (priceList == null) {
      setState(
        () =>
            line.priceStatus = _priceListStatus ?? 'لا توجد قائمة أسعار محددة',
      );
      return;
    }
    try {
      final prices = await ErpService.getList(
        'Item Price',
        filters: [
          ['item_code', '=', line.itemCode],
          ['price_list', '=', priceList],
        ],
        fields: const ['price_list_rate'],
        limit: 1,
      );
      if (!mounted) return;
      if (prices.isEmpty) {
        setState(
          () => line.priceStatus =
              'لا يوجد سعر مسجل لهذا الصنف في القائمة "$priceList"',
        );
        return;
      }
      final rate = prices.first['price_list_rate'] as num?;
      if (rate == null) {
        setState(
          () => line.priceStatus = 'سعر مسجل لهذا الصنف لكن قيمته فارغة',
        );
      } else {
        setState(() {
          line.unitPrice = rate;
          line.priceStatus = null;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() => line.priceStatus = 'فشل الاتصال أثناء جلب السعر: $e');
    }
  }

  Future<void> _pickWarehouseForLine(_InvoiceLine line) async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر المخزن',
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
    setState(() => line.warehouse = result.name);
  }

  Future<void> _pickPriceList() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر قائمة أسعار',
      hintText: 'ابحث باسم القائمة...',
      search: (query) async {
        final list = await ErpService.getList(
          'Price List',
          filters: [
            ['selling', '=', 1],
            if (query.isNotEmpty) ['name', 'like', '%$query%'],
          ],
          fields: const ['name'],
          limit: 20,
        );
        return list
            .map(
              (p) => PickedRecord(
                name: p['name'] as String,
                label: p['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result == null) return;

    setState(() {
      _priceList = result.name;
      _priceListStatus = null;
    });

    for (final line in _lines) {
      await _fetchPriceForLine(line);
    }
  }

  Future<void> _pickDeliveryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deliveryDate ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _deliveryDate = picked);
  }

  Future<void> _pickPaymentTerms() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر شروط الدفع',
      hintText: 'ابحث باسم القالب...',
      search: (query) async {
        final list = await ErpService.getList(
          'Payment Terms Template',
          filters: query.isEmpty
              ? null
              : [
                  ['template_name', 'like', '%$query%'],
                ],
          fields: const ['name', 'template_name'],
          limit: 20,
        );
        return list
            .map(
              (t) => PickedRecord(
                name: t['name'] as String,
                label: (t['template_name'] as String?) ?? t['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result == null) return;
    setState(() {
      _paymentTerms = result;
      _paymentScheduleTerms = [];
      _paymentScheduleStatus = null;
      _loadingPaymentSchedule = true;
    });

    try {
      final template = await ErpService.getDoc(
        'Payment Terms Template',
        result.name,
      );
      if (template.isEmpty) {
        _paymentScheduleStatus = 'تعذر جلب تفاصيل القالب من السيرفر';
      } else if (!template.containsKey('terms')) {
        _paymentScheduleStatus =
            'حقل تفاصيل الدفعات غير ظاهر لحسابك (على الأغلب محمي بصلاحية على السيرفر)';
      } else {
        final terms = template['terms'];
        if (terms is List && terms.isNotEmpty) {
          _paymentScheduleTerms = terms
              .whereType<Map>()
              .map((t) => Map<String, dynamic>.from(t))
              .toList();
        } else {
          _paymentScheduleStatus =
              'لا توجد صفوف دفعات مُهيكَلة مسجّلة في هذا القالب';
        }
      }
    } catch (e) {
      _paymentScheduleStatus = 'فشل الاتصال أثناء جلب تفاصيل القالب: $e';
    }
    if (mounted) setState(() => _loadingPaymentSchedule = false);
  }

  /// `tc_name`/`terms` — same pattern as `SalesOrderScreen._pickTermsTemplate`:
  /// pick a `Terms and Conditions` template (optional) → its text seeds the
  /// free-editable [_termsController], which the rep can still type into or
  /// override by hand either way.
  Future<void> _pickTermsTemplate() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر الشروط والأحكام',
      hintText: 'ابحث باسم القالب...',
      search: (query) async {
        final list = await ErpService.getList(
          'Terms and Conditions',
          filters: [
            ['selling', '=', 1],
            if (query.isNotEmpty) ['title', 'like', '%$query%'],
          ],
          fields: const ['name', 'title'],
          limit: 20,
        );
        return list
            .map(
              (t) => PickedRecord(
                name: t['name'] as String,
                label: (t['title'] as String?) ?? t['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result == null) return;
    setState(() {
      _termsTemplate = result;
      _loadingTermsText = true;
    });
    try {
      final template = await ErpService.getDoc(
        'Terms and Conditions',
        result.name,
      );
      final terms = template['terms'] as String?;
      if (terms != null) _termsController.text = stripHtml(terms);
    } catch (_) {
      // Ignored — picking a template is never required to already have
      // working terms text.
    }
    if (mounted) setState(() => _loadingTermsText = false);
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  DateTime _dueDateForTerm(Map<String, dynamic> term, DateTime base) {
    final creditMonths = (term['credit_months'] as num?)?.toInt() ?? 0;
    if (creditMonths > 0) {
      return DateTime(base.year, base.month + creditMonths, base.day);
    }
    final creditDays = (term['credit_days'] as num?)?.toInt() ?? 0;
    final basedOn = term['due_date_based_on'] as String?;
    if (basedOn == 'Day(s) after the end of the invoice month') {
      final endOfMonth = DateTime(base.year, base.month + 1, 0);
      return endOfMonth.add(Duration(days: creditDays));
    }
    return base.add(Duration(days: creditDays));
  }

  num? get _grandTotal {
    if (_lines.isEmpty) return null;
    num total = 0;
    for (final line in _lines) {
      final price = line.unitPrice;
      if (price == null) return null;
      total += price * line.qty;
    }
    return total;
  }

  Future<num?> _fetchCurrentOutstanding(String customerName) async {
    try {
      final invoices = await ErpService.getList(
        'Sales Invoice',
        filters: [
          ['customer', '=', customerName],
          ['docstatus', '=', 1],
          ['outstanding_amount', '>', 0],
        ],
        fields: const ['outstanding_amount'],
        limit: 200,
      );
      num total = 0;
      for (final invoice in invoices) {
        final amount = invoice['outstanding_amount'];
        if (amount is num) total += amount;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// Blocks the send if this invoice would push the customer's total debt
  /// past their credit limit — never checked for a return (it reduces
  /// debt, not increases it). Per explicit instruction: exceeding the
  /// limit must always block with an alert, no exceptions, for every
  /// other case.
  Future<bool> _checkCreditLimit() async {
    if (_isReturn) return true;
    final creditLimit = _creditLimit;
    final customer = _customer;
    final grandTotal = _grandTotal;
    if (creditLimit == null || customer == null || grandTotal == null)
      return true;

    final currentOutstanding = await _fetchCurrentOutstanding(customer.name);
    if (currentOutstanding == null) return true;

    try {
      final projected = currentOutstanding + grandTotal;
      if (projected <= creditLimit) return true;

      if (!mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          title: const Text('تخطي سقف الدين'),
          content: Text(
            'سقف الدين المسموح: ${creditLimit.toStringAsFixed(0)} ج.م\n'
            'مديونية العميل الحالية: ${currentOutstanding.toStringAsFixed(0)} ج.م\n'
            'إجمالي هذه الفاتورة: ${grandTotal.toStringAsFixed(2)} ج.م\n'
            'الإجمالي بعد الفاتورة: ${projected.toStringAsFixed(2)} ج.م\n\n'
            'لا يمكن إصدار الفاتورة لأنها ستتجاوز سقف الدين المسموح لهذا العميل.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      );
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Device location — see SalesOrderScreen for the full rationale. Always
  /// required at submit now, regardless of which entry point built this
  /// invoice.
  Future<String?> _captureLocationUrl() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _locationStatus = 'خدمة الموقع (GPS) مقفولة على الجهاز';
        _locationFix = Geolocator.openLocationSettings;
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _locationStatus = 'تم رفض صلاحية الموقع';
        _locationFix = null;
        return null;
      }
      if (permission == LocationPermission.deniedForever) {
        _locationStatus =
            'صلاحية الموقع مرفوضة نهائيًا — فعّلها من إعدادات التطبيق بالجهاز';
        _locationFix = Geolocator.openAppSettings;
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );

      _locationStatus =
          'تم تحديد الموقع (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
      _locationFix = null;
      return 'https://www.google.com/maps?q=${position.latitude},${position.longitude}';
    } catch (e) {
      _locationStatus = 'خطأ أثناء تحديد الموقع: $e';
      _locationFix = null;
      return null;
    }
  }

  /// No confirmation dialog — GPS is mandatory, per explicit instruction,
  /// so the app just takes the rep straight to the fix (opens the actual
  /// system location/app-settings screen itself) instead of asking
  /// permission to ask permission first. A lightweight SnackBar (not a
  /// blocking modal) explains what's happening and offers a retry action
  /// for once they've actually made the change and come back.
  Future<String?> _ensureLocationCaptured() async {
    while (true) {
      final url = await _captureLocationUrl();
      if (url != null) return url;
      if (!mounted) return null;

      final fix = _locationFix;
      if (fix != null) await fix();
      if (!mounted) return null;

      final retry = Completer<void>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locationStatus ?? 'لازم تفعيل الموقع (GPS) عشان ترسل'),
          duration: const Duration(seconds: 12),
          action: SnackBarAction(
            label: 'أعد المحاولة',
            onPressed: () {
              if (!retry.isCompleted) retry.complete();
            },
          ),
        ),
      );
      await retry.future;
      if (!mounted) return null;
    }
  }

  /// Optionally prefills the whole form from a source Sales Order (billing
  /// it) or Sales Invoice (crediting a return against it) — never
  /// required, just a shortcut. [isOrder] picks which doctype/RPC.
  Future<void> _pickSourceDoc({required bool isOrder}) async {
    final result = await showSearchPicker(
      context: context,
      title: isOrder ? 'اختر طلبية' : 'اختر فاتورة أصلية',
      hintText: 'ابحث بالرقم أو اسم العميل...',
      search: (query) async {
        final doctype = isOrder ? 'Sales Order' : 'Sales Invoice';
        // Orders: only approved ones that still have something left to
        // invoice. Invoices (for a linked return): only submitted ones —
        // can't return a Draft that was never actually issued.
        final filters = <List<dynamic>>[
          ['docstatus', '=', 1],
          if (isOrder) ['billing_status', '!=', 'Fully Billed'],
          if (query.isNotEmpty) ['customer_name', 'like', '%$query%'],
        ];
        final list = await ErpService.getList(
          doctype,
          filters: filters,
          fields: [
            'name',
            'customer',
            'customer_name',
            'grand_total',
            if (isOrder) 'per_billed',
          ],
          limit: 20,
        );
        return list.map((d) {
          final grandTotal = d['grand_total'] as num?;
          // For an order, what's actually useful to see here isn't its
          // full total — it's how much of that is STILL unbilled
          // (`per_billed`, standard field), since that's what this
          // pick is actually going to invoice.
          final perBilled = (d['per_billed'] as num?) ?? 0;
          final remaining = isOrder && grandTotal != null
              ? grandTotal * (100 - perBilled) / 100
              : grandTotal;
          return PickedRecord(
            name: d['name'] as String,
            label:
                '${d['name']} — ${(d['customer_name'] as String?) ?? (d['customer'] as String?) ?? ''}',
            subtitle: remaining != null
                ? (isOrder
                      ? 'المتبقي للفوترة: ${remaining.toStringAsFixed(2)}'
                      : 'الإجمالي: $remaining')
                : null,
          );
        }).toList();
      },
    );
    if (result == null) return;

    setState(() {
      _sourceDoc = result;
      _loadingDraft = true;
      _error = null;
    });

    try {
      final draft = isOrder
          ? await ErpService.makeSalesInvoiceFromOrder(result.name)
          : await ErpService.makeSalesReturn(result.name);
      if (!mounted) return;
      setState(() {
        if (!isOrder) _isReturn = true;
        final customerName = draft['customer'] as String?;
        if (customerName != null) {
          _customer = PickedRecord(
            name: customerName,
            label: (draft['customer_name'] as String?) ?? customerName,
          );
        }
        _applyItemsDatesAndTerms(draft, negateQtyForDisplay: !isOrder);
      });
      // A line converted from an order/return draft never went through
      // `_addItem`'s batch check — the order itself never asks for a batch
      // (by design, only the invoice does). Close that gap here so a
      // batch-tracked item can't slip onto an invoice without one just
      // because it arrived via conversion instead of manual entry.
      await _ensureBatchesForLines();
      // Best-effort — credit limit/price-list/outstanding info for the
      // customer the draft came with.
      final customerName = draft['customer'] as String?;
      if (customerName != null) {
        unawaited(
          _loadCustomerDetails(
            PickedRecord(
              name: customerName,
              label: (draft['customer_name'] as String?) ?? customerName,
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  /// `false` هنا معناها فشل حقيقي أو إلغاء — [SwipeToConfirmButton] بيعكسها
  /// كحالة حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submit() async {
    final withinCreditLimit = await _checkCreditLimit();
    if (!withinCreditLimit) return false;

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    // Declared outside the `try` (not `final` inside it) so the `catch`
    // block below can still reach it to enqueue an offline job.
    Map<String, dynamic>? fields;
    try {
      final locationUrl = await _ensureLocationCaptured();
      if (locationUrl == null) {
        if (mounted) setState(() => _submitting = false);
        return false;
      }
      if (mounted && _locationStatus != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('الموقع: $_locationStatus'),
            duration: const Duration(seconds: 3),
          ),
        );
      }

      final items = _lines.map((line) {
        final signedQty = _isReturn ? -line.qty : line.qty;
        final source = line.sourceRow;
        if (source != null) {
          final row = Map<String, dynamic>.from(source);
          row['qty'] = signedQty;
          if (line.warehouse != null) row['warehouse'] = line.warehouse;
          if (line.batchNo != null) row['batch_no'] = line.batchNo;
          // Strip the draft's own row id — this is a fresh create, not an
          // update to an existing child row. Also strip `cost_center`: a
          // source order created before its own cost center was fixed on
          // the server carries the OLD (broken, group) one forward
          // otherwise — confirmed live on a real pre-existing order.
          // Omitting it lets the server resolve a fresh one from today's
          // actual Company/Item defaults instead of blindly trusting
          // whatever the source document happened to have cached.
          row
            ..remove('name')
            ..remove('cost_center');
          return row;
        }
        return {
          'item_code': line.itemCode,
          'qty': signedQty,
          if (line.warehouse != null) 'warehouse': line.warehouse,
          if (line.batchNo != null) 'batch_no': line.batchNo,
        };
      }).toList();

      fields = <String, dynamic>{
        'customer': _customer!.name,
        'items': items,
        if (_deliveryDate != null)
          'delivery_date': _deliveryDate!.toIso8601String().split('T').first,
        if (_paymentTerms != null)
          'payment_terms_template': _paymentTerms!.name,
        if (_termsTemplate != null) 'tc_name': _termsTemplate!.name,
        if (_termsController.text.trim().isNotEmpty)
          'terms': _termsController.text.trim(),
        'custom_رقم_الفاتورة_الورقية': _paperInvoiceNumberController.text.trim(),
        'custom_location_url': locationUrl,
        // This business hands goods over on the spot — the invoice itself
        // deducts (or, for a return, credits back) stock directly, no
        // separate Delivery Note step.
        'update_stock': 1,
        if (_isReturn) 'is_return': 1,
        if (_isReturn && _sourceDoc != null) 'return_against': _sourceDoc!.name,
      };

      final editDoc = widget.editDoc;
      if (editDoc != null) {
        final editName = editDoc['name'] as String;
        if (!SyncStatusService().isOnline) {
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Sales Invoice',
              'name': editName,
              'data': fields,
            },
          );
          _lastSubmitWasQueued = true;
          if (!mounted) return true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('لا يوجد اتصال — سيُحفظ التعديل تلقائيًا'),
            ),
          );
          Navigator.of(context).pop();
          return true;
        }
        await ErpService.updateDoc('Sales Invoice', editName, fields);
        if (!mounted) return true;
        Navigator.of(context).pop();
        return true;
      }

      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.salesInvoiceCreate,
          payload: fields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(_resetInvoiceForm);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم الحفظ وستُرسل الفاتورة تلقائيًا'),
          ),
        );
        return true;
      }

      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson != null) {
        fields['sales_team'] = [
          {'sales_person': salesPerson, 'allocated_percentage': 100},
        ];
      }

      final created = await ErpService.createDoc('Sales Invoice', fields);
      final submittedCustomer = _customer;

      if (!mounted) return true;
      setState(_resetInvoiceForm);

      final createdName = created['name'] as String?;
      if (createdName != null) {
        if (submittedCustomer != null) {
          await promptLogVisit(
            context,
            customer: submittedCustomer.name,
            territory: submittedCustomer.subtitle,
            referenceDoctype: 'Sales Invoice',
            referenceName: createdName,
          );
        }
        if (!mounted) return true;
        context.push(documentDetailRoute('Sales Invoice', createdName));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حفظ الفاتورة بنجاح')));
      }
      return true;
    } catch (e) {
      final editDoc = widget.editDoc;
      final capturedFields = fields;
      if (e is ErpException && e.isConnectivityFailure && capturedFields != null) {
        if (editDoc != null) {
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Sales Invoice',
              'name': editDoc['name'] as String,
              'data': capturedFields,
            },
          );
          _lastSubmitWasQueued = true;
          if (!mounted) return true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('تعذر الاتصال — سيُحفظ التعديل تلقائيًا'),
            ),
          );
          Navigator.of(context).pop();
          return true;
        }
        await SyncEngine().enqueue(
          type: SyncJobType.salesInvoiceCreate,
          payload: capturedFields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(_resetInvoiceForm);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم الحفظ وستُرسل الفاتورة تلقائيًا'),
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

  /// Extracted so both the live-success path and the offline-queued path
  /// reset the form identically.
  void _resetInvoiceForm() {
    _customer = null;
    _lines.clear();
    _priceList = null;
    _creditLimit = null;
    _creditLimitStatus = null;
    _priceListStatus = null;
    _deliveryDate = null;
    _paymentTerms = null;
    _termsTemplate = null;
    _termsController.clear();
    _paymentScheduleTerms = [];
    _paymentScheduleStatus = null;
    _locationStatus = null;
    _sourceDoc = null;
    _isReturn = false;
  }

  bool get _onAllInvoicesTab => !_isEditing && _tabController.index == 1;

  bool get _canSubmit =>
      !_submitting &&
      !_onAllInvoicesTab &&
      _customer != null &&
      _lines.isNotEmpty &&
      _paperInvoiceNumberController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Text(_isEditing ? 'تعديل الفاتورة' : 'فاتورة مبيعات'),
        bottom: _isEditing
            ? null
            : TabBar(
                controller: _tabController,
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.midGray,
                indicatorColor: AppColors.accent,
                tabs: const [
                  Tab(text: 'إصدار فاتورة'),
                  Tab(text: 'كل الفواتير'),
                ],
              ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildFormTab(),
                  if (!_isEditing) const AllSalesInvoicesScreen(),
                ],
              ),
            ),
            if (!_onAllInvoicesTab)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Opacity(
                  opacity: _canSubmit ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !_canSubmit,
                    child: SwipeToConfirmButton(
                      label: _isReturn
                          ? 'اسحب لحفظ المرتجع'
                          : 'اسحب لحفظ الفاتورة',
                      confirmedLabel: 'تم الحفظ',
                      onConfirmed: _submit,
                      wasQueued: () => _lastSubmitWasQueued,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormTab() {
    final grandTotal = _grandTotal;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Optional shortcuts — never required, just prefill the form below.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _pickSourceDoc(isOrder: true),
              icon: const Icon(Icons.receipt_long_rounded, size: 16),
              label: const Text('تحويل من طلبية'),
            ),
            FilterChip(
              label: const Text('فاتورة مرتجع'),
              selected: _isReturn,
              onSelected: (v) => setState(() => _isReturn = v),
              selectedColor: AppColors.accent.withValues(alpha: 0.15),
              checkmarkColor: AppColors.accent,
              labelStyle: TextStyle(
                color: _isReturn ? AppColors.accent : AppColors.black,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_isReturn)
              OutlinedButton.icon(
                onPressed: () => _pickSourceDoc(isOrder: false),
                icon: const Icon(Icons.link_rounded, size: 16),
                label: const Text('ربط بفاتورة أصلية '),
              ),
          ],
        ),
        if (_sourceDoc != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _isReturn
                    ? Icons.assignment_return_rounded
                    : Icons.link_rounded,
                size: 14,
                color: AppColors.midGray,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'مبني على: ${_sourceDoc!.name}',
                  style: const TextStyle(
                    color: AppColors.midGray,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_loadingDraft)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: () => setState(() => _sourceDoc = null),
                  child: const Text(
                    'إلغاء الربط',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
        if (_isReturn) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: const Text(
              'وضع المرتجع مفعّل — الكميات هتترد فعليًا للمخزن، والفاتورة هتتسجل كإشعار دائن.',
              style: TextStyle(color: AppColors.accent, fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _pickerCard(
          label: _customer?.label ?? 'اختر العميل',
          icon: Icons.storefront_rounded,
          onTap: _pickCustomer,
          trailing: _loadingPartyDetails
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (_customer != null && !_loadingPartyDetails) ...[
          if (_customer!.subtitle != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'المنطقة: ${_customer!.subtitle}',
                style: const TextStyle(color: AppColors.midGray, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _creditLimit != null
                  ? 'سقف الدين: ${_creditLimit!.toStringAsFixed(0)} ج.م'
                  : (_creditLimitStatus ?? 'سقف الدين غير متاح'),
              style: const TextStyle(color: AppColors.midGray, fontSize: 12),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _currentOutstanding != null
                  ? 'المديونية الحالية: ${_currentOutstanding!.toStringAsFixed(0)} ج.م'
                  : (_outstandingStatus ?? 'المديونية الحالية غير متاحة'),
              style: const TextStyle(color: AppColors.midGray, fontSize: 12),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _priceList != null
                ? Text(
                    'قائمة الأسعار: $_priceList',
                    style: const TextStyle(
                      color: AppColors.midGray,
                      fontSize: 12,
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Text(
                          _priceListStatus ?? 'قائمة الأسعار غير متاحة',
                          style: const TextStyle(
                            color: AppColors.midGray,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _pickPriceList,
                        child: const Text(
                          'اختيار يدوي',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'رقم الفاتورة الورقية *',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _paperInvoiceNumberController,
          decoration: const InputDecoration(hintText: 'رقم الفاتورة في الدفتر الورقي'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'الأصناف',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            TextButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('إضافة صنف'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_lines.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: const Center(
              child: Text(
                'لم تُضف أي أصناف بعد',
                style: TextStyle(color: AppColors.midGray),
              ),
            ),
          )
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          line.itemName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 20,
                            ),
                            color: AppColors.accent,
                            visualDensity: VisualDensity.compact,
                            onPressed: line.qty > 1
                                ? () => setState(() => line.qty -= 1)
                                : null,
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              line.qty.toStringAsFixed(0),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.add_circle_outline_rounded,
                              size: 20,
                            ),
                            color: AppColors.accent,
                            visualDensity: VisualDensity.compact,
                            onPressed:
                                line.batchAvailableQty == null ||
                                    line.qty < line.batchAvailableQty!
                                ? () => setState(() => line.qty += 1)
                                : null,
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.midGray,
                        ),
                        onPressed: () => setState(() => _lines.removeAt(index)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    line.unitPrice != null
                        ? 'السعر: ${line.unitPrice} × ${line.qty.toStringAsFixed(0)} = ${(line.unitPrice! * line.qty).toStringAsFixed(2)} ج.م'
                        : (line.priceStatus ?? 'السعر غير متاح'),
                    style: const TextStyle(
                      color: AppColors.midGray,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () async {
                      if (line.batchNo != null) {
                        final picked = await _pickBatchForLine(line);
                        if (picked) setState(() {});
                      } else {
                        _pickWarehouseForLine(line);
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warehouse_rounded,
                          size: 13,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          line.warehouse ?? 'المخزن: افتراضي (تلقائي)',
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (line.batchNo != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          size: 13,
                          color: AppColors.midGray,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'لوط: ${line.batchNo}'
                          '${line.batchExpiryDate != null ? ' • صلاحية حتى ${line.batchExpiryDate}' : ''}',
                          style: const TextStyle(
                            color: AppColors.midGray,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          }),
        if (_lines.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              grandTotal != null
                  ? '${_isReturn ? 'إجمالي المرتجع التقديري' : 'الإجمالي التقديري'}: ${grandTotal.toStringAsFixed(2)} ج.م'
                  : 'الإجمالي غير مكتمل (أسعار ناقصة)',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 24),
        const Text(
          'تاريخ التسليم',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _pickerCard(
          label: _deliveryDate != null
              ? _formatDate(_deliveryDate!)
              : 'اختر تاريخ التسليم',
          icon: Icons.event_rounded,
          onTap: _pickDeliveryDate,
        ),
        const SizedBox(height: 24),
        const Text(
          'شروط الدفع',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _pickerCard(
          label: _paymentTerms?.label ?? 'اختر شروط الدفع ',
          icon: Icons.receipt_long_rounded,
          onTap: _pickPaymentTerms,
          trailing: _loadingPaymentSchedule
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (_paymentScheduleTerms.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'معاينة الدفعات (تقديرية)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
                const SizedBox(height: 8),
                ..._paymentScheduleTerms.map((t) {
                  final portion = t['invoice_portion'] as num?;
                  final description = t['description'] as String?;
                  final baseDate = _deliveryDate ?? DateTime.now();
                  final dueDate = _dueDateForTerm(t, baseDate);
                  final amount = (portion != null && grandTotal != null)
                      ? grandTotal * portion / 100
                      : null;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            'استحقاق ${_formatDate(dueDate)} — ${portion ?? '—'}%'
                            '${description != null && description.isNotEmpty ? ' — $description' : ''}',
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (amount != null)
                          Text(
                            '${amount.toStringAsFixed(2)} ج.م',
                            style: const TextStyle(
                              color: AppColors.black,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ] else if (_paymentScheduleStatus != null &&
            !_loadingPaymentSchedule) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _paymentScheduleStatus!,
              style: const TextStyle(color: AppColors.midGray, fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 24),
        const Text(
          'الشروط والأحكام / ملاحظات',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        _pickerCard(
          label: _termsTemplate?.label ?? 'اختر قالبًا ',
          icon: Icons.description_rounded,
          onTap: _pickTermsTemplate,
          trailing: _loadingTermsText
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _termsController,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'اكتب ملاحظاتك هنا يدويًا، أو عدّل النص بعد اختيار قالب',
          ),
        ),
        if (_error != null) _errorRow(),
      ],
    );
  }

  Widget _errorRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.accent,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickerCard({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (trailing != null) trailing,
              const Icon(Icons.chevron_left_rounded, color: AppColors.midGray),
            ],
          ),
        ),
      ),
    );
  }
}
