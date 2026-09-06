import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../main.dart' show openDocumentFromNotification;
import 'auth_service.dart';
import 'erp_service.dart';

/// Registers this device's FCM token against the logged-in user
/// (`User.custom_fcm_token`) so a server-side sender (not a Server
/// Script — see the offline/notifications plan) can push a real
/// system notification on every workflow step, matching the existing
/// `Notification Log`/in-app bell one-for-one.
///
/// Entirely best-effort: until the Android app is registered in the
/// Firebase project and `google-services.json` is dropped into
/// `android/app/`, `Firebase.initializeApp()` below fails and every method
/// here just no-ops — the app must never crash or block on this being
/// unconfigured.
class PushNotificationService {
  PushNotificationService._();

  static bool _initialized = false;

  /// Call once after a successful login (and again on app start if a
  /// session is already stored) — fetches the current device's FCM token
  /// and saves it, then keeps it updated if it ever rotates.
  static Future<void> registerForCurrentUser() async {
    try {
      if (!_initialized) {
        await Firebase.initializeApp();
        _initialized = true;
      }

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);

      messaging.onTokenRefresh.listen((newToken) {
        _saveToken(newToken);
      });

      // Tapped from the system tray while the app was backgrounded — same
      // `doctype`/`name` data payload the bell's own notifications use.
      FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) _handleTap(initialMessage);
    } catch (e, stackTrace) {
      // Expected until Firebase is actually configured for this app —
      // never let a missing/incomplete Firebase setup break login or
      // startup.
      debugPrint('PushNotificationService: not active yet ($e)');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static void _handleTap(RemoteMessage message) {
    final doctype = message.data['doctype'];
    final name = message.data['name'];
    if (doctype is String && name is String) {
      openDocumentFromNotification(doctype, name);
    }
  }

  static Future<void> _saveToken(String token) async {
    try {
      final userId = await AuthService.currentUserId();
      if (userId == null) return;
      await ErpService.updateDoc('User', userId, {
        'custom_fcm_token': token,
      });
    } catch (_) {
      // Best-effort — a failed token save just means this device won't
      // get push notifications until the next successful attempt (app
      // resume, token refresh, next login).
    }
  }
}
