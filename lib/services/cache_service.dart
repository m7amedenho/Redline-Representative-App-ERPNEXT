import 'dart:convert';

import 'package:drift/drift.dart';

import '../local_db/app_database.dart';
import 'erp_service.dart';

class CachedListResult {
  const CachedListResult({
    required this.rows,
    required this.fromCache,
    required this.cachedAt,
  });

  final List<Map<String, dynamic>> rows;

  /// True when this came from a PREVIOUS successful fetch, not the live
  /// call just made — the UI should show a "آخر تحديث: ..." hint so the
  /// rep knows it might be stale rather than silently treating it as
  /// ground truth (matters most for anything with a credit-limit/balance
  /// implication).
  final bool fromCache;

  final DateTime cachedAt;
}

/// Generic read-through cache for `getList`-shaped queries — reference
/// data a rep should still be able to *view* offline (a customer's
/// statement, outstanding invoices, prices) even though creating new
/// documents against stale numbers stays gated by the online-only rules
/// elsewhere. Keyed by an arbitrary `(cacheDoctype, cacheKey)` pair rather
/// than one real drift table per screen — the set of cacheable views will
/// grow, and this way adding one never needs a schema migration.
///
/// Deliberately only caches successful LIST fetches, not writes — this has
/// nothing to do with `SyncEngine`'s queue.
class CacheService {
  static final AppDatabase _db = AppDatabase.instance;

  /// Tries the live [fetch] first. On success, caches the result and
  /// returns it fresh. On a connectivity failure, falls back to the last
  /// successful cache for this exact key, if any — and rethrows only when
  /// there's truly nothing to fall back to, or when the server genuinely
  /// rejected the request (a real rejection means it's a rule problem —
  /// showing stale data over hiding it as an error would just be
  /// confusing).
  static Future<CachedListResult> getListCached({
    required String cacheDoctype,
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetch,
  }) async {
    try {
      final rows = await fetch();
      final now = DateTime.now();
      await _write(cacheDoctype, cacheKey, rows, now);
      return CachedListResult(rows: rows, fromCache: false, cachedAt: now);
    } catch (e) {
      final isConnectivityFailure = e is ErpException
          ? e.isConnectivityFailure
          : true;
      if (!isConnectivityFailure) rethrow;

      final cached = await _read(cacheDoctype, cacheKey);
      if (cached != null) return cached;
      rethrow;
    }
  }

  static Future<void> _write(
    String cacheDoctype,
    String cacheKey,
    List<Map<String, dynamic>> rows,
    DateTime cachedAt,
  ) {
    return _db
        .into(_db.referenceCache)
        .insertOnConflictUpdate(
          ReferenceCacheCompanion.insert(
            doctype: cacheDoctype,
            name: cacheKey,
            dataJson: jsonEncode(rows),
            cachedAt: cachedAt,
          ),
        );
  }

  /// Same contract as [getListCached], plus [onCacheHit] — called
  /// synchronously with the last cached copy (if any) BEFORE the live
  /// [fetch] even starts, so a screen can paint instantly instead of
  /// showing a spinner for however long a weak connection takes to time
  /// out. The eventual return value is still the live result (or the same
  /// cache again, on a connectivity failure) — a caller should `setState`
  /// once from [onCacheHit] and once more from the awaited return, so a
  /// slow network silently upgrades the screen from "cached" to "live"
  /// instead of blocking on it.
  static Future<CachedListResult> getListStaleWhileRevalidate({
    required String cacheDoctype,
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetch,
    required void Function(CachedListResult cached) onCacheHit,
  }) async {
    final cached = await _read(cacheDoctype, cacheKey);
    if (cached != null) onCacheHit(cached);
    try {
      final rows = await fetch();
      final now = DateTime.now();
      await _write(cacheDoctype, cacheKey, rows, now);
      return CachedListResult(rows: rows, fromCache: false, cachedAt: now);
    } catch (e) {
      final isConnectivityFailure = e is ErpException
          ? e.isConnectivityFailure
          : true;
      if (!isConnectivityFailure) rethrow;
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Deletes every cached entry under [cacheDoctype] (every `cacheKey`
  /// variant — e.g. every workflow-state list for a doctype in Pending
  /// Approvals), so the next read is forced to go live instead of quietly
  /// keeping a copy that a just-arrived push notification says is stale.
  /// Used by [PrefetchService.handlePushRefresh] — a push telling the app
  /// "this doctype changed" invalidates rather than tries to guess which
  /// exact cache key is now wrong.
  static Future<void> invalidate(String cacheDoctype) {
    return (_db.delete(
      _db.referenceCache,
    )..where((t) => t.doctype.equals(cacheDoctype))).go();
  }

  static Future<CachedListResult?> _read(
    String cacheDoctype,
    String cacheKey,
  ) async {
    final row =
        await (_db.select(_db.referenceCache)..where(
              (t) => t.doctype.equals(cacheDoctype) & t.name.equals(cacheKey),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.dataJson) as List;
    return CachedListResult(
      rows: decoded.cast<Map<String, dynamic>>(),
      fromCache: true,
      cachedAt: row.cachedAt,
    );
  }
}
