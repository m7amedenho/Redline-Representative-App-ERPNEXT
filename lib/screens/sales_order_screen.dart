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
import 'all_sales_orders_screen.dart';
import 'document_detail_screen.dart';

class _OrderLine {
  _OrderLine({required this.itemCode, required this.itemName});

  final String itemCode;
  final String itemName;
  double qty = 1;

  /// Best-effort — looked up from `Item Price` for the customer's price
  /// list. Null if no price list is known yet or no matching price was
  /// found; the line is still addable.
  num? unitPrice;

  /// Set whenever [unitPrice] stays null, explaining exactly why (no price
  /// list, no matching Item Price row, or a network/permission failure) —
  /// shown to the user instead of a generic "unavailable" so a real cause
  /// is visible instead of having to guess.
  String? priceStatus;

  /// Explicit override only — left null means "let the server decide"
  /// (confirmed live: the server already auto-defaults each item to the
  /// rep's own vehicle warehouse, e.g. "سيارة م. رشاد سعيد - ALEX", when no
  /// `warehouse` key is sent at all). Only set when the rep deliberately
  /// picks a different warehouse via [SearchPicker] on the `Warehouse`
  /// DocType.
  String? warehouse;
}

/// Creates a Sales Order — `POST /api/resource/Sales Order`. Field names
/// (`customer`, `items[].item_code`/`qty`, `delivery_date`,
/// `payment_terms_template`) are the standard ERPNext ones; they're NOT in
/// the OpenAPI specs (those only document `/api/method` endpoints), so
/// they're unverified against this specific site. See
/// docs/API_INTEGRATION_NOTES.md.
///
/// Pricing/credit-limit notes (see docs for the full writeup): unit prices
/// come from the `Item Price` DocType filtered by a price list resolved via
/// `ErpService.resolvePriceList`-equivalent logic — `Customer.default_price_list`
/// first, `Selling Settings.selling_price_list` as fallback (both standard
/// fields, not `get_party_details`, which needs a `company` this app
/// doesn't have and silently omits pricing without one); credit limit comes
/// straight from `Customer.credit_limit`. The totals shown here are an
/// informational estimate only — they don't apply Pricing Rules/taxes the
/// way the server's own save logic would.
class SalesOrderScreen extends StatefulWidget {
  const SalesOrderScreen({super.key, this.editDoc});

  /// When set, this screen edits an existing Sales Order (still in a state
  /// the current user is allowed to edit — see
  /// `DocumentDetailScreen._canEditCurrentState`) instead of creating a new
  /// one: the form is prefilled from it, "كل الطلبيات" is hidden (there's
  /// only one document to work on here), and saving `PUT`s back to it
  /// rather than `POST`ing a new order.
  final Map<String, dynamic>? editDoc;

  @override
  State<SalesOrderScreen> createState() => _SalesOrderScreenState();
}

class _SalesOrderScreenState extends State<SalesOrderScreen>
    with SingleTickerProviderStateMixin {
  bool get _isEditing => widget.editDoc != null;

  late final TabController _tabController = TabController(
    length: _isEditing ? 1 : 2,
    vsync: this,
  );

  PickedRecord? _customer;
  final List<_OrderLine> _lines = [];

  String? _priceList;
  num? _creditLimit;
  num? _currentOutstanding;
  DateTime? _deliveryDate;
  PickedRecord? _paymentTerms;
  PickedRecord? _termsTemplate;
  bool _loadingTermsText = false;

  /// Backs the free-text "terms" field — picking [_termsTemplate] fills
  /// this in from the template's own text as a starting point, but the rep
  /// can still freely type/edit it (per explicit request: "ممكن يختار وممكن
  /// يكتب يدوي" — selectable from a template AND manually editable), and an
  /// edited value is never overwritten automatically afterward.
  final _termsController = TextEditingController();
  List<Map<String, dynamic>> _paymentScheduleTerms = [];
  bool _loadingPaymentSchedule = false;

  /// Diagnostic reason strings — shown directly in the UI instead of a
  /// generic "unavailable" so a real cause (permission, no data, network
  /// failure) is visible rather than guessed at from outside the app.
  String? _creditLimitStatus;
  String? _priceListStatus;
  String? _paymentScheduleStatus;
  String? _outstandingStatus;
  String? _locationStatus;

  /// Set alongside [_locationStatus] whenever the failure is something the
  /// user can actually go fix from a system settings screen (service off,
  /// permission permanently denied) — null for transient failures (timeout,
  /// a generic exception) where retrying in-place is the only sensible
  /// option. Read by [_ensureLocationCaptured]'s blocking dialog.
  Future<void> Function()? _locationFix;

  bool _loadingPartyDetails = false;
  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Only used to re-run build() so the submit button (create-tab only)
    // shows/hides as the user switches tabs — same listener pattern as
    // SalesInvoiceScreen's own TabController.
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });

    final editDoc = widget.editDoc;
    if (editDoc != null) _prefillFromExistingDoc(editDoc);
  }

  /// Loads an existing Sales Order's fields into the (otherwise "create a
  /// new order") form — items' `rate` is used as the initial [_OrderLine
  /// .unitPrice] directly (no live re-fetch) so the total shown matches
  /// what's actually on the document until the rep touches a line.
  /// Best-effort throughout, same as [_pickCustomer] — a failure here just
  /// leaves that one field for the rep to (re)pick by hand.
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

    final items = doc['items'];
    if (items is List) {
      for (final raw in items.whereType<Map>()) {
        final itemCode = raw['item_code']?.toString();
        if (itemCode == null) continue;
        final line =
            _OrderLine(
                itemCode: itemCode,
                itemName: (raw['item_name'] as String?) ?? itemCode,
              )
              ..qty = (raw['qty'] as num?)?.toDouble() ?? 1
              ..unitPrice = raw['rate'] as num?
              ..warehouse = raw['warehouse'] as String?;
        _lines.add(line);
      }
    }

    final deliveryDate = doc['delivery_date'] as String?;
    if (deliveryDate != null) {
      _deliveryDate = DateTime.tryParse(deliveryDate);
    }

    final paymentTermsTemplate = doc['payment_terms_template'] as String?;
    if (paymentTermsTemplate != null) {
      _paymentTerms = PickedRecord(
        name: paymentTermsTemplate,
        label: paymentTermsTemplate,
      );
    }

    final termsTemplate = doc['tc_name'] as String?;
    if (termsTemplate != null) {
      _termsTemplate = PickedRecord(name: termsTemplate, label: termsTemplate);
    }
    final terms = doc['terms'] as String?;
    if (terms != null) _termsController.text = stripHtml(terms);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _termsController.dispose();
    super.dispose();
  }

  /// Deliberately no client-side `account_manager` filter here — the
  /// server's own Territory User Permission (or whatever else is
  /// configured) already scopes which customers each user can see, and a
  /// user with access to more than one territory (a region manager, say)
  /// needs to see all of them. Layering an extra `account_manager` filter
  /// on top double-restricted results down to nothing whenever a customer
  /// matched on territory but had no `account_manager` set — confirmed by
  /// a real test. Trust the server's permission engine, same as everywhere
  /// else in this app.
  Future<void> _pickCustomer() async {
    List<String> territories;
    try {
      territories = await ErpService.getExpandedUserTerritories();
    } catch (_) {
      // No cached territories yet AND no connection right now — must NOT
      // open the picker with an unscoped filter (would show every
      // customer, not just this rep's own territory).
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
        // Confirmed live (real rep credentials, not Administrator): Frappe
        // does NOT auto-restrict Customer by Territory User Permission on
        // this site. The server-level fix (`apply_strict_user_permissions`)
        // was reverted — it broke Warehouse visibility for every rep as a
        // side effect (confirmed live) and the conflicting User Permission
        // row can't currently be cleaned up (a real Frappe framework bug in
        // `delete_doc`'s activity-feed hook blocks the delete). So this
        // client-side filter is the actual, load-bearing mechanism — not a
        // redundant convenience layer. [territoryFilter] (the rep's own
        // explicit gear-icon pick) always takes priority when set.
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

  /// Credit limit / price list / current outstanding for [result] — shared
  /// between [_pickCustomer] (after the rep picks a customer) and
  /// [initState]'s edit-mode prefill (an existing order already has a
  /// customer, but not this derived data).
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
      _error = null;
    });

    // Best-effort only — a failure shouldn't block picking a customer.
    // Every branch sets a *specific* status string instead of a generic
    // "unavailable" so the real cause shows up in the UI.
    try {
      final customerDoc = await ErpService.getDoc('Customer', result.name);
      if (customerDoc.isEmpty) {
        _creditLimitStatus = 'تعذر جلب بيانات العميل من السيرفر';
        _priceListStatus = _creditLimitStatus;
      } else {
        // Credit limit lives in the `credit_limits` child table (rows of
        // Customer Credit Limit: company + credit_limit), NOT a plain
        // `credit_limit` field on Customer — confirmed from the site's own
        // schema. Pick the row matching the resolved company; fall back to
        // the first row if there's only one (single-company site).
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

    final line = _OrderLine(itemCode: result.name, itemName: result.label);
    setState(() => _lines.add(line));
    await _fetchPriceForLine(line);
  }

  /// Looks up `Item Price` for [line] against the currently resolved
  /// `_priceList` — extracted out of `_addItem` so the manual price-list
  /// picker ([_pickPriceList]) can re-run it for every existing line once
  /// the rep picks a list by hand.
  Future<void> _fetchPriceForLine(_OrderLine line) async {
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

  /// Manual fallback when no price list resolved automatically (customer
  /// has none, Selling Settings has none either) — lets the rep pick one
  /// from `Price List` directly instead of being stuck with no pricing at
  /// all. `selling: 1` is a standard field marking a list usable for sales.
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

  /// Explicit per-line override of the server's own auto-defaulted
  /// warehouse (see [_OrderLine.warehouse] doc comment). Same
  /// `Warehouse`-picker pattern as `material_request_screen.dart`'s
  /// `_pickWarehouse` (excludes group/disabled warehouses).
  Future<void> _pickWarehouseForLine(_OrderLine line) async {
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

    // Best-effort preview only — real due dates are computed server-side
    // from the document's actual posting date, see class doc comment.
    // Every branch sets a specific status string on failure/emptiness
    // instead of silently leaving the section blank.
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

  /// `tc_name` — standard ERPNext field (Link → `Terms and Conditions`,
  /// which autonames by its own `title`, so `name` and `title` are the same
  /// string); same status here as `payment_terms_template` elsewhere in
  /// this file — the field name itself is stable framework knowledge, not
  /// verified against this specific site's actual template records.
  /// Optional, same pattern as [_pickPaymentTerms].
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
    // Best-effort — the text field just stays whatever it was (empty, or
    // whatever the rep already typed) if this fetch fails; picking a
    // template is never required to already have working terms text.
    try {
      final template = await ErpService.getDoc(
        'Terms and Conditions',
        result.name,
      );
      final terms = template['terms'] as String?;
      // `terms` is a Text Editor field on the server (stores HTML) — shown
      // here as plain text since this is a simple, single-line-styled
      // mobile field, not a rich text editor.
      if (terms != null) _termsController.text = stripHtml(terms);
    } catch (_) {
      // Ignored — see above.
    }
    if (mounted) setState(() => _loadingTermsText = false);
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Estimated due date for one `Payment Terms Template Detail` row — real
  /// due dates are computed server-side from the document's actual posting
  /// date once it exists, so this is a client-side approximation off
  /// [_deliveryDate] (or today, if no delivery date is set yet) using the
  /// same two fields ERPNext itself bases due dates on: `credit_months`
  /// (whole months, takes priority when set) or `credit_days`, applied
  /// either directly or from the end of the base month depending on
  /// `due_date_based_on`.
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
      if (price == null) return null; // Incomplete — don't show a wrong total.
      total += price * line.qty;
    }
    return total;
  }

  /// Sum of `Sales Invoice.outstanding_amount` for this customer's
  /// submitted invoices (`docstatus=1`, `outstanding_amount>0`) — a plain,
  /// standard field, simpler and more direct than assembling it from
  /// `get_outstanding_reference_documents`. Used both for the informational
  /// line shown right after picking a customer, and — fetched fresh again —
  /// by [_checkCreditLimit] at the moment of actually sending, since that's
  /// a blocking financial check and shouldn't trust a value that might be
  /// stale by then. Returns null on any failure (permission, network) —
  /// callers show a diagnostic status instead of guessing.
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

  /// Blocks the send if this order would push the customer's total debt
  /// (existing outstanding invoices + this order) past their credit limit.
  /// Can only check when both the credit limit and this sum are actually
  /// available — on an account without permission to read either (see
  /// docs/API_INTEGRATION_NOTES.md), this silently skips the check rather
  /// than blocking on data it doesn't have.
  Future<bool> _checkCreditLimit() async {
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
            'إجمالي هذه الطلبية: ${grandTotal.toStringAsFixed(2)} ج.م\n'
            'الإجمالي بعد الطلبية: ${projected.toStringAsFixed(2)} ج.م\n\n'
            'لا يمكن إرسال الطلبية لأنها ستتجاوز سقف الدين المسموح لهذا العميل.',
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
      // Couldn't verify — don't block on data we don't actually have.
      return true;
    }
  }

  /// Device location, sent as a plain maps URL rather than a GeoJSON
  /// Geolocation value — per explicit instruction, a Client Script on the
  /// server reads `custom_location_url` and populates the real Geolocation
  /// field (`custom_location_map`) itself, so this app's job is just to
  /// produce a URL, not a GeoJSON shape. Mandatory as of this round — see
  /// [_ensureLocationCaptured], which blocks submission until this
  /// succeeds. Sets [_locationStatus] with the exact reason on every path,
  /// and [_locationFix] to whatever system-settings action (if any) would
  /// actually fix it.
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

  /// GPS is now mandatory: no Android API lets an app silently force
  /// location services on, so the closest achievable equivalent is to
  /// block submission entirely and keep sending the user to the relevant
  /// system settings screen until a real fix succeeds. Loops
  /// [_captureLocationUrl] behind a non-dismissible dialog; returns null
  /// only if the user explicitly cancels.
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

  /// Always just saves a plain Draft — this app never advances a document
  /// past Draft at creation time any more. Sending it into the workflow (or
  /// a plain submit when there's no workflow) is a separate, explicit swipe
  /// action on [DocumentDetailScreen] once the rep is ready.
  ///
  /// Extracted so both the live-success path and the offline-queued path
  /// reset the form identically.
  void _resetOrderForm() {
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
  }

  /// `false` هنا معناها فشل حقيقي أو إلغاء — [SwipeToConfirmButton] بيعكسها
  /// كحالة حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submit() async {
    if (_customer == null || _lines.isEmpty) return false;

    final withinCreditLimit = await _checkCreditLimit();
    if (!withinCreditLimit) return false;

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    // Declared outside the `try` (not `final` inside it) so the `catch`
    // block below can still reach it to enqueue an offline job — a `catch`
    // block can't see a variable scoped to its own `try` block.
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

      fields = <String, dynamic>{
        'customer': _customer!.name,
        'items': _lines
            .map(
              (l) => {
                'item_code': l.itemCode,
                'qty': l.qty,
                if (l.warehouse != null) 'warehouse': l.warehouse,
              },
            )
            .toList(),
        if (_deliveryDate != null)
          'delivery_date': _deliveryDate!.toIso8601String().split('T').first,
        if (_paymentTerms != null)
          'payment_terms_template': _paymentTerms!.name,
        if (_termsTemplate != null) 'tc_name': _termsTemplate!.name,
        if (_termsController.text.trim().isNotEmpty)
          'terms': _termsController.text.trim(),
        'custom_location_url': locationUrl,
      };

      final editDoc = widget.editDoc;
      if (editDoc != null) {
        // Editing an existing order — same fields, `PUT` in place. No
        // `sales_team` re-resolution (already set at creation) and no form
        // reset/navigation-away: pop back to the detail screen the rep
        // came from so they can then use its "resend" swipe.
        final editName = editDoc['name'] as String;
        if (!SyncStatusService().isOnline) {
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Sales Order',
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
        await ErpService.updateDoc('Sales Order', editName, fields);
        if (!mounted) return true;
        Navigator.of(context).pop();
        return true;
      }

      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.salesOrderCreate,
          payload: fields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(_resetOrderForm);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم الحفظ وستُرسل الطلبية تلقائيًا'),
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
      final created = await ErpService.createDoc('Sales Order', fields);
      final submittedCustomer = _customer;

      if (!mounted) return true;
      setState(_resetOrderForm);

      final createdName = created['name'] as String?;
      if (createdName != null) {
        if (submittedCustomer != null) {
          await promptLogVisit(
            context,
            customer: submittedCustomer.name,
            territory: submittedCustomer.subtitle,
            referenceDoctype: 'Sales Order',
            referenceName: createdName,
          );
        }
        if (!mounted) return true;
        context.push(documentDetailRoute('Sales Order', createdName));
      }
      return true;
    } catch (e) {
      final capturedFields = fields;
      if (e is ErpException && e.isConnectivityFailure && capturedFields != null) {
        final editDoc = widget.editDoc;
        if (editDoc != null) {
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Sales Order',
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
          type: SyncJobType.salesOrderCreate,
          payload: capturedFields,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(_resetOrderForm);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم الحفظ وستُرسل الطلبية تلقائيًا'),
          ),
        );
        return true;
      }
      if (!mounted) return false;
      final message = handleErpError(context, e);
      if (message == null) return false;
      setState(() => _error = message);
      return false;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _customer != null && _lines.isNotEmpty && !_submitting;
    final grandTotal = _grandTotal;
    final onCreateTab = _tabController.index == 0;

    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Text(_isEditing ? 'تعديل الطلبية' : 'طلبية جديدة'),
        bottom: _isEditing
            ? null
            : TabBar(
                controller: _tabController,
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.midGray,
                indicatorColor: AppColors.accent,
                tabs: const [
                  Tab(text: 'طلبية جديدة'),
                  Tab(text: 'كل الطلبيات'),
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
                  ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _sectionTitle('العميل'),
                      const SizedBox(height: 8),
                      _pickerCard(
                        label: _customer?.label ?? 'اختر العميل',
                        icon: Icons.storefront_rounded,
                        onTap: _pickCustomer,
                        trailing: _loadingPartyDetails
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                              style: const TextStyle(
                                color: AppColors.midGray,
                                fontSize: 12,
                              ),
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
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            _currentOutstanding != null
                                ? 'المديونية الحالية: ${_currentOutstanding!.toStringAsFixed(0)} ج.م'
                                : (_outstandingStatus ??
                                      'المديونية الحالية غير متاحة'),
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
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
                                        _priceListStatus ??
                                            'قائمة الأسعار غير متاحة',
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
                      const SizedBox(height: 24),
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
                              borderRadius: BorderRadius.circular(
                                AppRadius.card,
                              ),
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
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
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
                                              ? () => setState(
                                                  () => line.qty -= 1,
                                                )
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
                                          onPressed: () =>
                                              setState(() => line.qty += 1),
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: AppColors.midGray,
                                      ),
                                      onPressed: () => setState(
                                        () => _lines.removeAt(index),
                                      ),
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
                                  onTap: () => _pickWarehouseForLine(line),
                                  child: Text(
                                    'المخزن: ${line.warehouse ?? 'افتراضي (تلقائي)'}',
                                    style: const TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
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
                                ? 'الإجمالي التقديري: ${grandTotal.toStringAsFixed(2)} ج.م'
                                : 'الإجمالي غير مكتمل (أسعار ناقصة)',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      _sectionTitle('تاريخ التسليم'),
                      const SizedBox(height: 8),
                      _pickerCard(
                        label: _deliveryDate != null
                            ? _formatDate(_deliveryDate!)
                            : 'اختر تاريخ التسليم',
                        icon: Icons.event_rounded,
                        onTap: _pickDeliveryDate,
                      ),
                      const SizedBox(height: 24),
                      _sectionTitle('شروط الدفع'),
                      const SizedBox(height: 8),
                      _pickerCard(
                        label: _paymentTerms?.label ?? 'اختر شروط الدفع ',
                        icon: Icons.receipt_long_rounded,
                        onTap: _pickPaymentTerms,
                        trailing: _loadingPaymentSchedule
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ..._paymentScheduleTerms.map((t) {
                                final portion = t['invoice_portion'] as num?;
                                final description = t['description'] as String?;
                                final baseDate =
                                    _deliveryDate ?? DateTime.now();
                                final dueDate = _dueDateForTerm(t, baseDate);
                                final amount =
                                    (portion != null && grandTotal != null)
                                    ? grandTotal * portion / 100
                                    : null;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      _sectionTitle('الشروط والأحكام'),
                      const SizedBox(height: 8),
                      _pickerCard(
                        label: _termsTemplate?.label ?? 'اختر قالبًا ',
                        icon: Icons.description_rounded,
                        onTap: _pickTermsTemplate,
                        trailing: _loadingTermsText
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _termsController,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText:
                              'اكتب الشروط والأحكام يدويًا، أو عدّل النص بعد اختيار قالب',
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Row(
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
                                style: const TextStyle(
                                  color: AppColors.accent,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  if (!_isEditing) const AllSalesOrdersScreen(),
                ],
              ),
            ),
            if (onCreateTab) ...[
              if (!canSubmit && !_submitting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    _customer == null
                        ? 'اختر عميل أولاً'
                        : 'أضف صنف واحد على الأقل',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.midGray,
                      fontSize: 12,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Opacity(
                  opacity: canSubmit ? 1 : 0.4,
                  child: IgnorePointer(
                    ignoring: !canSubmit,
                    child: SwipeToConfirmButton(
                      label: 'اسحب لحفظ الطلبية',
                      confirmedLabel: 'تم الحفظ',
                      onConfirmed: _submit,
                      wasQueued: () => _lastSubmitWasQueued,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
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
