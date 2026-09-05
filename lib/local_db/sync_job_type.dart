/// Every kind of offline-queueable action, one per ALLOW-listed screen/path
/// from the offline plan. Stored on `SyncJobs.jobType` as `.name` (a plain
/// string) so the replay engine can switch on it without a drift enum
/// migration whenever a new type is added.
///
/// Deliberately excludes Sales Invoice, Payment Entry, and the "استلام
/// النقل" stock-transfer-receipt flow — those stay online-only (live
/// credit-limit check / immediate stock-ledger movement, see the plan).
enum SyncJobType {
  salesOrderCreate,
  customerVisitCreate,
  materialRequestCreate,

  /// Reserved, NOT currently wired to `SyncEngine` or enqueued anywhere —
  /// unlike the other single-step types, `_submitReceipt()`'s "استلام"
  /// leg needs a live `makeInTransitStockEntry` RPC just to know what to
  /// submit at all (the server computes the draft shape), so there's
  /// nothing to build offline in the first place. It stays online-only in
  /// practice even though it only ever creates a Stock Entry Draft.
  materialRequestReceiptCreate,
  expenseClaimPersonalCreate,
  expenseClaimVehicleLogChain,
  customerRegistrationCreate,
  photoAttach,
}

enum SyncJobStatus { pending, inProgress, success, failed, needsReview }
