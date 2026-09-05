import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// The app's one local database — the offline `SyncJobs` queue and the
/// `ReferenceCache` read-through cache both live here rather than in
/// separate storage mechanisms, so a screen can join "is there a pending
/// job for this customer" against "what's the last cached balance" in one
/// query instead of reconciling two data sources by hand.
@DriftDatabase(tables: [SyncJobs, ReferenceCache])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Test-only constructor — an in-memory database so widget/unit tests
  /// never touch the real on-device file.
  AppDatabase.forTesting(super.executor);

  /// The app has exactly one on-device database — every service
  /// (`SyncEngine`, `SyncStatusService`, the sync-queue screen) shares this
  /// single connection rather than each opening its own, matching the
  /// static-singleton style already used by `ErpService`/`AuthService`.
  static final AppDatabase instance = AppDatabase();

  @override
  int get schemaVersion => 1;
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'red_erp_local.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
