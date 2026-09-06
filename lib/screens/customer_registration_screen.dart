import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../local_db/sync_job_type.dart';
import '../services/auth_service.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';
import 'document_detail_screen.dart';

const _customerTypes = ['Individual', 'Company', 'Partnership'];
const _customerTypeLabels = {
  'Individual': 'فرد',
  'Company': 'شركة',
  'Partnership': 'شراكة',
};

/// Formats a locally-entered Egyptian mobile number (`01xxxxxxxxx`) into the
/// `+20xxxxxxxxxx` E.164-ish form the server's `custom_رقم_الهاتف` Phone
/// field actually requires — confirmed live: a plain `01xxxxxxxxx` value is
/// rejected with `InvalidPhoneNumberError` ("Please select a country code").
/// Leaves an already-prefixed value (`+...`) untouched.
String _formatPhone(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.startsWith('+')) return trimmed;
  final digits = trimmed.startsWith('0') ? trimmed.substring(1) : trimmed;
  return '+20$digits';
}

/// New-customer registration AND editing — `POST`/`PUT
/// /api/resource/Customer`. Every field name below is confirmed from a real
/// ERD dump of this site's `Customer` DocType (not guessed — see
/// docs/API_INTEGRATION_NOTES.md), including the Arabic-named custom fields
/// (`custom_رقم_الهاتف`/`custom_رقم_الهاتف_اخر`/`custom_العنوان`/
/// `custom_الضمانات` — the last one is `reqd=1` on the server, so it's
/// required here too) and the Geolocation field `custom_location`.
///
/// Registration/edits now go through a real approval Workflow
/// ("موافقات العملاء", created server-side) — `disabled` is kept in sync
/// with `workflow_state` by a server script, so this screen no longer needs
/// to fake it. `territory` and `sales_team` are auto-assigned on CREATE
/// only, same pattern as Sales Order/Invoice.
///
/// When [editDoc] is given, the screen edits that existing customer instead
/// of creating a new one — same `editDoc` pattern as `SalesOrderScreen`.
class CustomerRegistrationScreen extends StatefulWidget {
  const CustomerRegistrationScreen({super.key, this.editDoc});

  final Map<String, dynamic>? editDoc;

  @override
  State<CustomerRegistrationScreen> createState() =>
      _CustomerRegistrationScreenState();
}

class _CustomerRegistrationScreenState
    extends State<CustomerRegistrationScreen> {
  final _nameController = TextEditingController();
  final _phone1Controller = TextEditingController();
  final _phone2Controller = TextEditingController();
  final _addressController = TextEditingController();
  final _guaranteesController = TextEditingController();
  final _creditLimitController = TextEditingController();

  String _customerType = 'Individual';
  PickedRecord? _customerGroup;
  PickedRecord? _gender;
  PickedRecord? _priceList;
  PickedRecord? _paymentTerms;

  String? _territory;
  List<String> _territoryChoices = const [];
  bool _resolvingTerritory = true;

  bool _submitting = false;
  String? _error;
  String? _locationStatus;
  String? _capturedLocationGeoJson;
  bool _capturingLocation = false;

  /// النظام العامل يفتحه لو فشل تحديد الموقع لسبب قابل للحل من الإعدادات
  /// (GPS مقفول / صلاحية مرفوضة نهائيًا) — نفس نمط [SalesOrderScreen].
  Future<void> Function()? _locationFix;

  bool get _isEditing => widget.editDoc != null;

  @override
  void initState() {
    super.initState();
    final editDoc = widget.editDoc;
    if (editDoc != null) {
      _loadFromEditDoc(editDoc);
      _territory = editDoc['territory'] as String?;
      _resolvingTerritory = false;
    } else {
      _resolveTerritory();
    }
  }

  void _loadFromEditDoc(Map<String, dynamic> doc) {
    _nameController.text = (doc['customer_name'] as String?) ?? '';
    _customerType = (doc['customer_type'] as String?) ?? 'Individual';
    _phone1Controller.text = (doc['custom_رقم_الهاتف'] as String?) ?? '';
    _phone2Controller.text = (doc['custom_رقم_الهاتف_اخر'] as String?) ?? '';
    _addressController.text = (doc['custom_العنوان'] as String?) ?? '';

    final guarantees = doc['custom_الضمانات'];
    if (guarantees is String) {
      // Text Editor field — may carry HTML from Desk; strip tags for the
      // plain-text field here, best-effort.
      _guaranteesController.text = guarantees
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
    }

    final customerGroup = doc['customer_group'] as String?;
    if (customerGroup != null && customerGroup.isNotEmpty) {
      _customerGroup = PickedRecord(name: customerGroup, label: customerGroup);
    }
    final gender = doc['gender'] as String?;
    if (gender != null && gender.isNotEmpty) {
      _gender = PickedRecord(name: gender, label: gender);
    }
    final priceList = doc['default_price_list'] as String?;
    if (priceList != null && priceList.isNotEmpty) {
      _priceList = PickedRecord(name: priceList, label: priceList);
    }
    final paymentTerms = doc['payment_terms'] as String?;
    if (paymentTerms != null && paymentTerms.isNotEmpty) {
      _paymentTerms = PickedRecord(name: paymentTerms, label: paymentTerms);
    }

    final creditLimits = doc['credit_limits'];
    if (creditLimits is List && creditLimits.isNotEmpty) {
      final first = creditLimits.first;
      if (first is Map && first['credit_limit'] != null) {
        _creditLimitController.text = (first['credit_limit'] as num).toString();
      }
    }
  }

  /// Silent single-territory auto-assign, or a required picker when the
  /// rep genuinely has more than one — same layered lookup already proven
  /// for Sales Order/Invoice territory scoping. Never blocks the form on
  /// failure (falls back to letting the server/manager assign it later).
  Future<void> _resolveTerritory() async {
    try {
      final territories = await ErpService.getExpandedUserTerritories();
      if (!mounted) return;
      setState(() {
        if (territories.length == 1) {
          _territory = territories.first;
        } else {
          _territoryChoices = territories;
        }
        _resolvingTerritory = false;
      });
    } catch (_) {
      if (mounted) setState(() => _resolvingTerritory = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phone1Controller.dispose();
    _phone2Controller.dispose();
    _addressController.dispose();
    _guaranteesController.dispose();
    _creditLimitController.dispose();
    super.dispose();
  }

  /// Best-effort device location for `custom_location` — never blocks
  /// registration. Sets [_locationStatus] with the exact reason on every
  /// path so a failure is visible instead of looking identical to success.
  Future<String?> _captureLocationGeoJson() async {
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
    } catch (e) {
      _locationStatus = 'خطأ أثناء تحديد الموقع: $e';
      _locationFix = null;
      return null;
    }
  }

  /// زرار "تسجيل الموقع" الصريح — بيلتقط ويعرض النتيجة فورًا قبل الحفظ،
  /// بدل الالتقاط الصامت جوه [_submit] بس. لو فشل لسبب قابل للحل، الرسالة
  /// بتحمل زرار يفتح إعدادات الموقع/التطبيق مباشرة.
  Future<void> _onCaptureLocationTap() async {
    setState(() => _capturingLocation = true);
    final result = await _captureLocationGeoJson();
    if (!mounted) return;
    setState(() {
      _capturedLocationGeoJson = result;
      _capturingLocation = false;
    });
    final fix = _locationFix;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_locationStatus ?? ''),
        action: fix == null
            ? null
            : SnackBarAction(label: 'فتح الإعدادات', onPressed: () => fix()),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  bool get _canSubmit =>
      _nameController.text.trim().isNotEmpty &&
      _phone1Controller.text.trim().isNotEmpty &&
      _guaranteesController.text.trim().isNotEmpty &&
      !_submitting &&
      (_territoryChoices.isEmpty || _territory != null);

  Future<void> _pickTerritory() async {
    final choices = _territoryChoices;
    final selected = await showModalBottomSheet<String>(
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
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'اختر المنطقة',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              ...choices.map(
                (t) => ListTile(
                  title: Text(t),
                  trailing: _territory == t
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop(t),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) setState(() => _territory = selected);
  }

  Future<void> _pickLink({
    required String doctype,
    required String searchField,
    required String title,
    required void Function(PickedRecord?) onPicked,
    List<List<dynamic>>? extraFilters,
  }) async {
    final result = await showSearchPicker(
      context: context,
      title: title,
      search: (query) async {
        final filters = <List<dynamic>>[
          if (extraFilters != null) ...extraFilters,
          if (query.isNotEmpty) [searchField, 'like', '%$query%'],
        ];
        final list = await ErpService.getList(
          doctype,
          filters: filters.isEmpty ? null : filters,
          fields: const ['name'],
          limit: 20,
        );
        return list
            .map(
              (r) => PickedRecord(
                name: r['name'] as String,
                label: r['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result != null) onPicked(result);
  }

  /// `false` هنا معناها فشل حقيقي — [SwipeToConfirmButton] بيعكسها كحالة
  /// حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    // Declared outside the `try` so `catch` can still reach it to enqueue
    // an offline job.
    Map<String, dynamic>? body;
    try {
      // لو المستخدم ضغط زرار "تسجيل الموقع" صراحة قبل كدا، استخدم نتيجته
      // بدل إعادة الالتقاط — وإلا نفس الالتقاط الصامت القديم كـ fallback.
      final locationGeoJson =
          _capturedLocationGeoJson ?? await _captureLocationGeoJson();
      if (mounted && _capturedLocationGeoJson == null && _locationStatus != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('الموقع: $_locationStatus'),
            duration: const Duration(seconds: 3),
          ),
        );
      }

      body = <String, dynamic>{
        'customer_name': _nameController.text.trim(),
        'customer_type': _customerType,
        'custom_رقم_الهاتف': _formatPhone(_phone1Controller.text),
        'custom_الضمانات': _guaranteesController.text.trim(),
      };

      if (_phone2Controller.text.trim().isNotEmpty) {
        body['custom_رقم_الهاتف_اخر'] = _formatPhone(_phone2Controller.text);
      }
      if (_addressController.text.trim().isNotEmpty) {
        body['custom_العنوان'] = _addressController.text.trim();
      }
      if (locationGeoJson != null) {
        body['custom_location'] = locationGeoJson;
      }
      if (_territory != null) body['territory'] = _territory;
      if (_customerGroup != null) body['customer_group'] = _customerGroup!.name;
      if (_customerType == 'Individual' && _gender != null) {
        body['gender'] = _gender!.name;
      }
      if (_priceList != null) body['default_price_list'] = _priceList!.name;
      if (_paymentTerms != null) body['payment_terms'] = _paymentTerms!.name;

      final editDoc = widget.editDoc;
      if (editDoc != null) {
        final editName = editDoc['name'] as String;
        final proposedLimit = double.tryParse(
          _creditLimitController.text.trim(),
        );

        if (!SyncStatusService().isOnline) {
          if (proposedLimit != null && proposedLimit > 0) {
            body['_proposedCreditLimit'] = proposedLimit;
          }
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Customer',
              'name': editName,
              'data': body,
            },
          );
          if (!mounted) return true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('لا يوجد اتصال — سيُحفظ التعديل تلقائيًا'),
            ),
          );
          Navigator.of(context).pop();
          return true;
        }

        if (proposedLimit != null && proposedLimit > 0) {
          final company = await ErpService.resolveDefaultCompany();
          if (company != null) {
            body['credit_limits'] = [
              {'company': company, 'credit_limit': proposedLimit},
            ];
          }
        }
        await ErpService.updateDoc('Customer', editName, body);
        if (!mounted) return true;
        Navigator.of(context).pop();
        return true;
      }

      // `account_manager` only needs the already-locally-stored user id —
      // safe to resolve even offline. `credit_limits` (needs
      // `resolveDefaultCompany`) and `sales_team` (needs
      // `resolveCurrentSalesPerson`) both need a live server round trip,
      // so they're deferred to `SyncEngine`'s replay when queued offline
      // — see `_proposedCreditLimit` below and
      // `SyncEngine._replayCustomerRegistrationCreate`.
      final currentUserId = await AuthService.currentUserId();
      if (currentUserId != null) {
        body['account_manager'] = currentUserId;
      }

      final proposedLimit = double.tryParse(_creditLimitController.text.trim());

      if (!SyncStatusService().isOnline) {
        if (proposedLimit != null && proposedLimit > 0) {
          body['_proposedCreditLimit'] = proposedLimit;
        }
        await SyncEngine().enqueue(
          type: SyncJobType.customerRegistrationCreate,
          payload: body,
        );
        if (!mounted) return true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — تم حفظ العميل وسيُرسل تلقائيًا'),
          ),
        );
        return true;
      }

      if (proposedLimit != null && proposedLimit > 0) {
        final company = await ErpService.resolveDefaultCompany();
        if (company != null) {
          body['credit_limits'] = [
            {'company': company, 'credit_limit': proposedLimit},
          ];
        }
      }

      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson != null) {
        body['sales_team'] = [
          {'sales_person': salesPerson, 'allocated_percentage': 100},
        ];
      }

      final created = await ErpService.createDoc('Customer', body);
      if (!mounted) return true;

      final createdName = created['name'] as String?;
      if (createdName != null) {
        context.push(documentDetailRoute('Customer', createdName));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم تسجيل العميل بنجاح')));
      }
      return true;
    } catch (e) {
      final capturedBody = body;
      if (e is ErpException && e.isConnectivityFailure && capturedBody != null) {
        final editDoc = widget.editDoc;
        if (editDoc != null) {
          await SyncEngine().enqueue(
            type: SyncJobType.genericApiCall,
            payload: {
              'operation': 'update',
              'doctype': 'Customer',
              'name': editDoc['name'] as String,
              'data': capturedBody,
            },
          );
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
          type: SyncJobType.customerRegistrationCreate,
          payload: capturedBody,
        );
        if (!mounted) return true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم حفظ العميل وسيُرسل تلقائيًا'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Text(_isEditing ? 'تعديل بيانات العميل' : 'تسجيل عميل جديد'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _label('اسم العميل'),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'اسم العميل / المحل',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  _label('نوع العميل'),
                  _buildCustomerTypeSelector(),
                  const SizedBox(height: 16),
                  _label('رقم الموبايل'),
                  TextFormField(
                    controller: _phone1Controller,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(hintText: '01xxxxxxxxx'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  _label('رقم موبايل آخر '),
                  TextFormField(
                    controller: _phone2Controller,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(hintText: '01xxxxxxxxx'),
                  ),
                  const SizedBox(height: 16),
                  _label('العنوان '),
                  TextFormField(
                    controller: _addressController,
                    decoration: const InputDecoration(
                      hintText: 'العنوان بالتفصيل',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('الموقع'),
                  Material(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(AppRadius.field),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                      onTap: _capturingLocation ? null : _onCaptureLocationTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            if (_capturingLocation)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              Icon(
                                _capturedLocationGeoJson != null
                                    ? Icons.location_on_rounded
                                    : Icons.location_searching_rounded,
                                color: AppColors.accent,
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _capturedLocationGeoJson != null
                                    ? (_locationStatus ?? 'تم تحديد الموقع')
                                    : 'تسجيل الموقع',
                                style: TextStyle(
                                  color: _capturedLocationGeoJson != null
                                      ? AppColors.black
                                      : AppColors.midGray,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('الضمانات'),
                  TextFormField(
                    controller: _guaranteesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'تفاصيل الضمانات...',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  _label('سقف الدين المقترح '),
                  TextFormField(
                    controller: _creditLimitController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(hintText: '0.00'),
                  ),
                  const SizedBox(height: 16),
                  _label('المجموعة '),
                  _buildPickerField(
                    label: _customerGroup?.label,
                    hint: 'اختر مجموعة العميل',
                    onTap: () => _pickLink(
                      doctype: 'Customer Group',
                      searchField: 'name',
                      title: 'اختر مجموعة العميل',
                      onPicked: (r) => setState(() => _customerGroup = r),
                    ),
                  ),
                  if (_customerType == 'Individual') ...[
                    const SizedBox(height: 16),
                    _label('النوع '),
                    _buildPickerField(
                      label: _gender?.label,
                      hint: 'اختر النوع',
                      onTap: () => _pickLink(
                        doctype: 'Gender',
                        searchField: 'name',
                        title: 'اختر النوع',
                        onPicked: (r) => setState(() => _gender = r),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _label('قائمة الأسعار '),
                  _buildPickerField(
                    label: _priceList?.label,
                    hint: 'اختر قائمة الأسعار',
                    onTap: () => _pickLink(
                      doctype: 'Price List',
                      searchField: 'name',
                      title: 'اختر قائمة الأسعار',
                      onPicked: (r) => setState(() => _priceList = r),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('شروط الدفع '),
                  _buildPickerField(
                    label: _paymentTerms?.label,
                    hint: 'اختر شروط الدفع',
                    onTap: () => _pickLink(
                      doctype: 'Payment Terms Template',
                      searchField: 'name',
                      title: 'اختر شروط الدفع',
                      onPicked: (r) => setState(() => _paymentTerms = r),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('المنطقة'),
                  if (_resolvingTerritory)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_territoryChoices.isEmpty)
                    Text(
                      _territory ?? 'سيتم تحديدها لاحقًا',
                      style: const TextStyle(
                        color: AppColors.midGray,
                        fontSize: 13,
                      ),
                    )
                  else
                    _buildPickerField(
                      label: _territory,
                      hint: 'اختر المنطقة',
                      onTap: _pickTerritory,
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    _errorRow(),
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
                    label: _isEditing
                        ? 'اسحب لحفظ التعديلات'
                        : 'اسحب لتسجيل العميل',
                    confirmedLabel: 'تم الحفظ',
                    onConfirmed: _submit,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickerField({
    required String? label,
    required String hint,
    required VoidCallback onTap,
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

  Widget _buildCustomerTypeSelector() {
    return Row(
      children: _customerTypes.map((type) {
        final selected = type == _customerType;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Material(
              color: selected ? AppColors.accent : AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.field),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.field),
                onTap: () => setState(() => _customerType = type),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _customerTypeLabels[type]!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected ? AppColors.white : AppColors.black,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
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
