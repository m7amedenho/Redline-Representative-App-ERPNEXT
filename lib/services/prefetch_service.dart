import 'cache_service.dart';
import 'erp_service.dart';
import 'sync_status_service.dart';

/// Fired once, best-effort, right after the home screen opens with a real
/// connection — warms the same [CacheService] entries the list screens
/// read from, so a rep who opens Customers/Sales Orders/... a minute later
/// on a weak connection gets an instant cached paint instead of waiting on
/// a live call that may never even finish. Every entry here uses the exact
/// same `cacheDoctype`/`cacheKey` the real screen's own load uses (see
/// their `_load`/`_search` methods) — this only pre-warms that same cache,
/// it doesn't introduce a second source of truth.
///
/// Deliberately silent and non-blocking: nothing here ever surfaces an
/// error or blocks navigation — a failed prefetch just means the relevant
/// screen falls back to its own normal live-or-cached load when opened.
class PrefetchService {
  static bool _ranThisSession = false;

  static Future<void> warmCachesOnce() async {
    if (_ranThisSession) return;
    _ranThisSession = true;
    if (!SyncStatusService().isOnline) return;

    await Future.wait([
      _warmCustomers(),
      _warmSalesOrders(),
      _warmSalesInvoices(),
      _warmPendingTransfers(),
    ]);
  }

  /// Reacts to a push notification's `data.doctype` (see
  /// `PushNotificationService`) — a workflow step just happened server-side
  /// on a document of this type, so whatever this app has cached about it
  /// (the Pending Approvals list for every state of this doctype, plus the
  /// matching "all X" list screen) is stale as of right now. Invalidates
  /// those entries outright rather than guessing which cache key changed,
  /// then re-warms the ones with a single well-known key so the very next
  /// open — even offline a second later — already has the fresh copy
  /// instead of falling back to the now-stale one.
  static Future<void> handlePushRefresh(String doctype) async {
    if (!SyncStatusService().isOnline) return;
    try {
      await CacheService.invalidate('${doctype}_pending_list');
      switch (doctype) {
        case 'Sales Order':
          await CacheService.invalidate('Sales Order_list');
          await _warmSalesOrders();
        case 'Sales Invoice':
          await CacheService.invalidate('Sales Invoice_list');
          await CacheService.invalidate('DueInvoices');
          await _warmSalesInvoices();
        case 'Customer':
          await CacheService.invalidate('Customer_list');
        case 'Material Request':
          await CacheService.invalidate('Stock Entry_pending_transfers');
          await _warmPendingTransfers();
      }
    } catch (_) {
      // Best-effort — worst case the relevant screen just shows what it had
      // cached until its own next live load or pull-to-refresh.
    }
  }

  static Future<void> _warmCustomers() async {
    try {
      final territories = await ErpService.getExpandedUserTerritories();
      await CacheService.getListCached(
        cacheDoctype: 'Customer_list',
        cacheKey: '${territories.join(',')}|',
        fetch: () => ErpService.getList(
          'Customer',
          filters: [
            if (territories.isNotEmpty) ['territory', 'in', territories],
          ],
          fields: const ['name', 'customer_name', 'territory'],
          limit: 50,
        ),
      );
    } catch (_) {
      // Best-effort — the Customers screen will just fetch live when opened.
    }
  }

  static Future<void> _warmSalesOrders() async {
    try {
      await CacheService.getListCached(
        cacheDoctype: 'Sales Order_list',
        cacheKey: 'recent',
        fetch: () => ErpService.getList(
          'Sales Order',
          fields: const [
            'name',
            'customer_name',
            'customer',
            'grand_total',
            'workflow_state',
            'status',
            'docstatus',
            'modified',
          ],
          orderBy: 'modified desc',
          limit: 100,
        ),
      );
    } catch (_) {}
  }

  static Future<void> _warmSalesInvoices() async {
    try {
      await CacheService.getListCached(
        cacheDoctype: 'Sales Invoice_list',
        cacheKey: 'recent',
        fetch: () => ErpService.getList(
          'Sales Invoice',
          fields: const [
            'name',
            'customer_name',
            'customer',
            'grand_total',
            'outstanding_amount',
            'workflow_state',
            'status',
            'docstatus',
            'modified',
          ],
          orderBy: 'modified desc',
          limit: 100,
        ),
      );
    } catch (_) {}
  }

  static Future<void> _warmPendingTransfers() async {
    try {
      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson == null) return;
      await CacheService.getListCached(
        cacheDoctype: 'Stock Entry_pending_transfers',
        cacheKey: salesPerson,
        fetch: () => ErpService.getList(
          'Stock Entry',
          filters: [
            ['custom_sales_rep', '=', salesPerson],
            ['custom_is_received', '=', 0],
            ['docstatus', '=', 1],
          ],
          fields: const ['name', 'posting_date'],
          limit: 50,
        ),
      );
    } catch (_) {}
  }
}
