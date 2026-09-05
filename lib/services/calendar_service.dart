import 'package:device_calendar/device_calendar.dart';
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
    final calendars = calendarsResult.data;
    if (calendars == null || calendars.isEmpty) return null;

    final writable = calendars.where((c) => c.isReadOnly != true).toList();
    final chosen = writable.isNotEmpty ? writable.first : calendars.first;
    return chosen.id;
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
    final calendarId = await _resolveWritableCalendarId();
    if (calendarId == null) return false;

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
        Reminder(minutes: 0), // 9:00 AM on the due date itself
        Reminder(minutes: 24 * 60), // one day before
      ],
    );

    final result = await _plugin.createOrUpdateEvent(event);
    return result?.data != null;
  }
}
