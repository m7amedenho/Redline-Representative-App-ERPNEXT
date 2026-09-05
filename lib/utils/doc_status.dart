import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared status/color resolution for any ERPNext document — workflow
/// state first (if this DocType has an active workflow), then a plain
/// `status` field, then `docstatus` as a last resort. Used by
/// [DocumentDetailScreen] and any document-list screen (e.g. the "all
/// orders" list) that needs the same status chip without re-deriving it.
({String label, Color color}) docStatusInfo(Map<String, dynamic>? doc) {
  if (doc == null) return (label: '—', color: AppColors.midGray);

  final workflowState = doc['workflow_state'] as String?;
  if (workflowState != null && workflowState.isNotEmpty) {
    return (label: workflowState, color: AppColors.accent);
  }

  final status = doc['status'] as String?;
  if (status != null && status.isNotEmpty) {
    return (label: status, color: _colorForStatusText(status));
  }

  final docstatus = doc['docstatus'];
  switch (docstatus) {
    case 1:
      return (label: 'مُرسل', color: AppColors.success);
    case 2:
      return (label: 'ملغي', color: AppColors.accent);
    default:
      return (label: 'مسودة', color: AppColors.midGray);
  }
}

/// Sales Invoice payment status specifically — distinct from
/// [docStatusInfo] (which shows the *approval* workflow state while a
/// document is still in Draft/pending-approval). Once an invoice is fully
/// approved and submitted (`docstatus == 1`), what a rep actually needs to
/// track next is whether the customer has PAID, not the now-finished
/// approval chain — this reads the standard ERPNext `status` field (which
/// already resolves to "Unpaid"/"Overdue"/"Partly Paid"/"Paid"/etc. once
/// submitted, confirmed field, not custom) and maps it to Arabic. Returns
/// null while the invoice hasn't been submitted yet (`docstatus != 1`) —
/// callers should fall back to [docStatusInfo] in that case, since payment
/// status is meaningless before approval.
({String label, Color color})? invoicePaymentStatusInfo(
  Map<String, dynamic>? doc,
) {
  if (doc == null) return null;
  final docstatus = (doc['docstatus'] as num?)?.toInt() ?? 0;
  if (docstatus != 1) return null;

  final status = (doc['status'] as String?) ?? '';
  final lower = status.toLowerCase();
  if (lower.contains('overdue')) {
    return (label: 'متأخرة السداد', color: AppColors.accent);
  }
  if (lower == 'paid') {
    return (label: 'مسددة بالكامل', color: AppColors.success);
  }
  if (lower.contains('partly paid') || lower.contains('partially paid')) {
    return (label: 'مسددة جزئيًا', color: Colors.orange);
  }
  if (lower.contains('unpaid')) {
    return (label: 'غير مسددة', color: AppColors.midGray);
  }
  if (lower.contains('return') || lower.contains('credit note')) {
    return (label: status, color: AppColors.midGray);
  }
  if (status.isEmpty) return null;
  return (label: status, color: AppColors.midGray);
}

Color _colorForStatusText(String status) {
  final lower = status.toLowerCase();
  if (lower.contains('cancel') || lower.contains('overdue'))
    return AppColors.accent;
  if (lower.contains('paid') ||
      lower.contains('completed') ||
      lower.contains('closed')) {
    return AppColors.success;
  }
  if (lower.contains('draft')) return AppColors.midGray;
  return AppColors.accent;
}
