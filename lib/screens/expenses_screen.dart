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

enum _Step { chooseType, chooseVehicleSubtype, form }

const _repExpenseTypes = [
  'وجبات',
  'طريق',
  'فنادق وإقامة',
  'أخرى - مصروف مندوب',
];
const _vehicleOtherExpenseType = 'أخرى - مصروف سيارة';
const _vehicleOilExpenseType = 'زيت';

IconData _iconForExpenseType(String name) {
  switch (name) {
    case 'وجبات':
      return Icons.restaurant_rounded;
    case 'طريق':
      return Icons.route_rounded;
    case 'فنادق وإقامة':
      return Icons.hotel_rounded;
    case 'بنزين':
      return Icons.local_gas_station_rounded;
    case 'زيت':
      return Icons.opacity_rounded;
    case 'صيانة':
      return Icons.build_rounded;
    default:
      return Icons.more_horiz_rounded;
  }
}

/// Expenses — rebuilt on the real accounting foundation set up this round:
/// 8 curated `Expense Claim Type` records (the rep only ever sees these,
/// never the raw chart of accounts), a `Treasury` picker for which real
/// account the money moved through, and the "المندوب" Accounting Dimension
/// for per-rep reporting. Every path here does a plain `insert` + a direct
/// [ErpService.submitDoc] — **no workflow, no approval gate** — an explicit
/// product decision confirmed with the user: an expense must land in the
/// books the moment the rep records it.
///
/// Vehicle fuel/maintenance still goes through `Vehicle Log` first (real
/// DocType, tracks odometer/fuel/service history), then auto-creates and
/// submits its own linked `Expense Claim` via the real HRMS RPC
/// `hrms...vehicle_log.make_expense_claim` — see
/// [ErpService.makeExpenseClaimFromVehicleLog]. "أخرى" (vehicle) skips
/// Vehicle Log entirely — it's just a plain claim tagged
/// `[_vehicleOtherExpenseType]`, same as the personal path.
///
/// `license_plate` (→ `Vehicle`) and `service_item` (→
/// `Vehicle Service Item`) are real Link pickers now, not free text — a
/// mistyped plate used to fail with a raw `LinkValidationError`, confirmed
/// live this round. `employee`/`last_odometer` are resolved automatically
/// (the previous version never sent either, despite both being mandatory
/// on the server — every vehicle-log submission was silently broken).
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  _Step _step = _Step.chooseType;
  String? _type; // 'vehicle' | 'personal'
  String? _vehicleSubtype; // 'fuel' | 'maintenance' | 'other'

  PickedRecord? _vehicle;
  num? _lastOdometer;
  bool _loadingLastOdometer = false;

  PickedRecord? _serviceItem;
  PickedRecord? _expenseType;
  TreasuryInfo? _treasury;

  final _odometerController = TextEditingController();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();

  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;

  bool get _isVehicleLogForm =>
      _type == 'vehicle' &&
      (_vehicleSubtype == 'fuel' || _vehicleSubtype == 'maintenance');

  @override
  void dispose() {
    _odometerController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _handleBack() {
    setState(() {
      _error = null;
      if (_step == _Step.form) {
        if (_type == 'vehicle') {
          _step = _Step.chooseVehicleSubtype;
        } else {
          _step = _Step.chooseType;
          _type = null;
        }
        _vehicleSubtype = null;
      } else if (_step == _Step.chooseVehicleSubtype) {
        _step = _Step.chooseType;
        _type = null;
      }
    });
  }

  void _resetToStart() {
    _step = _Step.chooseType;
    _type = null;
    _vehicleSubtype = null;
    _vehicle = null;
    _lastOdometer = null;
    _serviceItem = null;
    _expenseType = null;
    _treasury = null;
    _odometerController.clear();
    _amountController.clear();
    _notesController.clear();
  }

  void _enterVehicleSubtype(String subtype) {
    setState(() {
      _vehicleSubtype = subtype;
      _step = _Step.form;
      if (subtype == 'other') {
        _expenseType = const PickedRecord(
          name: _vehicleOtherExpenseType,
          label: _vehicleOtherExpenseType,
        );
      } else if (subtype == 'oil') {
        // زيت بيمشي زي "أخرى" — مصروف مباشر بدون Vehicle Log/عداد مسافة،
        // لأنه مش محتاج تتبع كمية وقود أو مسافة زي البنزين/الصيانة.
        _expenseType = const PickedRecord(
          name: _vehicleOilExpenseType,
          label: _vehicleOilExpenseType,
        );
      }
    });
  }

  /// السيارة بتاعة المندوب الحالي لازم تظهر جاهزة من غير ما يدور عليها —
  /// `Vehicle.employee` (Link حقيقي مؤكد من مخطط السيرفر). Best-effort
  /// وصامت تمامًا: لو ملقاش سيارة مرتبطة (أو أكتر من واحدة)، البيكر اليدوي
  /// [_pickVehicle] لسه شغال زي ما هو — ده تحسين مش شرط.
  Future<void> _autoResolveVehicle() async {
    if (_vehicle != null) return;
    try {
      final employee = await ErpService.resolveCurrentEmployee();
      if (employee == null) return;
      final rows = await ErpService.getList(
        'Vehicle',
        filters: [
          ['employee', '=', employee],
        ],
        fields: const ['name', 'license_plate', 'make', 'model'],
        limit: 1,
      );
      if (rows.isEmpty || !mounted) return;
      final v = rows.first;
      final result = PickedRecord(
        name: v['name'] as String,
        label: (v['license_plate'] as String?) ?? v['name'] as String,
        subtitle: [
          if (v['make'] != null) v['make'] as String,
          if (v['model'] != null) v['model'] as String,
        ].join(' '),
      );
      setState(() => _vehicle = result);
      await _fetchLastOdometer(result.name);
    } catch (_) {
      // Best-effort — البيكر اليدوي لسه متاح.
    }
  }

  Future<void> _pickVehicle() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر السيارة',
      hintText: 'ابحث برقم اللوحة...',
      search: (query) async {
        final list = await ErpService.getList(
          'Vehicle',
          filters: query.isEmpty
              ? null
              : [
                  ['license_plate', 'like', '%$query%'],
                ],
          fields: const ['name', 'license_plate', 'make', 'model'],
          limit: 20,
        );
        return list
            .map(
              (v) => PickedRecord(
                name: v['name'] as String,
                label: (v['license_plate'] as String?) ?? v['name'] as String,
                subtitle: [
                  if (v['make'] != null) v['make'] as String,
                  if (v['model'] != null) v['model'] as String,
                ].join(' '),
              ),
            )
            .toList();
      },
    );
    if (result == null) return;
    setState(() {
      _vehicle = result;
      _lastOdometer = null;
    });
    await _fetchLastOdometer(result.name);
  }

  /// Real last-odometer, from the most recent existing `Vehicle Log` for
  /// this exact vehicle if one exists, otherwise `Vehicle.last_odometer`
  /// itself (its running total, kept up to date by the server's own
  /// `on_submit`/`on_cancel` hooks — see `vehicle_log.py`). Read-only in
  /// the UI on purpose: this is a record of reality, not something the rep
  /// should be free to overwrite.
  Future<void> _fetchLastOdometer(String vehicleName) async {
    setState(() => _loadingLastOdometer = true);
    try {
      final logs = await ErpService.getList(
        'Vehicle Log',
        filters: [
          ['license_plate', '=', vehicleName],
        ],
        fields: const ['odometer'],
        orderBy: 'date desc, creation desc',
        limit: 1,
      );
      if (logs.isNotEmpty) {
        if (mounted) {
          setState(() => _lastOdometer = logs.first['odometer'] as num?);
        }
        return;
      }
      final vehicleDoc = await ErpService.getDoc('Vehicle', vehicleName);
      if (mounted) {
        setState(() => _lastOdometer = vehicleDoc['last_odometer'] as num?);
      }
    } catch (_) {
      // Best-effort — the field just stays unknown, `last_odometer` sent
      // to the server falls back to the current reading (see submit).
    } finally {
      if (mounted) setState(() => _loadingLastOdometer = false);
    }
  }

  Future<void> _pickServiceItem() async {
    final result = await showSearchPicker(
      context: context,
      title: 'اختر نوع الصيانة',
      hintText: 'ابحث...',
      search: (query) async {
        final list = await ErpService.getList(
          'Vehicle Service Item',
          filters: query.isEmpty
              ? null
              : [
                  ['name', 'like', '%$query%'],
                ],
          fields: const ['name'],
          limit: 20,
        );
        return list
            .map(
              (s) => PickedRecord(
                name: s['name'] as String,
                label: s['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result != null) setState(() => _serviceItem = result);
  }

  /// كروت اختيار بأيقونة زي بيكر نوع مصروف السيارة بالظبط — مفيش داعي
  /// لصندوق بحث لـ4 خيارات ثابتة معروفة مسبقًا (نفس الأسماء الحقيقية
  /// المتأكد منها على السيرفر)، وده أوضح بصريًا من قايمة نصية.
  Future<void> _pickExpenseType() async {
    final width = (MediaQuery.of(context).size.width - 40 - 12) / 2;
    final result = await showModalBottomSheet<PickedRecord>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'اختر نوع المصروف',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: _repExpenseTypes.map((name) {
                    return SizedBox(
                      width: width,
                      child: _choiceCard(
                        icon: _iconForExpenseType(name),
                        label: name,
                        onTap: () => Navigator.of(
                          context,
                        ).pop(PickedRecord(name: name, label: name)),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (result != null) setState(() => _expenseType = result);
  }

  Future<void> _pickTreasury() async {
    final result = await pickTreasury(context);
    if (result != null) setState(() => _treasury = result);
  }

  bool get _canSubmitVehicleLog =>
      !_submitting &&
      _vehicle != null &&
      _treasury != null &&
      double.tryParse(_amountController.text.trim()) != null &&
      double.tryParse(_odometerController.text.trim()) != null &&
      (_vehicleSubtype != 'maintenance' || _serviceItem != null);

  bool get _canSubmitExpenseClaim =>
      !_submitting &&
      _expenseType != null &&
      _treasury != null &&
      double.tryParse(_amountController.text.trim()) != null;

  Future<void> _postNoteIfAny(String doctype, String name) async {
    final note = _notesController.text.trim();
    if (note.isEmpty) return;
    try {
      await ErpService.createDoc('Comment', {
        'comment_type': 'Comment',
        'reference_doctype': doctype,
        'reference_name': name,
        'content': note,
      });
    } catch (_) {
      // Best-effort — the expense itself already saved fine either way.
    }
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submitVehicleLogPath() async {
    if (!_canSubmitVehicleLog) return false;
    final vehicle = _vehicle!;
    final amount = double.parse(_amountController.text.trim());
    final odometer = double.parse(_odometerController.text.trim());
    final treasury = _treasury!;
    final today = DateTime.now().toIso8601String().split('T').first;

    // Built from local state only (no `resolveCurrentEmployee` — that
    // needs network, deferred to `SyncEngine`'s replay) so it can be
    // queued before even attempting a live call.
    Map<String, dynamic> buildOfflinePayload() => <String, dynamic>{
      'licensePlate': vehicle.name,
      'date': today,
      'odometer': odometer,
      'lastOdometer': _lastOdometer ?? odometer,
      'type': _vehicleSubtype == 'fuel' ? 'Fuel' : 'Service',
      if (_vehicleSubtype == 'fuel') 'fuelQty': 1,
      if (_vehicleSubtype == 'fuel') 'price': amount,
      if (_vehicleSubtype != 'fuel')
        'serviceDetail': [
          {
            'service_item': _serviceItem!.name,
            'type': 'Service',
            'frequency': 'Mileage',
            'expense_amount': amount,
          },
        ],
      'expenseType': _vehicleSubtype == 'fuel' ? 'بنزين' : 'صيانة',
      'amount': amount,
      'expenseDate': today,
      'modeOfPayment': treasury.modeOfPayment,
      'account': treasury.account,
      'note': _notesController.text.trim(),
    };

    Future<bool> queueOffline() async {
      await SyncEngine().enqueue(
        type: SyncJobType.expenseClaimVehicleLogChain,
        payload: buildOfflinePayload(),
      );
      _lastSubmitWasQueued = true;
      if (!mounted) return true;
      setState(_resetToStart);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا يوجد اتصال — تم الحفظ وسيُرسل تلقائيًا'),
        ),
      );
      return true;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    if (!SyncStatusService().isOnline) {
      final result = await queueOffline();
      if (mounted) setState(() => _submitting = false);
      return result;
    }

    try {
      final employee = await ErpService.resolveCurrentEmployee();
      if (employee == null) {
        setState(
          () => _error =
              'تعذر تحديد بيانات الموظف المرتبطة بحسابك — راجع الإدارة',
        );
        return false;
      }

      final body = <String, dynamic>{
        'license_plate': vehicle.name,
        'employee': employee,
        'date': DateTime.now().toIso8601String().split('T').first,
        'odometer': odometer,
        'last_odometer': _lastOdometer ?? odometer,
        'type': _vehicleSubtype == 'fuel' ? 'Fuel' : 'Service',
      };
      if (_vehicleSubtype == 'fuel') {
        body['fuel_qty'] = 1;
        body['price'] = amount;
      } else {
        body['service_detail'] = [
          {
            'service_item': _serviceItem!.name,
            'type': 'Service',
            'frequency': 'Mileage',
            'expense_amount': amount,
          },
        ];
      }

      final createdLog = await ErpService.createDoc('Vehicle Log', body);
      final logName = createdLog['name'] as String?;
      if (logName == null) {
        throw Exception('لم يرجع السيرفر اسم المستند بعد الإنشاء');
      }

      await _postNoteIfAny('Vehicle Log', logName);

      // كان ناقص خالص — `createDoc` بيسيب المستند مسودة (docstatus 0)،
      // وده مكانش بيتصلّح تاني في أي خطوة تانية (الـ RPC اللي بيعمل مطالبة
      // المصروفات بيقرأ من سجل المركبة، مش بيعتمده). النتيجة: كل سجل مركبة
      // كان فاضل "مسودة" على طول في Desk، وعداد المسافة (`last_odometer`)
      // بتاع السيارة نفسه بيتحدث بس في الـ on_submit hook — يعني كمان كان
      // بيفضل صفر لأي مركبة لسه محدش عمل submit يدوي لسجلاتها. مطالبة
      // المصروفات المرتبطة لسه بتتعمل حتى لو الاعتماد ده فشل، زي ما هو
      // موضح تحت.
      try {
        await ErpService.submitDoc('Vehicle Log', logName);
      } catch (_) {
        // نفس منطق التسامح تحت — سجل المركبة لسه محفوظ، المستخدم يقدر
        // يعتمده يدويًا لو فشل الاعتماد الآلي لأي سبب.
      }

      String? claimName;
      try {
        claimName = await _createAndSubmitLinkedExpenseClaim(
          vehicleLogName: logName,
          employee: employee,
          expenseType: _vehicleSubtype == 'fuel' ? 'بنزين' : 'صيانة',
          amount: amount,
          treasury: treasury,
        );
      } catch (_) {
        // المصروف المرتبط فشل — Vehicle Log نفسه لسه محفوظ صح، المستخدم
        // هيشوفه ويقدر يحاول تاني أو يراجعه يدويًا، مش هنخسر البيانات.
      }

      if (!mounted) return true;
      setState(_resetToStart);
      if (claimName != null) {
        context.push(documentDetailRoute('Expense Claim', claimName));
      } else {
        context.push(documentDetailRoute('Vehicle Log', logName));
      }
      return true;
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        return queueOffline();
      }
      if (!mounted) return false;
      final message = handleErpError(context, e);
      if (message != null) setState(() => _error = message);
      return false;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Fetches the safe draft (linkage + duplicate guard + computed amount)
  /// via [ErpService.makeExpenseClaimFromVehicleLog], then replaces its one
  /// generic row with a properly categorized one so it posts to the right
  /// account in the new chart-of-accounts structure, attaches the
  /// treasury/employee/approver/dimension, and submits immediately.
  Future<String> _createAndSubmitLinkedExpenseClaim({
    required String vehicleLogName,
    required String employee,
    required String expenseType,
    required num amount,
    required TreasuryInfo treasury,
  }) async {
    final draft = await ErpService.makeExpenseClaimFromVehicleLog(
      vehicleLogName,
    );
    final body = Map<String, dynamic>.from(draft)..remove('name');
    body['expenses'] = [
      {
        'expense_type': expenseType,
        'amount': amount,
        'expense_date': DateTime.now().toIso8601String().split('T').first,
      },
    ];
    await _attachPaymentAndDimension(
      body,
      employee: employee,
      treasury: treasury,
    );

    final created = await ErpService.createDoc('Expense Claim', body);
    final name = created['name'] as String;
    await ErpService.submitDoc('Expense Claim', name);
    return name;
  }

  /// `currency`/`exchange_rate` are genuinely mandatory server fields with
  /// no auto-default on a bare API insert (confirmed live: omitting them
  /// throws `MandatoryError`) — Desk's own client JS normally fills these
  /// in, which a REST create bypasses entirely. `approval_status` is a
  /// SEPARATE, real HRMS business rule (`expense_claim.py#on_submit`,
  /// confirmed live): submission is refused unless it's explicitly
  /// "Approved" or "Rejected" beforehand, regardless of any workflow —
  /// setting it to "Approved" here IS the "no human gate, lands in the
  /// books immediately" behavior, not a workaround for one.
  ///
  /// `sanctioned_amount`/`cost_center`/`payable_account` are the real fix
  /// for a genuinely nasty bug confirmed live this round: without them, the
  /// claim would insert and submit successfully, report `is_paid: 1`, and
  /// STILL post zero GL entries — worse, `grand_total`/`total_sanctioned_amount`
  /// themselves silently compute to 0 (Desk's client JS normally copies
  /// `amount` → `sanctioned_amount` as you type; a bare REST insert skips
  /// that entirely), and per-line `cost_center` is mandatory for GL
  /// construction even though the document-level one auto-defaults. A
  /// missing `payable_account` fails GL entry construction outright even
  /// with `is_paid=1`. All three confirmed by reproducing the exact bug
  /// live and iterating until real GL Entries appeared.
  Future<void> _attachPaymentAndDimension(
    Map<String, dynamic> body, {
    required String employee,
    required TreasuryInfo treasury,
  }) async {
    body['currency'] = 'EGP';
    body['exchange_rate'] = 1;
    body['approval_status'] = 'Approved';
    body['is_paid'] = 1;
    if (treasury.modeOfPayment != null)
      body['mode_of_payment'] = treasury.modeOfPayment;
    if (treasury.account != null)
      body['bank_or_cash_account'] = treasury.account;

    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) body['المندوب'] = salesPerson;

    final approver = await ErpService.resolveExpenseApprover(employee);
    if (approver != null) body['expense_approver'] = approver;

    final defaults = await ErpService.resolveExpenseAccountingDefaults(employee);
    if (defaults.payableAccount != null) {
      body['payable_account'] = defaults.payableAccount;
    }
    final expenses = body['expenses'];
    if (expenses is List) {
      for (final row in expenses) {
        if (row is! Map) continue;
        row['sanctioned_amount'] = row['amount'];
        if (defaults.costCenter != null && row['cost_center'] == null) {
          row['cost_center'] = defaults.costCenter;
        }
      }
    }
    if (defaults.costCenter != null) body['cost_center'] = defaults.costCenter;
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submitExpenseClaimPath() async {
    if (!_canSubmitExpenseClaim) return false;
    final expenseType = _expenseType!;
    final amount = double.parse(_amountController.text.trim());
    final treasury = _treasury!;
    final today = DateTime.now().toIso8601String().split('T').first;

    Future<bool> queueOffline() async {
      await SyncEngine().enqueue(
        type: SyncJobType.expenseClaimPersonalCreate,
        payload: {
          'expenseType': expenseType.name,
          'amount': amount,
          'expenseDate': today,
          'modeOfPayment': treasury.modeOfPayment,
          'account': treasury.account,
          'note': _notesController.text.trim(),
        },
      );
      _lastSubmitWasQueued = true;
      if (!mounted) return true;
      setState(_resetToStart);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا يوجد اتصال — تم الحفظ وسيُرسل تلقائيًا'),
        ),
      );
      return true;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _lastSubmitWasQueued = false;
    });

    if (!SyncStatusService().isOnline) {
      final result = await queueOffline();
      if (mounted) setState(() => _submitting = false);
      return result;
    }

    // `true` only once `createDoc` below actually succeeds — a connectivity
    // failure AFTER that point (e.g. the `submitDoc` call) must NOT queue a
    // fresh duplicate claim; the created draft is already recoverable
    // manually from its own document screen.
    var created = false;
    try {
      final employee = await ErpService.resolveCurrentEmployee();
      if (employee == null) {
        setState(
          () => _error =
              'تعذر تحديد بيانات الموظف المرتبطة بحسابك — راجع الإدارة',
        );
        return false;
      }

      final body = <String, dynamic>{
        'employee': employee,
        'posting_date': today,
        'expenses': [
          {
            'expense_type': expenseType.name,
            'amount': amount,
            'expense_date': today,
          },
        ],
      };
      await _attachPaymentAndDimension(
        body,
        employee: employee,
        treasury: treasury,
      );

      final createdDoc = await ErpService.createDoc('Expense Claim', body);
      created = true;
      final createdName = createdDoc['name'] as String?;
      if (createdName == null) {
        throw Exception('لم يرجع السيرفر اسم المستند بعد الإنشاء');
      }

      await _postNoteIfAny('Expense Claim', createdName);
      await ErpService.submitDoc('Expense Claim', createdName);

      if (!mounted) return true;
      setState(_resetToStart);
      context.push(documentDetailRoute('Expense Claim', createdName));
      return true;
    } catch (e) {
      if (!created && e is ErpException && e.isConnectivityFailure) {
        return queueOffline();
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
        title: const Text('تسجيل مصروف'),
        leading: _step == _Step.chooseType
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _handleBack,
              ),
      ),
      body: SafeArea(child: _buildStepBody()),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case _Step.chooseType:
        return _buildChooseTypeStep();
      case _Step.chooseVehicleSubtype:
        return _buildChooseVehicleSubtypeStep();
      case _Step.form:
        return _isVehicleLogForm
            ? _buildVehicleLogForm()
            : _buildExpenseClaimForm();
    }
  }

  Widget _buildChooseTypeStep() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('نوع المصروف'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _choiceCard(
                  icon: Icons.restaurant_rounded,
                  label: 'شخصي',
                  onTap: () => setState(() {
                    _type = 'personal';
                    _step = _Step.form;
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _choiceCard(
                  icon: Icons.directions_car_rounded,
                  label: 'سيارة',
                  onTap: () {
                    setState(() {
                      _type = 'vehicle';
                      _step = _Step.chooseVehicleSubtype;
                    });
                    _autoResolveVehicle();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChooseVehicleSubtypeStep() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('نوع مصروف السيارة'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _choiceCard(
                  icon: Icons.local_gas_station_rounded,
                  label: 'وقود',
                  onTap: () => _enterVehicleSubtype('fuel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _choiceCard(
                  icon: Icons.opacity_rounded,
                  label: 'زيت',
                  onTap: () => _enterVehicleSubtype('oil'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _choiceCard(
                  icon: Icons.build_rounded,
                  label: 'صيانة',
                  onTap: () => _enterVehicleSubtype('maintenance'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _choiceCard(
                  icon: Icons.more_horiz_rounded,
                  label: 'أخرى',
                  onTap: () => _enterVehicleSubtype('other'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choiceCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.card),
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.06),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.accent, size: 32),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVehicleLogForm() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _label('السيارة'),
              _pickerField(
                label: _vehicle?.label,
                hint: 'اختر السيارة',
                onTap: _pickVehicle,
              ),
              if (_vehicle != null) ...[
                const SizedBox(height: 4),
                Text(
                  _loadingLastOdometer
                      ? 'جاري تحميل آخر قراءة...'
                      : (_lastOdometer != null
                            ? 'آخر قراءة مسجلة: ${_lastOdometer!.toStringAsFixed(0)}'
                            : 'لا توجد قراءة سابقة (أول تسجيل لهذه السيارة)'),
                  style: const TextStyle(
                    color: AppColors.midGray,
                    fontSize: 11.5,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _label('قراءة العداد الحالية'),
              TextFormField(
                controller: _odometerController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'كم'),
                onChanged: (_) => setState(() {}),
              ),
              if (_vehicleSubtype == 'maintenance') ...[
                const SizedBox(height: 16),
                _label('نوع الصيانة'),
                _pickerField(
                  label: _serviceItem?.label,
                  hint: 'اختر نوع الصيانة',
                  onTap: _pickServiceItem,
                ),
              ],
              const SizedBox(height: 16),
              _label(
                _vehicleSubtype == 'fuel' ? 'تكلفة الوقود' : 'تكلفة الصيانة',
              ),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(hintText: '0.00'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              _label('الخزنة'),
              _pickerField(
                label: _treasury?.treasuryName,
                hint: 'اختر الخزنة اللي دفعت منها',
                onTap: _pickTreasury,
              ),
              const SizedBox(height: 16),
              _label('ملاحظات '),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'تفاصيل إضافية...'),
              ),
              if (_error != null) ...[const SizedBox(height: 12), _errorRow()],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Opacity(
            opacity: _canSubmitVehicleLog ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !_canSubmitVehicleLog,
              child: SwipeToConfirmButton(
                label: 'اسحب لتسجيل المصروف',
                confirmedLabel: 'تم التسجيل',
                onConfirmed: _submitVehicleLogPath,
                wasQueued: () => _lastSubmitWasQueued,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExpenseClaimForm() {
    final hasPresetType =
        _type == 'vehicle' &&
        (_vehicleSubtype == 'other' || _vehicleSubtype == 'oil');

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!hasPresetType) ...[
                _label('نوع المصروف'),
                _pickerField(
                  label: _expenseType?.label,
                  hint: 'اختر نوع المصروف',
                  onTap: _pickExpenseType,
                  leadingIcon: _expenseType != null
                      ? _iconForExpenseType(_expenseType!.name)
                      : null,
                ),
                const SizedBox(height: 16),
              ],
              _label('المبلغ'),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(hintText: '0.00'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              _label('الخزنة'),
              _pickerField(
                label: _treasury?.treasuryName,
                hint: 'اختر الخزنة اللي دفعت منها',
                onTap: _pickTreasury,
              ),
              const SizedBox(height: 16),
              _label('ملاحظات '),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'تفاصيل إضافية...'),
              ),
              if (_error != null) ...[const SizedBox(height: 12), _errorRow()],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Opacity(
            opacity: _canSubmitExpenseClaim ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !_canSubmitExpenseClaim,
              child: SwipeToConfirmButton(
                label: 'اسحب لتسجيل المصروف',
                confirmedLabel: 'تم التسجيل',
                onConfirmed: _submitExpenseClaimPath,
                wasQueued: () => _lastSubmitWasQueued,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pickerField({
    required String? label,
    required String hint,
    required VoidCallback onTap,
    IconData? leadingIcon,
  }) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.field),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              if (leadingIcon != null) ...[
                Icon(leadingIcon, color: AppColors.accent, size: 18),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label ?? hint,
                  style: TextStyle(
                    color: label == null ? AppColors.midGray : AppColors.black,
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
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _errorRow() {
    return Row(
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
    );
  }
}
