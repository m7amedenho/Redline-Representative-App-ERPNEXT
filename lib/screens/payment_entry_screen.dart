import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';
import 'document_detail_screen.dart';
import 'treasury_screen.dart';

class _OutstandingInvoice {
  _OutstandingInvoice({
    required this.voucherType,
    required this.voucherNo,
    required this.outstandingAmount,
    this.dueDate,
    this.paymentTerm,
  });

  final String voucherType;
  final String voucherNo;
  final num outstandingAmount;
  final String? dueDate;

  /// لو الفاتورة عليها جدول دفعات (Payment Schedule) بتخصيص حسب شرط الدفع،
  /// كل شرط بييجي كصف منفصل من `get_outstanding_reference_documents` — مش
  /// بنجمعهم في صف واحد زي الأول، لأن `Payment Entry` نفسه بيرفض يتسجل
  /// من غير `payment_term` محدد لكل صف مرجع لما يكون التخصيص مفعّل على
  /// الفاتورة (اتأكد حي: "لديه تخصيص بناءً على شرط الدفع ممكّن").
  final String? paymentTerm;

  /// مفتاح فريد حقيقي — `voucherNo` لوحده مش كفاية لما فاتورة واحدة ليها
  /// أكتر من شرط دفع.
  String get key => '$voucherNo|${paymentTerm ?? ''}';

  bool get isOverdue {
    final due = dueDate;
    if (due == null) return false;
    final parsed = DateTime.tryParse(due);
    if (parsed == null) return false;
    final today = DateTime.now();
    return parsed.isBefore(DateTime(today.year, today.month, today.day));
  }
}

/// Payment Entry screen — "تحصيل من عميل".
///
/// Flow: pick customer → `GET .../customer.make_payment_entry` (confirmed,
/// `source_name` required) for the draft's base fields (party/company/
/// accounts) → `GET .../payment_entry.get_outstanding_reference_documents`
/// (confirmed, `args` required) for the customer's outstanding invoices,
/// shown as a checklist → rep enters the total collected amount → picks
/// which invoices it pays off → the amount is allocated across the
/// selected invoices in the order the server returned them (oldest due
/// first, per ERPNext's own convention) → submit builds a real
/// `references` child table entry per selected invoice
/// (`reference_doctype`/`reference_name`/`allocated_amount`/
/// `outstanding_amount` — standard ERPNext Payment Entry fields, confirmed
/// from framework knowledge, not from the OpenAPI specs which don't cover
/// DocType field shapes) instead of just posting the untouched draft.
class PaymentEntryScreen extends StatefulWidget {
  const PaymentEntryScreen({super.key, this.presetCustomer});

  /// لو جايين من زرار "الذهاب للتحصيل" (شاشة تسجيل الزيارة، غرض "تحصيل")
  /// — يبدأ الشاشة على طول بالعميل ده محمّل بدل ما يدور عليه تاني.
  final PickedRecord? presetCustomer;

  @override
  State<PaymentEntryScreen> createState() => _PaymentEntryScreenState();
}

class _PaymentEntryScreenState extends State<PaymentEntryScreen> {
  PickedRecord? _customer;
  Map<String, dynamic>? _draftDoc;
  List<_OutstandingInvoice> _outstanding = [];
  final Set<String> _selectedKeys = {};
  final _amountController = TextEditingController();

  /// رقم الإيصال الورقي — إجباري في التطبيق (مش على مستوى السيرفر عمدًا،
  /// نفس منطق رقم الفاتورة الورقية) لضمان تطابق كل تحصيل رقمي مع إيصاله
  /// الورقي الحقيقي.
  final _receiptNumberController = TextEditingController();

  /// Which real, company-owned cash box/bank account/e-wallet this
  /// collection actually went into — optional (the server has its own
  /// default `mode_of_payment`/`paid_to` if the rep skips it), but when
  /// set it overrides both fields on submit so the money is attributed to
  /// the correct account instead of a generic default.
  TreasuryInfo? _treasury;

  bool _loadingDraft = false;
  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;
  String? _outstandingError;

  @override
  void initState() {
    super.initState();
    final preset = widget.presetCustomer;
    if (preset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectCustomer(preset);
      });
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _receiptNumberController.dispose();
    super.dispose();
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
        // See SalesOrderScreen._pickCustomer for why `territories` IS
        // auto-applied here as the load-bearing filter.
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
    await _selectCustomer(result);
  }

  /// يصحح `dueDate` لكل صف بمقارنته بجدول `payment_schedule` الحقيقي على
  /// الفاتورة نفسها — واحدة `getDoc` لكل فاتورة مختلفة ظاهرة في القائمة
  /// (مش لكل صف)، بأفضل مجهود (لو فشلت فاتورة معينة، صفوفها تفضل بتاريخها
  /// الأصلي بدل ما توقف القائمة كلها).
  Future<List<_OutstandingInvoice>> _correctDueDatesFromPaymentSchedule(
    List<_OutstandingInvoice> rows,
  ) async {
    final invoiceNames = rows
        .where((r) => r.voucherType == 'Sales Invoice')
        .map((r) => r.voucherNo)
        .toSet();
    if (invoiceNames.isEmpty) return rows;

    // voucherNo -> (paymentTerm -> dueDate)
    final schedules = <String, Map<String, String>>{};
    for (final name in invoiceNames) {
      try {
        final doc = await ErpService.getDoc('Sales Invoice', name);
        final schedule = doc['payment_schedule'];
        if (schedule is! List) continue;
        final byTerm = <String, String>{};
        for (final entry in schedule) {
          if (entry is! Map) continue;
          final term = entry['payment_term'] as String?;
          final due = entry['due_date'] as String?;
          if (term != null && due != null) byTerm[term] = due;
        }
        schedules[name] = byTerm;
      } catch (_) {
        // Best-effort — هذه الفاتورة تفضل بتاريخها القديم (الإجمالي) بدل
        // ما نمنع عرض بقية القائمة.
      }
    }

    return rows.map((r) {
      final term = r.paymentTerm;
      String? realDate;
      if (term != null) {
        final byTerm = schedules[r.voucherNo];
        if (byTerm != null) realDate = byTerm[term];
      }
      if (realDate == null || realDate == r.dueDate) return r;
      return _OutstandingInvoice(
        voucherType: r.voucherType,
        voucherNo: r.voucherNo,
        outstandingAmount: r.outstandingAmount,
        dueDate: realDate,
        paymentTerm: r.paymentTerm,
      );
    }).toList();
  }

  /// المنطق المشترك لما العميل يتحدد — سواء من البحث اليدوي فوق، أو من
  /// [PaymentEntryScreen.presetCustomer] لما نيجي من زرار "الذهاب للتحصيل"
  /// في شاشة تسجيل الزيارة.
  Future<void> _selectCustomer(PickedRecord result) async {
    setState(() {
      _customer = result;
      _draftDoc = null;
      _outstanding = [];
      _outstandingError = null;
      _selectedKeys.clear();
      _amountController.clear();
      _loadingDraft = true;
      _error = null;
    });

    try {
      final draft = await ErpService.makePaymentEntryFromCustomer(result.name);
      final company = draft['company'] as String?;

      List<_OutstandingInvoice> outstanding = [];
      String? outstandingError;
      if (company != null) {
        try {
          final raw = await ErpService.getOutstandingReferenceDocuments(
            party: result.name,
            company: company,
          );
          // ERPNext يرجّع صف منفصل لكل شرط دفع في الفاتورة (لو مقسّمة على
          // دفعات) — كلهم بنفس voucher_no بس بـpayment_term مختلف. **لازم
          // نفضل عارضينهم منفصلين** لأن `Payment Entry` نفسه بيرفض التسجيل
          // من غير `payment_term` محدد لكل صف مرجع لما تخصيص شرط الدفع
          // مفعّل على الفاتورة (اتأكد حي: تجميعهم في صف واحد كان بيكسر
          // التحصيل بـ"لديه تخصيص بناءً على شرط الدفع ممكّن").
          outstanding = raw
              .map((doc) {
                if (doc is! Map) return null;
                final map = Map<String, dynamic>.from(doc);
                final voucherNo = (map['voucher_no'] ?? map['reference_name'])
                    ?.toString();
                final outstandingAmount =
                    map['outstanding_amount'] ?? map['amount'];
                if (voucherNo == null || outstandingAmount is! num) return null;
                return _OutstandingInvoice(
                  voucherType:
                      (map['voucher_type'] ?? map['reference_doctype'] ?? 'Sales Invoice')
                          .toString(),
                  voucherNo: voucherNo,
                  outstandingAmount: outstandingAmount,
                  dueDate: map['due_date'] as String?,
                  paymentTerm: map['payment_term'] as String?,
                );
              })
              .whereType<_OutstandingInvoice>()
              .toList();

          // اتأكد حي: `due_date` الراجع من get_outstanding_reference_documents
          // بيكرر نفس التاريخ (تاريخ الفاتورة الإجمالي) لكل شروط الدفع —
          // مش التاريخ الحقيقي لكل شرط. التواريخ الصح موجودة بس في
          // `payment_schedule` بتاع الفاتورة نفسها (نفس الجدول المعروض في
          // شاشة الفاتورة وERPNext Desk). بنجيبها ونصحح بيها.
          outstanding = await _correctDueDatesFromPaymentSchedule(outstanding);

          // المتأخرة (استحقاقها فات) فوق ومتعلّم عليها، غير المستحقة لسه
          // تحت عادي — بدون إخفاء أي حاجة، كل المستحق بيفضل ظاهر.
          outstanding.sort((a, b) {
            if (a.isOverdue != b.isOverdue) {
              return a.isOverdue ? -1 : 1;
            }
            return (a.dueDate ?? '').compareTo(b.dueDate ?? '');
          });
        } catch (e) {
          // مش هيوقف تسجيل التحصيل (المندوب لسه يقدر يدخل مبلغ ويحصّله)،
          // بس لازم يبان — سكوت هنا هو بالظبط اللي خلى عطل حقيقي (نقص
          // party_account) يتفسّر غلط كـ"مفيش فواتير مستحقة" لفترة طويلة.
          outstandingError = 'تعذر تحميل الفواتير المستحقة: $e';
        }
      }

      if (!mounted) return;
      setState(() {
        _draftDoc = draft;
        _outstanding = outstanding;
        _outstandingError = outstandingError;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  void _toggleInvoice(String key) {
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        _selectedKeys.add(key);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedKeys
        ..clear()
        ..addAll(_outstanding.map((i) => i.key));
    });
  }

  num get _enteredAmount => double.tryParse(_amountController.text.trim()) ?? 0;

  /// Allocates the entered amount across selected invoices/terms in server
  /// order (oldest due first) — each row takes the smaller of what's left
  /// of the entered amount or its own outstanding balance. Keyed by
  /// [_OutstandingInvoice.key], not the bare voucher number, since one
  /// invoice can have several rows (one per payment term).
  Map<String, num> get _allocations {
    num remaining = _enteredAmount;
    final result = <String, num>{};
    for (final invoice in _outstanding) {
      if (!_selectedKeys.contains(invoice.key)) continue;
      if (remaining <= 0) break;
      final allocated = remaining < invoice.outstandingAmount
          ? remaining
          : invoice.outstandingAmount;
      result[invoice.key] = allocated;
      remaining -= allocated;
    }
    return result;
  }

  num get _totalAllocated => _allocations.values.fold(0, (a, b) => a + b);

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت (كان ده العطل
  /// الحقيقي المؤكد: "خطأ غير متوقع" بيظهر تحت زرار أخضر "تم التحصيل").
  Future<bool> _submit() async {
    if (_draftDoc == null || _selectedKeys.isEmpty || _enteredAmount <= 0) {
      return false;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    // Declared outside the `try` so `catch` can still reach it to enqueue
    // an offline job.
    Map<String, dynamic>? payload;
    try {
      final allocations = _allocations;
      final references = _outstanding
          .where((invoice) => allocations.containsKey(invoice.key))
          .map(
            (invoice) => {
              'reference_doctype': invoice.voucherType,
              'reference_name': invoice.voucherNo,
              'allocated_amount': allocations[invoice.key],
              'outstanding_amount': invoice.outstandingAmount,
              if (invoice.paymentTerm != null)
                'payment_term': invoice.paymentTerm,
            },
          )
          .toList();

      payload = Map<String, dynamic>.from(_draftDoc!);
      payload['paid_amount'] = _enteredAmount;
      payload['received_amount'] = _enteredAmount;
      payload['references'] = references;
      payload['custom_رقم_الإيصال_الورقي'] = _receiptNumberController.text.trim();
      final treasury = _treasury;
      if (treasury != null) {
        if (treasury.modeOfPayment != null) {
          payload['mode_of_payment'] = treasury.modeOfPayment;
        }
        if (treasury.account != null) payload['paid_to'] = treasury.account;
      }

      void resetForm() {
        _customer = null;
        _treasury = null;
        _draftDoc = null;
        _outstanding = [];
        _selectedKeys.clear();
        _amountController.clear();
        _receiptNumberController.clear();
      }

      // كل الحقول هنا مبنية من بيانات محلية بالفعل (`_draftDoc` كان اتحمّل
      // وقت اختيار العميل) — مفيش أي resolve حي مطلوب وقت الإرسال، فالتحصيل
      // ده أبسط من الطلبية/الفاتورة في الطابور: مجرد createDoc واحد وبس.
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.paymentEntryCreate,
          payload: payload,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(resetForm);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم حفظ التحصيل وسيُرسل تلقائيًا'),
          ),
        );
        return true;
      }

      final created = await ErpService.createDoc('Payment Entry', payload);

      if (!mounted) return true;
      setState(resetForm);

      if (!mounted) return true;
      final createdName = created['name'] as String?;
      if (createdName != null) {
        context.push(documentDetailRoute('Payment Entry', createdName));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم تسجيل التحصيل بنجاح')));
      }
      return true;
    } catch (e) {
      final capturedPayload = payload;
      if (e is ErpException && e.isConnectivityFailure && capturedPayload != null) {
        await SyncEngine().enqueue(
          type: SyncJobType.paymentEntryCreate,
          payload: capturedPayload,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        setState(() {
          _customer = null;
          _treasury = null;
          _draftDoc = null;
          _outstanding = [];
          _selectedKeys.clear();
          _amountController.clear();
          _receiptNumberController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم حفظ التحصيل وسيُرسل تلقائيًا'),
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

  bool get _canSubmit =>
      _draftDoc != null &&
      !_submitting &&
      _selectedKeys.isNotEmpty &&
      _enteredAmount > 0 &&
      _receiptNumberController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final totalAllocated = _totalAllocated;
    final unallocated = _enteredAmount - totalAllocated;

    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('تحصيل من عميل')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Material(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      onTap: _pickCustomer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.storefront_rounded,
                              color: AppColors.accent,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _customer?.label ?? 'اختر العميل',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (_loadingDraft)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            const Icon(
                              Icons.chevron_left_rounded,
                              color: AppColors.midGray,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_draftDoc != null) ...[
                    const SizedBox(height: 24),
                    const Text(
                      'المبلغ المحصّل',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(hintText: '0.00'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'رقم الإيصال الورقي *',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _receiptNumberController,
                      decoration: const InputDecoration(hintText: 'رقم الإيصال في الدفتر الورقي'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'الخزنة ',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Material(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        onTap: () async {
                          final picked = await pickTreasury(context);
                          if (picked != null) {
                            setState(() => _treasury = picked);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.account_balance_wallet_rounded,
                                color: AppColors.accent,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _treasury?.treasuryName ??
                                      'حدد أي خزنة استلمت المبلغ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_left_rounded,
                                color: AppColors.midGray,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'الفواتير المستحقة',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (_outstanding.isNotEmpty)
                          TextButton(
                            onPressed: _selectAll,
                            child: const Text('تحديد الكل'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_outstandingError != null)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: AppColors.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _outstandingError!,
                                style: const TextStyle(
                                  color: AppColors.accent,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (_outstanding.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.white,
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        child: const Center(
                          child: Text(
                            'لا توجد فواتير مستحقة على هذا العميل',
                            style: TextStyle(color: AppColors.midGray),
                          ),
                        ),
                      )
                    else
                      ..._outstanding.map((invoice) {
                        final selected = _selectedKeys.contains(invoice.key);
                        final allocated = _allocations[invoice.key];
                        final overdue = invoice.isOverdue;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: overdue
                                ? AppColors.accent.withValues(alpha: 0.06)
                                : AppColors.white,
                            borderRadius: BorderRadius.circular(AppRadius.card),
                            border: selected
                                ? Border.all(
                                    color: AppColors.accent,
                                    width: 1.5,
                                  )
                                : (overdue
                                      ? Border.all(
                                          color: AppColors.accent.withValues(
                                            alpha: 0.4,
                                          ),
                                        )
                                      : null),
                          ),
                          child: CheckboxListTile(
                            value: selected,
                            onChanged: (_) => _toggleInvoice(invoice.key),
                            activeColor: AppColors.accent,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    invoice.paymentTerm != null
                                        ? '${invoice.voucherNo} — ${invoice.paymentTerm}'
                                        : invoice.voucherNo,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                ),
                                if (overdue)
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
                            ),
                            subtitle: Text(
                              'المستحق: ${invoice.outstandingAmount}'
                              '${invoice.dueDate != null ? ' — الاستحقاق: ${invoice.dueDate}' : ''}'
                              '${allocated != null ? '\nسيُحصّل منها: ${allocated.toStringAsFixed(2)}' : ''}',
                              style: const TextStyle(
                                color: AppColors.midGray,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        );
                      }),
                    if (_selectedKeys.isNotEmpty &&
                        _enteredAmount > 0) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          unallocated > 0.01
                              ? 'تم توزيع ${totalAllocated.toStringAsFixed(2)} من ${_enteredAmount.toStringAsFixed(2)} — الباقي (${unallocated.toStringAsFixed(2)}) بدون فاتورة محددة'
                              : 'تم توزيع المبلغ بالكامل على الفواتير المحددة',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ],
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
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Opacity(
                opacity: _canSubmit ? 1 : 0.4,
                child: IgnorePointer(
                  ignoring: !_canSubmit,
                  child: SwipeToConfirmButton(
                    label: 'اسحب لتأكيد التحصيل',
                    confirmedLabel: 'تم التحصيل',
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
}
