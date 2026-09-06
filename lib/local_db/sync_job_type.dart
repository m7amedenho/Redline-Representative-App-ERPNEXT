/// Every kind of offline-queueable action, one per ALLOW-listed screen/path
/// from the offline plan. Stored on `SyncJobs.jobType` as `.name` (a plain
/// string) so the replay engine can switch on it without a drift enum
/// migration whenever a new type is added.
///
/// By explicit instruction, financially sensitive flows (Sales Invoice,
/// Payment Entry, stock transfers) are queued too, accepting the
/// concurrent-conflict risk this carries — the approval workflow each of
/// these still goes through on reconnect is the accepted mitigation.
enum SyncJobType {
  salesOrderCreate,
  salesInvoiceCreate,
  paymentEntryCreate,
  customerVisitCreate,
  materialRequestCreate,

  /// Reserved, NOT currently wired to `SyncEngine` or enqueued anywhere —
  /// unlike every other type here, `_submitReceipt()`'s "استلام" leg needs
  /// a live `makeInTransitStockEntry` RPC just to know what to submit at
  /// all (the server computes the draft shape) — there is nothing to build
  /// offline in the first place, a structural limit, not a risk decision.
  materialRequestReceiptCreate,
  materialRequestTransferReceiveCreate,
  expenseClaimPersonalCreate,
  expenseClaimVehicleLogChain,
  customerRegistrationCreate,
  photoAttach,

  /// Everything else that doesn't need a live-resolution step before it can
  /// be built — comments, workflow transitions (`apply_workflow`), and
  /// plain document edits. The payload carries the ready-to-send request
  /// (see `SyncEngine._replayGenericApiCall`), so this one job type covers
  /// an open-ended, growing set of screens without a new enum case each
  /// time. Anything that DOES need a live resolve-then-build step (sales
  /// person, employee, accounting defaults, ...) still needs its own
  /// dedicated type above — see those replay functions' doc comments.
  genericApiCall,
}

enum SyncJobStatus { pending, inProgress, success, failed, needsReview }
