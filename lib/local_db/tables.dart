import 'package:drift/drift.dart';

/// One queued offline action, replayed in `id` order once connectivity
/// returns. `jobType` picks which screen's replay logic handles it (see
/// `SyncJobType` in `sync_job_type.dart`) — kept as a plain string column
/// (not a drift enum) so adding a new job type never needs a schema
/// migration, only a new case in the replay switch.
///
/// `payload`/`steps` are stored as raw JSON text rather than structured
/// columns: the shape of what a screen sends to `ErpService.createDoc` can
/// change over time, and a queued job captured from an older app version
/// must still replay correctly without a matching migration for every
/// field that ever changes.
class SyncJobs extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// e.g. `sales_order_create`, `expense_claim_vehicle_log_chain` — see
  /// `SyncJobType`.
  TextColumn get jobType => text()();

  /// `pending` / `in_progress` / `success` / `failed` / `needs_review`.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// The exact request body the screen would have sent live, as JSON.
  TextColumn get payload => text()();

  /// Null for single-step jobs. For a chained job (the vehicle-log →
  /// expense-claim sequence) a JSON array of step records, each gaining a
  /// `resolvedName` once that step succeeds server-side — so a resumed
  /// replay never re-issues a step that already went through.
  TextColumn get steps => text().nullable()();

  IntColumn get currentStepIndex => integer().withDefault(const Constant(0))();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  /// Human-readable (Arabic) — reuses `ErpException.message` where
  /// possible so this reads the same as a live-failure message would.
  TextColumn get lastError => text().nullable()();

  /// Populated once the job's primary document exists server-side, so a
  /// completed row can deep-link via `documentDetailRoute`.
  TextColumn get resultDoctype => text().nullable()();
  TextColumn get resultName => text().nullable()();

  /// For a `photo_attach` job queued against a document that was ITSELF
  /// created offline and hasn't synced yet — the photo job can't run
  /// until the parent job has a `resultName`.
  IntColumn get dependsOnJobId => integer().nullable()();

  /// `photo_attach` jobs only — the durable on-device copy (never the
  /// original picker cache path, which the OS can clear at any time).
  TextColumn get localPhotoPath => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Generic read-through cache for reference/lookup data viewed offline
/// (customer info, account-statement lines, outstanding invoices, prices).
/// Keyed by `(doctype, name)` rather than one table per doctype — the set
/// of screens that want offline viewing will grow, and a single generic
/// table means adding one doesn't need a new migration each time.
class ReferenceCache extends Table {
  TextColumn get doctype => text()();
  TextColumn get name => text()();

  /// The cached document/row, as JSON — same shape `ErpService.getDoc`/
  /// `getList` already return, so a cache-read can be swapped in wherever
  /// a live call currently sits with no reshaping.
  TextColumn get dataJson => text()();

  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {doctype, name};
}
