import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/erp_service.dart';
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
  required String referenceName,
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

  try {
    final location = await _captureVisitLocation();
    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    final body = <String, dynamic>{
      'customer': customer,
      if (territory != null && territory.isNotEmpty) 'territory': territory,
      if (salesPerson != null) 'sales_person': salesPerson,
      if (notes.isNotEmpty) 'notes': notes,
      if (location != null) 'location': location,
      'reference_doctype': referenceDoctype,
      'reference_name': referenceName,
    };
    await ErpService.createDoc('Customer Visit', body);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تسجيل الزيارة بنجاح')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تسجيل الزيارة، لكن المستند اتحفظ بنجاح')),
      );
    }
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
