import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';

class _VisitRow {
  const _VisitRow({
    required this.name,
    required this.customer,
    required this.customerLabel,
    required this.visitDatetime,
    this.notes,
  });

  final String name;
  final String customer;
  final String customerLabel;
  final String visitDatetime;
  final String? notes;
}

class _OverdueCustomer {
  const _OverdueCustomer({
    required this.name,
    required this.label,
    this.lastVisitDate,
  });

  final String name;
  final String label;
  final String? lastVisitDate;

  int? daysSinceLastVisit() {
    if (lastVisitDate == null) return null;
    final parsed = DateTime.tryParse(lastVisitDate!);
    if (parsed == null) return null;
    return DateTime.now().difference(parsed).inDays;
  }
}

/// زيارات العملاء الحقيقية — `Customer Visit` (custom DocType، اتعمل خصيصًا
/// لده) بدل الـ`ComingSoonView` القديم. تابين:
/// - "زياراتي": قائمة الزيارات المسجلة (السيرفر بيقيّدها لمنطقة المندوب
///   عبر Permission Query Script "Filter Customer Visits By Rep Territory").
/// - "عملاء متأخرين": عملاء منطقة المندوب (نفس فلتر `Territory` المستخدم
///   في كل بيكر عميل بالتطبيق) اللي آخر زيارة ليهم أقدم من
///   `Territory.custom_visit_frequency_days` (افتراضي 30 يوم لو الحقل
///   فاضي) — أو ملهمش زيارة خالص.
class CustomerVisitsScreen extends StatefulWidget {
  const CustomerVisitsScreen({super.key});

  @override
  State<CustomerVisitsScreen> createState() => _CustomerVisitsScreenState();
}

class _CustomerVisitsScreenState extends State<CustomerVisitsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  bool _loadingVisits = true;
  String? _visitsError;
  List<_VisitRow> _visits = [];

  bool _loadingOverdue = false;
  String? _overdueError;
  List<_OverdueCustomer> _overdue = [];
  bool _overdueLoaded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (_tabController.index == 1 && !_overdueLoaded && !_loadingOverdue) {
          _loadOverdue();
        }
      });
    _loadVisits();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadVisits() async {
    setState(() {
      _loadingVisits = true;
      _visitsError = null;
    });
    try {
      final rows = await ErpService.getList(
        'Customer Visit',
        fields: const ['name', 'customer', 'visit_datetime', 'notes'],
        orderBy: 'visit_datetime desc',
        limit: 100,
      );
      final customerIds = rows
          .map((r) => r['customer'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final labels = <String, String>{};
      if (customerIds.isNotEmpty) {
        final customers = await ErpService.getList(
          'Customer',
          filters: [
            ['name', 'in', customerIds],
          ],
          fields: const ['name', 'customer_name'],
          limit: customerIds.length,
        );
        for (final c in customers) {
          labels[c['name'] as String] =
              (c['customer_name'] as String?) ?? c['name'] as String;
        }
      }

      if (!mounted) return;
      setState(() {
        _visits = rows
            .map((r) {
              final customer = r['customer'] as String?;
              if (customer == null) return null;
              return _VisitRow(
                name: r['name'] as String,
                customer: customer,
                customerLabel: labels[customer] ?? customer,
                visitDatetime: (r['visit_datetime'] as String?) ?? '',
                notes: r['notes'] as String?,
              );
            })
            .whereType<_VisitRow>()
            .toList();
        _loadingVisits = false;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loadingVisits = false;
        _visitsError = message ?? 'تعذر تحميل الزيارات';
      });
    }
  }

  Future<void> _loadOverdue() async {
    setState(() {
      _loadingOverdue = true;
      _overdueError = null;
    });
    try {
      final territories = await ErpService.getExpandedUserTerritories();
      if (territories.isEmpty) {
        setState(() {
          _loadingOverdue = false;
          _overdueLoaded = true;
          _overdueError = 'لا توجد مناطق مرتبطة بحسابك';
        });
        return;
      }

      final customers = await ErpService.getList(
        'Customer',
        filters: [
          ['territory', 'in', territories],
        ],
        fields: const ['name', 'customer_name', 'territory'],
        limit: 200,
      );
      if (customers.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loadingOverdue = false;
          _overdueLoaded = true;
          _overdue = [];
        });
        return;
      }

      final customerNames = customers.map((c) => c['name'] as String).toList();

      final visitRows = await ErpService.getList(
        'Customer Visit',
        filters: [
          ['customer', 'in', customerNames],
        ],
        fields: const ['customer', 'visit_datetime'],
        orderBy: 'visit_datetime desc',
        limit: 1000,
      );
      final lastVisit = <String, String>{};
      for (final v in visitRows) {
        final customer = v['customer'] as String?;
        final date = v['visit_datetime'] as String?;
        if (customer == null || date == null) continue;
        lastVisit.putIfAbsent(customer, () => date);
      }

      final territoryFrequency = <String, int>{};
      final territoryNames = customers
          .map((c) => c['territory'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      if (territoryNames.isNotEmpty) {
        final territoryRows = await ErpService.getList(
          'Territory',
          filters: [
            ['name', 'in', territoryNames],
          ],
          fields: const ['name', 'custom_visit_frequency_days'],
          limit: territoryNames.length,
        );
        for (final t in territoryRows) {
          final freq = t['custom_visit_frequency_days'] as num?;
          if (freq != null && freq > 0) {
            territoryFrequency[t['name'] as String] = freq.toInt();
          }
        }
      }

      final overdue = <_OverdueCustomer>[];
      final now = DateTime.now();
      for (final c in customers) {
        final name = c['name'] as String;
        final territory = c['territory'] as String?;
        final frequencyDays =
            (territory != null ? territoryFrequency[territory] : null) ?? 30;
        final lastDate = lastVisit[name];
        final daysSince = lastDate != null
            ? now.difference(DateTime.tryParse(lastDate) ?? now).inDays
            : null;
        if (lastDate == null || (daysSince ?? 0) >= frequencyDays) {
          overdue.add(
            _OverdueCustomer(
              name: name,
              label: (c['customer_name'] as String?) ?? name,
              lastVisitDate: lastDate,
            ),
          );
        }
      }
      overdue.sort((a, b) {
        final aDays = a.daysSinceLastVisit() ?? 1 << 30;
        final bDays = b.daysSinceLastVisit() ?? 1 << 30;
        return bDays.compareTo(aDays);
      });

      if (!mounted) return;
      setState(() {
        _overdue = overdue;
        _loadingOverdue = false;
        _overdueLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      setState(() {
        _loadingOverdue = false;
        _overdueLoaded = true;
        _overdueError = message ?? 'تعذر تحميل العملاء المتأخرين';
      });
    }
  }

  /// نتيجة الشيت: `true` = اتسجلت زيارة، [PickedRecord] = "روح لتحصيل" —
  /// التنقّل الفعلي بيحصل هنا بعد ما الشيت يقفل تمامًا (`context` بتاع
  /// الشاشة نفسها، مضمون صالح طول ما الشاشة لسه موجودة)، مش من جوه
  /// الشيت وهو بيتقفل في نفس اللحظة — ده كان بيسبب تنقّل مش موثوق على
  /// بعض الأجهزة.
  Future<void> _logVisit({PickedRecord? presetCustomer}) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (context) => _LogVisitSheet(presetCustomer: presetCustomer),
    );
    if (result == true) {
      _loadVisits();
      if (_overdueLoaded) _loadOverdue();
    } else if (result is PickedRecord) {
      if (!mounted) return;
      context.push('/payment-entry', extra: result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const Text('زيارات العملاء'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.black,
          indicatorColor: AppColors.accent,
          tabs: const [
            Tab(text: 'زياراتي'),
            Tab(text: 'عملاء متأخرين'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _logVisit(),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.accent,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('تسجيل زيارة'),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [_buildVisitsTab(), _buildOverdueTab()],
        ),
      ),
    );
  }

  Widget _buildVisitsTab() {
    if (_loadingVisits) return const LoadingIndicator();
    if (_visitsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _visitsError!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_visits.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد زيارات مسجلة بعد',
          style: TextStyle(color: AppColors.midGray),
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadVisits,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _visits.length,
        itemBuilder: (context, i) {
          final visit = _visits[i];
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Row(
              children: [
                const Icon(Icons.storefront_rounded, color: AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        visit.customerLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        visit.visitDatetime,
                        style: const TextStyle(
                          color: AppColors.midGray,
                          fontSize: 11.5,
                        ),
                      ),
                      if (visit.notes != null &&
                          visit.notes!.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          visit.notes!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildOverdueTab() {
    if (_loadingOverdue) return const LoadingIndicator();
    if (_overdueError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _overdueError!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_overdueLoaded) {
      return const LoadingIndicator();
    }
    if (_overdue.isEmpty) {
      return const Center(
        child: Text(
          'كل عملاء خط سيرك متابَعين — مفيش حد متأخر عليه زيارة',
          style: TextStyle(color: AppColors.midGray),
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _loadOverdue,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _overdue.length,
        itemBuilder: (context, i) {
          final customer = _overdue[i];
          final days = customer.daysSinceLastVisit();
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
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
                      Text(
                        customer.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        days == null
                            ? 'لم تُسجَّل له زيارة من قبل'
                            : 'آخر زيارة من $days يوم',
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _logVisit(
                    presetCustomer: PickedRecord(
                      name: customer.name,
                      label: customer.label,
                    ),
                  ),
                  icon: const Icon(Icons.add_location_alt_rounded, size: 16),
                  label: const Text('تسجيل زيارة'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// حوار تسجيل زيارة — بيلتقط GPS تلقائي best-effort (نفس نمط
/// `_captureLocationGeoJson` من `customer_registration_screen.dart`، مش
/// حاجب/إجباري، لأن الزيارة عبارة عن لحظة توثيق سريعة مش مستند لازم يتمنع
/// حفظه من غير موقع).
class _LogVisitSheet extends StatefulWidget {
  const _LogVisitSheet({this.presetCustomer});

  final PickedRecord? presetCustomer;

  @override
  State<_LogVisitSheet> createState() => _LogVisitSheetState();
}

const _visitTypes = ['زيارة', 'تحصيل', 'تنشيط'];

class _LogVisitSheetState extends State<_LogVisitSheet> {
  PickedRecord? _customer;
  String _visitType = 'زيارة';
  final _notesController = TextEditingController();
  final _receiptController = TextEditingController();
  bool _submitting = false;
  bool _lastSubmitWasQueued = false;
  String? _error;
  String? _receiptError;

  @override
  void initState() {
    super.initState();
    _customer = widget.presetCustomer;
  }

  @override
  void dispose() {
    _notesController.dispose();
    _receiptController.dispose();
    super.dispose();
  }

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
    final result = await showSearchPicker(
      context: context,
      title: 'اختر العميل',
      hintText: 'ابحث باسم العميل...',
      search: (query) async {
        final filters = <List<dynamic>>[
          if (query.isNotEmpty) ['customer_name', 'like', '%$query%'],
          if (territories.length == 1)
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
    );
    if (result != null) setState(() => _customer = result);
  }

  Future<String?> _captureLocationGeoJson() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {},
            'geometry': {
              'type': 'Point',
              'coordinates': [position.longitude, position.latitude],
            },
          },
        ],
      });
    } catch (_) {
      return null;
    }
  }

  /// بيقفل شيت تسجيل الزيارة وياخده مباشرة لشاشة "تحصيل من عميل" الحقيقية
  /// بنفس العميل جاهز — بدل ما يسجل زيارة "تحصيل" من غير ما يعمل التحصيل
  /// الفعلي فعلاً.
  void _goToCollection() {
    final customer = _customer;
    if (customer == null) return;
    // بيقفل الشيت بس ويرجّع العميل كنتيجة — التنقّل الفعلي بيحصل بعدين في
    // `_CustomerVisitsScreenState._logVisit`، مش هنا، عشان منستخدمش context
    // الشيت لحظة ما هو بيتقفل.
    Navigator.of(context).pop(customer);
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submit() async {
    final customer = _customer;
    if (customer == null) return false;
    // رقم الوصل إجباري لو الزيارة "تحصيل" — لا معنى لتسجيل تحصيل بدون
    // إثبات الوصل الورقي اللي اتحصّل بيه.
    final receipt = _receiptController.text.trim();
    if (_visitType == 'تحصيل' && receipt.isEmpty) {
      setState(() => _receiptError = 'رقم الوصل مطلوب لتسجيل تحصيل');
      return false;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _receiptError = null;
      _lastSubmitWasQueued = false;
    });
    // Declared outside the `try` so `catch` can still reach it to enqueue
    // an offline job.
    Map<String, dynamic>? body;
    try {
      final location = await _captureLocationGeoJson();
      body = <String, dynamic>{
        'customer': customer.name,
        'visit_type': _visitType,
        if (receipt.isNotEmpty) 'receipt_number': receipt,
        if (customer.subtitle != null && customer.subtitle!.isNotEmpty)
          'territory': customer.subtitle,
        if (_notesController.text.trim().isNotEmpty)
          'notes': _notesController.text.trim(),
        if (location != null) 'location': location,
      };

      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.customerVisitCreate,
          payload: body,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم حفظ الزيارة وستُرسل تلقائيًا'),
          ),
        );
        return true;
      }

      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson != null) body['sales_person'] = salesPerson;
      final created = await ErpService.createDoc('Customer Visit', body);
      if (!mounted) return true;
      Navigator.of(context).pop(true);
      final createdName = created['name'] as String?;
      if (createdName != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم تسجيل الزيارة بنجاح')));
      }
      return true;
    } catch (e) {
      final capturedBody = body;
      if (e is ErpException && e.isConnectivityFailure && capturedBody != null) {
        await SyncEngine().enqueue(
          type: SyncJobType.customerVisitCreate,
          payload: capturedBody,
        );
        _lastSubmitWasQueued = true;
        if (!mounted) return true;
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم حفظ الزيارة وستُرسل تلقائيًا'),
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
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'تسجيل زيارة',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 16),
            Material(
              color: AppColors.lightGray,
              borderRadius: BorderRadius.circular(AppRadius.field),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.field),
                onTap: widget.presetCustomer != null ? null : _pickCustomer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.storefront_rounded,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _customer?.label ?? 'اختر العميل',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _customer == null
                                ? AppColors.midGray
                                : AppColors.black,
                          ),
                        ),
                      ),
                      if (widget.presetCustomer == null)
                        const Icon(
                          Icons.chevron_left_rounded,
                          color: AppColors.midGray,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'نوع الزيارة',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _visitTypes.map((type) {
                final selected = _visitType == type;
                return ChoiceChip(
                  label: Text(type),
                  selected: selected,
                  selectedColor: AppColors.accent,
                  labelStyle: TextStyle(
                    color: selected ? AppColors.white : AppColors.black,
                    fontWeight: FontWeight.w700,
                  ),
                  onSelected: (_) => setState(() {
                    _visitType = type;
                    _receiptError = null;
                  }),
                );
              }).toList(),
            ),
            if (_visitType == 'تحصيل') ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _receiptController,
                decoration: InputDecoration(
                  hintText: 'رقم الوصل (لو حصّلت بالفعل)',
                  errorText: _receiptError,
                ),
                onChanged: (_) {
                  if (_receiptError != null)
                    setState(() => _receiptError = null);
                },
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _customer == null ? null : _goToCollection,
                icon: const Icon(Icons.payments_rounded, size: 18),
                label: const Text('الذهاب لتحصيل جديد من هذا العميل'),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'ملاحظات (اختياري)...',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.accent, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 16),
            Opacity(
              opacity: (_customer == null || _submitting) ? 0.4 : 1,
              child: IgnorePointer(
                ignoring: _customer == null || _submitting,
                child: SwipeToConfirmButton(
                  label: 'اسحب لحفظ الزيارة',
                  confirmedLabel: 'تم الحفظ',
                  onConfirmed: _submit,
                  wasQueued: () => _lastSubmitWasQueued,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
