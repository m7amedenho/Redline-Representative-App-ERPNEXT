import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../local_db/sync_job_type.dart';
import '../services/erp_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';

/// بعد إرسال طلبية/فاتورة بنجاح — يسأل المندوب هل يسجل زيارة لنفس العميل،
/// ولو "نعم" ياخد ملاحظة اختيارية، يلتقط GPS best-effort (زي
/// [CustomerVisitsScreen])، وينشئ `Customer Visit` مربوطة بالمستند اللي
/// اتبعت (`reference_doctype`/`reference_name`). فشل تسجيل الزيارة نفسها
/// (لو حصل) ميرجعش المستند الأساسي أو يوقف تدفق الشاشة — هو إضافة، مش شرط.
Future<void> promptLogVisit(
  BuildContext context, {
  required String customer,
  String? territory,
  required String referenceDoctype,
  String? referenceName,
  String visitType = 'زيارة',
  String? receiptNumber,
}) async {
  final wantsToLog = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text('تسجيل زيارة'),
      content: const Text('هل تريد تسجيل زيارة لهذا العميل؟'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('لا'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('نعم'),
        ),
      ],
    ),
  );
  if (wantsToLog != true || !context.mounted) return;

  final notesController = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text('ملاحظات الزيارة'),
      content: TextFormField(
        controller: notesController,
        maxLines: 3,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'ملاحظات (اختياري)...'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  final notes = notesController.text.trim();
  notesController.dispose();
  if (confirmed != true) return;

  Map<String, dynamic>? visitBody;
  try {
    final location = await _captureVisitLocation();
    if (location == null) {
      if (context.mounted) await _showLocationRequired(context);
      return;
    }
    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    visitBody = <String, dynamic>{
      'customer': customer,
      'visit_type': visitType,
      if (territory != null && territory.isNotEmpty) 'territory': territory,
      'sales_person': ?salesPerson,
      if (notes.isNotEmpty) 'notes': notes,
      if (receiptNumber != null && receiptNumber.trim().isNotEmpty)
        'receipt_number': receiptNumber.trim(),
      'location': location,
      if (referenceName != null && referenceName.isNotEmpty) ...{
        'reference_doctype': referenceDoctype,
        'reference_name': referenceName,
      },
    };
    final queued = !SyncStatusService().isOnline;
    if (queued) {
      await SyncEngine().enqueue(
        type: SyncJobType.customerVisitCreate,
        payload: visitBody,
      );
    } else {
      await ErpService.createDoc('Customer Visit', visitBody);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            queued
                ? 'تم حفظ الزيارة وستُرسل تلقائيًا عند عودة الاتصال'
                : 'تم تسجيل الزيارة بنجاح',
          ),
        ),
      );
    }
  } on ErpException catch (e) {
    if (e.isConnectivityFailure && visitBody != null) {
      await SyncEngine().enqueue(
        type: SyncJobType.customerVisitCreate,
        payload: visitBody,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — تم حفظ الزيارة وستُرسل تلقائيًا'),
          ),
        );
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر تسجيل الزيارة، لكن المستند اتحفظ بنجاح'),
        ),
      );
    }
  }
}

Future<void> _showLocationRequired(BuildContext context) async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  final permission = await Geolocator.checkPermission();
  if (!context.mounted) return;
  final openSettings = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('الموقع مطلوب'),
      content: const Text(
        'لا يمكن تسجيل زيارة بدون الموقع. شغّل GPS وامنح Red ERP صلاحية الموقع ثم حاول مرة أخرى.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('فتح الإعدادات'),
        ),
      ],
    ),
  );
  if (openSettings != true) return;
  if (!serviceEnabled) {
    await Geolocator.openLocationSettings();
  } else if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    await Geolocator.openAppSettings();
  }
}

Future<String?> _captureVisitLocation() async {
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
