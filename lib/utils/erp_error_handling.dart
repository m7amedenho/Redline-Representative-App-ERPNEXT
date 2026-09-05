import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/erp_service.dart';

/// Shared handling for errors thrown by [ErpService] calls across screens.
///
/// If the session actually expired (access token rejected and the silent
/// refresh also failed), redirects straight to `/auth` and returns null —
/// the caller should just bail out without setting any error state. For
/// every other failure, returns the Arabic message to show inline.
String? handleErpError(BuildContext context, Object error) {
  if (error is ErpException) {
    if (error.sessionExpired) {
      context.go('/auth');
      return null;
    }
    return error.message;
  }
  return 'حدث خطأ غير متوقع، حاول مرة أخرى لاحقًا.';
}
