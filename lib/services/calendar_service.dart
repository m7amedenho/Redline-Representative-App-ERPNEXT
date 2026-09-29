import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Adds payment-due reminders straight into the device's own calendar app
/// (`device_calendar` — the standard Android Calendar Provider, not a
/// separate Google API integration). Whichever account already syncs that
/// calendar on the phone (a signed-in Google account, in the common case)
/// picks the event up automatically; the calendar app's own reminder/
/// notification system is what actually alerts the rep — this app doesn't
/// need to run in the background or manage its own notification schedule
/// for this.
class CalendarService {
  static final _plugin = DeviceCalendarPlugin();
  static bool _timezoneReady = false;
  static String? lastError;

  static void _ensureTimezone() {
    if (_timezoneReady) return;
    tz_data.initializeTimeZones();
    // The ERP installation and its sales operation use Cairo dates.  A
    // named IANA zone preserves DST rules, unlike a fixed UTC offset.
    tz.setLocalLocation(tz.getLocation('Africa/Cairo'));
    _timezoneReady = true;
  }

  /// Ensures calendar permission, then picks a real writable calendar to
  /// add events to — prefers one that isn't read-only (a genuine synced
  /// account calendar, not e.g. a read-only holiday calendar). Returns
  /// null if permission is denied or the device genuinely has no calendar
  /// at all (callers should show that as a clear, specific failure, not a
  /// silent no-op).
  static Future<String?> _resolveWritableCalendarId() async {
    var hasPermissions = await _plugin.hasPermissions();
    if (hasPermissions.data != true) {
      final requested = await _plugin.requestPermissions();
      if (requested.data != true) return null;
    }

    final calendarsResult = await _plugin.retrieveCalendars();
    final calendars = calendarsResult.data ?? const <Calendar>[];

    final writable = calendars
        .where((c) => c.isReadOnly == false && c.id != null)
        .toList();
    if (writable.isEmpty) {
      // Some Android phones expose only read-only holiday calendars until
      // an account calendar is created. Create an app-owned local calendar
      // once so reminders still work without requiring a Google account.
      final created = await _plugin.createCalendar(
        'Red ERP - الاستحقاقات',
        localAccountName: 'Red ERP',
      );
      if (created.data != null && created.data!.isNotEmpty) {
        return created.data;
      }
      lastError = created.errors
          .map((e) => e.errorMessage)
          .whereType<String>()
          .join('\n');
      if (lastError?.isEmpty ?? true) {
        lastError = 'لا يوجد تقويم قابل للكتابة وتعذر إنشاء تقويم محلي.';
      }
      return null;
    }

    final defaults = writable.where((c) => c.isDefault == true).toList();
    return (defaults.isNotEmpty ? defaults.first : writable.first).id;
  }

  /// Adds one reminder event for a single payment-schedule due date — a
  /// 30-minute event at 9:00 AM on [dueDate], with two reminders (the day
  /// before, and right at 9:00 AM on the day itself) so the rep actually
  /// gets a notification instead of just a silent calendar entry. Returns
  /// true on success; false means permission was denied or the device has
  /// no usable calendar — callers should surface that plainly, not treat
  /// it as "done".
  static Future<bool> addPaymentReminder({
    required String customerName,
    required String documentName,
    required num amount,
    required DateTime dueDate,
  }) async {
    lastError = null;
    try {
      _ensureTimezone();
      final calendarId = await _resolveWritableCalendarId();
      if (calendarId == null) {
        lastError ??= 'تعذر إنشاء تقويم Red ERP. تأكد من منح صلاحية التقويم.';
        return false;
      }

      final start = tz.TZDateTime(
        tz.local,
        dueDate.year,
        dueDate.month,
        dueDate.day,
        9,
      );
      final end = start.add(const Duration(minutes: 30));

      final event = Event(
        calendarId,
        title: 'استحقاق دفعة — $customerName',
        description:
            'مستند: $documentName\n'
            'المبلغ المستحق: ${amount.toStringAsFixed(2)} ج.م',
        start: start,
        end: end,
        reminders: [
          Reminder(minutes: 0),
          Reminder(minutes: 24 * 60),
        ],
      );

      final result = await _plugin.createOrUpdateEvent(event);
      if (result?.data != null) return true;
      lastError = result?.errors
          .map((e) => e.errorMessage)
          .whereType<String>()
          .join('\n');
      if (lastError?.isEmpty ?? true) {
        lastError = 'رفض تطبيق التقويم إضافة الحدث.';
      }
      return false;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }
}
