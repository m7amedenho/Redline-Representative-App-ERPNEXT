import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../local_db/app_database.dart';
import '../local_db/sync_job_type.dart';
import 'erp_service.dart';

/// Tracks two things every offline-aware screen needs: are we actually
/// reachable (not just "the phone has a network interface"), and how many
/// queued operations are still waiting to go out. A `ChangeNotifier`
/// rather than another static class (unlike `ErpService`/`AuthService`)
/// because the persistent status banner and the sync-queue screen both
/// need to rebuild live as these values change, without polling.
///
/// Deliberately does NOT know about `SyncEngine` — this service only
/// reports connectivity/queue state; `SyncEngine` (added separately)
/// listens to it and decides when to actually drain the queue. Keeping
/// the dependency one-directional avoids a circular import between the
/// two.
///
/// Background work (the connectivity subscription, the 45s fallback poll,
/// the pending-count watch) only runs while at least one widget is actually
/// listening — started on the first [addListener], stopped on the last
/// [removeListener] — rather than the instant this singleton is first
/// touched. `SyncStatusBar` (mounted for the app's whole lifetime in
/// production) uses `ListenableBuilder`, which calls those two methods
/// automatically, so this is transparent there. It also means a widget
/// test that mounts and then unmounts the widget tree leaves no dangling
/// `Timer` behind — the "app boots" smoke test does exactly this.
class SyncStatusService extends ChangeNotifier {
  SyncStatusService._(this._db);

  static SyncStatusService? _instance;

  /// Widget tests that pump the real `RedErpApp` (and so mount the real,
  /// always-on `SyncStatusBar`) must not spin up a live `connectivity_plus`
  /// platform-channel subscription, a real network ping, or the drift
  /// database connection (`NativeDatabase.createInBackground` starts its
  /// own background isolate) — none of these reliably tear down within a
  /// single `testWidgets` body, which `flutter_test` flags as a leaked
  /// `Timer` at teardown. Set to `true` before pumping such a test.
  @visibleForTesting
  static bool disableBackgroundWorkForTests = false;

  /// Lazily created once, shared everywhere — same singleton style as
  /// `AppDatabase.instance`.
  factory SyncStatusService() =>
      _instance ??= SyncStatusService._(AppDatabase.instance);

  final AppDatabase _db;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<List<SyncJob>>? _pendingCountSub;
  Timer? _fallbackTimer;
  Timer? _debounce;
  int _listenerCount = 0;

  // Starts optimistic (assumed online) rather than pessimistic. This was a
  // real, confirmed bug: starting `false` meant every screen's "queue if
  // offline" gate (all of them check this flag BEFORE attempting anything
  // live) would misfire for the first few seconds after app start —
  // photo attach was the one actually noticed, but every other offline
  // gate had the exact same race. The device is online far more often
  // than not, and every one of those call sites already has a real
  // connectivity-failure fallback for when this guess is wrong (an actual
  // offline device just gets its first live attempt fail fast and fall
  // through to the same queue path) — so defaulting `true` trades a rare,
  // recoverable failure mode for a common, silent, unrecoverable-looking
  // one.
  bool _isOnline = true;
  int _pendingCount = 0;
  bool _checking = false;

  /// Best-effort reachability signal — starts optimistic, corrected by the
  /// first real `/api/method/ping` (never inferred from `connectivity_plus`
  /// alone). Screens gating on this must still treat a live-call failure as
  /// authoritative over this cached flag — see [ErpException.isConnectivityFailure].
  bool get isOnline => _isOnline;

  int get pendingCount => _pendingCount;

  bool get isChecking => _checking;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    if (_listenerCount == 1) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount == 0) _stop();
  }

  void _start() {
    if (disableBackgroundWorkForTests) return;
    _watchPendingCount();
    _listenToConnectivityChanges();
    // Best-effort initial check — don't block on it.
    unawaited(checkNow());
  }

  void _stop() {
    _connectivitySub?.cancel();
    _pendingCountSub?.cancel();
    _fallbackTimer?.cancel();
    _debounce?.cancel();
    _connectivitySub = null;
    _pendingCountSub = null;
    _fallbackTimer = null;
    _debounce = null;
  }

  void _watchPendingCount() {
    final query = _db.select(_db.syncJobs)
      ..where(
        (t) => t.status.isIn([
          SyncJobStatus.pending.name,
          SyncJobStatus.inProgress.name,
          SyncJobStatus.needsReview.name,
        ]),
      );
    _pendingCountSub = query.watch().listen((rows) {
      _pendingCount = rows.length;
      notifyListeners();
    });
  }

  void _listenToConnectivityChanges() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      // A raw interface-change event is a trigger to re-verify, never
      // treated as "online" by itself — debounced since some devices fire
      // several of these in quick succession for one real change.
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 800), checkNow);
    });

    // Connectivity events don't always fire reliably on every device/
    // network combination — a light foreground-only fallback poll keeps
    // the status from ever going stale for long.
    _fallbackTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => checkNow(),
    );
  }

  /// Forces an immediate reachability check — used on app resume, a manual
  /// "sync now" tap, and internally on connectivity/timer triggers.
  Future<bool> checkNow() async {
    if (_checking) return _isOnline;
    _checking = true;
    notifyListeners();
    try {
      final reachable = await ErpService.ping();
      if (reachable != _isOnline) {
        _isOnline = reachable;
      }
      return reachable;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }
}
