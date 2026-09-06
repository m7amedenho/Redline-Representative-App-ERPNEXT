import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../local_db/app_database.dart';
import '../local_db/sync_job_type.dart';
import 'auth_service.dart';
import 'erp_service.dart';
import 'sync_status_service.dart';

class _ReplayResult {
  const _ReplayResult(this.doctype, this.name);
  final String doctype;
  final String name;
}

/// Drains the `sync_jobs` queue — one job at a time, in `id` order — by
/// replaying it through the exact same `ErpService` calls the live screen
/// would have made. Only listens to [SyncStatusService] (one-directional
/// dependency, see that class's docs) to know when to start draining.
///
/// Each replay function below intentionally duplicates a screen's own
/// private orchestration (e.g. `_ExpensesScreenState._attachPaymentAndDimension`)
/// rather than calling it directly — those are State-private methods with
/// no shared home, and the underlying `ErpService` methods they call are
/// already public. If that server-side business logic changes, both the
/// live path and this file need updating together.
class SyncEngine {
  SyncEngine._(this._db) {
    // Only reacts to a genuine offline→online transition with something
    // actually queued — `SyncStatusService` notifies on every change
    // (pending count, `isChecking`, ...), and `drainQueue` itself calls
    // `checkNow` (which notifies again), so reacting to every notification
    // unconditionally would ping the server in a tight loop.
    _statusListener = () {
      final status = SyncStatusService();
      final becameOnline = status.isOnline && !_wasOnline;
      _wasOnline = status.isOnline;
      if (becameOnline && status.pendingCount > 0) {
        unawaited(drainQueue());
      }
    };
    SyncStatusService().addListener(_statusListener);
    // Jobs left over from a previous app session need a drain attempt on
    // THIS launch too, not just on a future offline→online transition —
    // `drainQueue` re-checks reachability and re-queries the table
    // directly, so this is safe even if we're actually offline right now.
    unawaited(drainQueue());
  }

  static SyncEngine? _instance;

  factory SyncEngine() => _instance ??= SyncEngine._(AppDatabase.instance);

  final AppDatabase _db;
  late final VoidCallback _statusListener;
  bool _draining = false;
  bool _wasOnline = false;

  /// Saves a new offline action and immediately tries to drain the queue
  /// (a no-op if we're not actually online — [drainQueue] checks first).
  /// [localPhotoPath] is only meaningful for [SyncJobType.photoAttach] —
  /// the durable on-device copy of the picked image (never the picker's
  /// own, possibly OS-clearable, cache path).
  Future<int> enqueue({
    required SyncJobType type,
    required Map<String, dynamic> payload,
    String? localPhotoPath,
  }) async {
    final id = await _db
        .into(_db.syncJobs)
        .insert(
          SyncJobsCompanion.insert(
            jobType: type.name,
            payload: jsonEncode(payload),
            localPhotoPath: Value(localPhotoPath),
          ),
        );
    unawaited(drainQueue());
    return id;
  }

  /// Forces a drain attempt right now — used by the "sync now" button and
  /// after enqueueing. Safe to call anytime: it's a no-op while already
  /// draining, and it verifies real reachability itself rather than
  /// trusting a possibly-stale cached `isOnline` flag.
  Future<void> drainQueue() async {
    if (_draining) return;
    final online = await SyncStatusService().checkNow();
    if (!online) return;

    _draining = true;
    try {
      while (true) {
        final job =
            await (_db.select(_db.syncJobs)
                  ..where((t) => t.status.equals(SyncJobStatus.pending.name))
                  ..orderBy([(t) => OrderingTerm.asc(t.id)])
                  ..limit(1))
                .getSingleOrNull();
        if (job == null) break;

        // Re-verify before EVERY job, not just once at the start — a
        // multi-item queue on a flaky connection can easily lose
        // reachability partway through.
        if (!await SyncStatusService().checkNow()) break;
        await _processJob(job);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _processJob(SyncJob job) async {
    await _setStatus(job.id, SyncJobStatus.inProgress);
    try {
      final payload = jsonDecode(job.payload) as Map<String, dynamic>;
      final result = await _replay(job, payload);
      await (_db.update(
        _db.syncJobs,
      )..where((t) => t.id.equals(job.id))).write(
        SyncJobsCompanion(
          status: Value(SyncJobStatus.success.name),
          resultDoctype: Value(result.doctype),
          resultName: Value(result.name),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (e) {
      final message = e is ErpException
          ? e.message
          : 'حدث خطأ غير متوقع أثناء إعادة الإرسال';
      await (_db.update(
        _db.syncJobs,
      )..where((t) => t.id.equals(job.id))).write(
        SyncJobsCompanion(
          status: Value(SyncJobStatus.failed.name),
          lastError: Value(message),
          retryCount: Value(job.retryCount + 1),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  Future<void> _setStatus(int jobId, SyncJobStatus status) {
    return (_db.update(
      _db.syncJobs,
    )..where((t) => t.id.equals(jobId))).write(
      SyncJobsCompanion(status: Value(status.name)),
    );
  }

  /// Persists partial progress mid-replay (currently only the vehicle-log
  /// chain uses this) so a retry after a later step fails doesn't repeat
  /// an earlier step that already succeeded server-side.
  Future<void> _checkpoint(int jobId, Map<String, dynamic> steps) {
    return (_db.update(
      _db.syncJobs,
    )..where((t) => t.id.equals(jobId))).write(
      SyncJobsCompanion(steps: Value(jsonEncode(steps))),
    );
  }

  Future<_ReplayResult> _replay(
    SyncJob job,
    Map<String, dynamic> payload,
  ) async {
    switch (job.jobType) {
      case 'salesOrderCreate':
        return _replaySalesOrderCreate(payload);
      case 'salesInvoiceCreate':
        return _replaySalesInvoiceCreate(payload);
      case 'paymentEntryCreate':
        return _replayPaymentEntryCreate(payload);
      case 'customerVisitCreate':
        return _replayCustomerVisitCreate(payload);
      case 'materialRequestCreate':
        return _replayMaterialRequestCreate(payload);
      case 'customerRegistrationCreate':
        return _replayCustomerRegistrationCreate(payload);
      case 'expenseClaimPersonalCreate':
        return _replayExpenseClaimPersonalCreate(payload);
      case 'expenseClaimVehicleLogChain':
        return _replayExpenseClaimVehicleLogChain(job, payload);
      case 'photoAttach':
        return _replayPhotoAttach(job, payload);
      case 'genericApiCall':
        return _replayGenericApiCall(payload);
      default:
        throw ErpException('نوع عملية غير معروف: ${job.jobType}');
    }
  }

  Future<_ReplayResult> _replaySalesOrderCreate(
    Map<String, dynamic> payload,
  ) async {
    final fields = Map<String, dynamic>.from(payload);
    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) {
      fields['sales_team'] = [
        {'sales_person': salesPerson, 'allocated_percentage': 100},
      ];
    }
    final created = await ErpService.createDoc('Sales Order', fields);
    return _ReplayResult('Sales Order', created['name'] as String);
  }

  /// Financially sensitive by explicit instruction — queued anyway,
  /// accepting the concurrent-credit-limit risk the plan originally
  /// carved this out to avoid. `update_stock`/`is_return`/etc. are already
  /// baked into `payload` from the live screen; only `sales_team` (needs
  /// `resolveCurrentSalesPerson`) is deferred to here.
  Future<_ReplayResult> _replaySalesInvoiceCreate(
    Map<String, dynamic> payload,
  ) async {
    final fields = Map<String, dynamic>.from(payload);
    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) {
      fields['sales_team'] = [
        {'sales_person': salesPerson, 'allocated_percentage': 100},
      ];
    }
    final created = await ErpService.createDoc('Sales Invoice', fields);
    return _ReplayResult('Sales Invoice', created['name'] as String);
  }

  /// Financially sensitive by explicit instruction, same as the invoice
  /// path — the concurrent-credit-limit conflict risk this reintroduces is
  /// accepted, not overlooked. Unlike the other create flows, nothing here
  /// needs live resolution at replay time: the payload is `_draftDoc`
  /// (already fetched live when the rep picked the customer) plus purely
  /// local selections, so this is a direct, single `createDoc` call.
  Future<_ReplayResult> _replayPaymentEntryCreate(
    Map<String, dynamic> payload,
  ) async {
    final created = await ErpService.createDoc('Payment Entry', payload);
    return _ReplayResult('Payment Entry', created['name'] as String);
  }

  Future<_ReplayResult> _replayCustomerVisitCreate(
    Map<String, dynamic> payload,
  ) async {
    final body = Map<String, dynamic>.from(payload);
    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) body['sales_person'] = salesPerson;
    final created = await ErpService.createDoc('Customer Visit', body);
    return _ReplayResult('Customer Visit', created['name'] as String);
  }

  Future<_ReplayResult> _replayMaterialRequestCreate(
    Map<String, dynamic> payload,
  ) async {
    final created = await ErpService.createDoc('Material Request', payload);
    return _ReplayResult('Material Request', created['name'] as String);
  }

  /// Uploads the durable local copy, then deletes it — only after a
  /// confirmed-success response, matching "auto-uploaded, then
  /// auto-deleted from the phone" exactly. A missing/already-deleted file
  /// (e.g. a duplicate drain attempt) is treated as already done rather
  /// than an error.
  Future<_ReplayResult> _replayPhotoAttach(
    SyncJob job,
    Map<String, dynamic> payload,
  ) async {
    final localPath = job.localPhotoPath;
    final doctype = payload['doctype'] as String;
    final docname = payload['docname'] as String;
    if (localPath == null || !await File(localPath).exists()) {
      return _ReplayResult(doctype, docname);
    }
    await ErpService.uploadFile(
      filePath: localPath,
      doctype: doctype,
      docname: docname,
    );
    try {
      await File(localPath).delete();
    } catch (_) {
      // Best-effort — a leftover file just wastes a little space, it
      // doesn't cause a re-upload (the job is already marked success).
    }
    return _ReplayResult(doctype, docname);
  }

  /// Covers every write that doesn't need a live-resolution step first —
  /// comments, plain document edits, and workflow transitions. Unlike the
  /// dedicated create flows above, the payload here already contains
  /// exactly what would have been sent live, captured at the moment the
  /// rep tapped the action.
  ///
  /// `applyWorkflow`'s `doc` snapshot is whatever the document looked like
  /// AT THAT MOMENT — if it changed through some other path before this
  /// replays, the transition still runs against the current server-side
  /// document (Frappe resolves the actual record by name), but the
  /// snapshot itself won't reflect any such change. No different from
  /// what a live retry days later would face.
  Future<_ReplayResult> _replayGenericApiCall(
    Map<String, dynamic> payload,
  ) async {
    final operation = payload['operation'] as String;
    switch (operation) {
      case 'create':
        final doctype = payload['doctype'] as String;
        final data = Map<String, dynamic>.from(payload['data'] as Map);
        await _resolveProposedCreditLimit(data);
        final created = await ErpService.createDoc(doctype, data);
        return _ReplayResult(doctype, created['name'] as String);
      case 'update':
        final doctype = payload['doctype'] as String;
        final name = payload['name'] as String;
        final data = Map<String, dynamic>.from(payload['data'] as Map);
        await _resolveProposedCreditLimit(data);
        await ErpService.updateDoc(doctype, name, data);
        return _ReplayResult(doctype, name);
      case 'submit':
        final doctype = payload['doctype'] as String;
        final name = payload['name'] as String;
        await ErpService.submitDoc(doctype, name);
        return _ReplayResult(doctype, name);
      case 'applyWorkflow':
        final doctype = payload['doctype'] as String;
        final name = payload['name'] as String;
        final action = payload['action'] as String;
        final docJson = payload['doc'] as String;
        await ErpService.callMethodPost(
          '/api/method/frappe.model.workflow.apply_workflow',
          params: {'doc': docJson, 'action': action},
        );
        return _ReplayResult(doctype, name);
      default:
        throw ErpException('عملية غير معروفة: $operation');
    }
  }

  /// Both Customer creation AND edits can carry a `_proposedCreditLimit`
  /// marker (set by the screen instead of the real `credit_limits` field
  /// when queued offline, since resolving the company needs a live call) —
  /// shared so the generic `create`/`update` replay path handles a queued
  /// customer edit's credit limit exactly the same way as a queued
  /// creation's.
  Future<void> _resolveProposedCreditLimit(Map<String, dynamic> body) async {
    final proposedLimit = body.remove('_proposedCreditLimit') as num?;
    if (proposedLimit == null || proposedLimit <= 0) return;
    final company = await ErpService.resolveDefaultCompany();
    if (company != null) {
      body['credit_limits'] = [
        {'company': company, 'credit_limit': proposedLimit},
      ];
    }
  }

  Future<_ReplayResult> _replayCustomerRegistrationCreate(
    Map<String, dynamic> payload,
  ) async {
    final body = Map<String, dynamic>.from(payload);
    await _resolveProposedCreditLimit(body);

    final currentUserId = await AuthService.currentUserId();
    if (currentUserId != null) body['account_manager'] = currentUserId;

    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) {
      body['sales_team'] = [
        {'sales_person': salesPerson, 'allocated_percentage': 100},
      ];
    }

    final created = await ErpService.createDoc('Customer', body);
    return _ReplayResult('Customer', created['name'] as String);
  }

  /// Mirrors `_ExpensesScreenState._attachPaymentAndDimension` exactly —
  /// see that method's doc comment in `expenses_screen.dart` for why each
  /// of these fields is mandatory.
  Future<void> _attachPaymentAndDimension(
    Map<String, dynamic> body, {
    required String employee,
    String? modeOfPayment,
    String? account,
  }) async {
    body['currency'] = 'EGP';
    body['exchange_rate'] = 1;
    body['approval_status'] = 'Approved';
    body['is_paid'] = 1;
    if (modeOfPayment != null) body['mode_of_payment'] = modeOfPayment;
    if (account != null) body['bank_or_cash_account'] = account;

    final salesPerson = await ErpService.resolveCurrentSalesPerson();
    if (salesPerson != null) body['المندوب'] = salesPerson;

    final approver = await ErpService.resolveExpenseApprover(employee);
    if (approver != null) body['expense_approver'] = approver;

    final defaults = await ErpService.resolveExpenseAccountingDefaults(
      employee,
    );
    if (defaults.payableAccount != null) {
      body['payable_account'] = defaults.payableAccount;
    }
    final expenses = body['expenses'];
    if (expenses is List) {
      for (final row in expenses) {
        if (row is! Map) continue;
        row['sanctioned_amount'] = row['amount'];
        if (defaults.costCenter != null && row['cost_center'] == null) {
          row['cost_center'] = defaults.costCenter;
        }
      }
    }
    if (defaults.costCenter != null) body['cost_center'] = defaults.costCenter;
  }

  /// Mirrors the live screens' own `_postNoteIfAny` — best-effort, never
  /// lets a failed comment post fail the whole job (the document it would
  /// attach to has already been created/submitted by this point).
  Future<void> _postNoteIfAny(String doctype, String name, Object? note) async {
    if (note is! String || note.trim().isEmpty) return;
    try {
      await ErpService.createDoc('Comment', {
        'comment_type': 'Comment',
        'reference_doctype': doctype,
        'reference_name': name,
        'content': note.trim(),
      });
    } catch (_) {
      // Best-effort, same as the live path.
    }
  }

  Future<_ReplayResult> _replayExpenseClaimPersonalCreate(
    Map<String, dynamic> payload,
  ) async {
    final employee = await ErpService.resolveCurrentEmployee();
    if (employee == null) {
      throw const ErpException(
        'تعذر تحديد بيانات الموظف المرتبطة بحسابك — راجع الإدارة',
      );
    }
    final body = <String, dynamic>{
      'employee': employee,
      'posting_date': payload['expenseDate'],
      'expenses': [
        {
          'expense_type': payload['expenseType'],
          'amount': payload['amount'],
          'expense_date': payload['expenseDate'],
        },
      ],
    };
    await _attachPaymentAndDimension(
      body,
      employee: employee,
      modeOfPayment: payload['modeOfPayment'] as String?,
      account: payload['account'] as String?,
    );

    final created = await ErpService.createDoc('Expense Claim', body);
    final createdName = created['name'] as String;
    await _postNoteIfAny('Expense Claim', createdName, payload['note']);
    await ErpService.submitDoc('Expense Claim', createdName);
    return _ReplayResult('Expense Claim', createdName);
  }

  /// The one chained job type — Vehicle Log must exist (and get submitted)
  /// on the server BEFORE `makeExpenseClaimFromVehicleLog` can even be
  /// called, since that RPC reads the just-created log by name. Checkpoints
  /// the Vehicle Log's server-assigned name into `job.steps` right after it
  /// succeeds, so a retry after a LATER step fails (e.g. the expense claim
  /// creation) reuses that same log instead of creating a duplicate one.
  Future<_ReplayResult> _replayExpenseClaimVehicleLogChain(
    SyncJob job,
    Map<String, dynamic> payload,
  ) async {
    final employee = await ErpService.resolveCurrentEmployee();
    if (employee == null) {
      throw const ErpException(
        'تعذر تحديد بيانات الموظف المرتبطة بحسابك — راجع الإدارة',
      );
    }

    String? logName;
    final existingSteps = job.steps;
    if (existingSteps != null) {
      final decoded = jsonDecode(existingSteps) as Map<String, dynamic>;
      logName = decoded['vehicleLogName'] as String?;
    }

    if (logName == null) {
      final body = <String, dynamic>{
        'license_plate': payload['licensePlate'],
        'employee': employee,
        'date': payload['date'],
        'odometer': payload['odometer'],
        'last_odometer': payload['lastOdometer'],
        'type': payload['type'],
        if (payload['fuelQty'] != null) 'fuel_qty': payload['fuelQty'],
        if (payload['price'] != null) 'price': payload['price'],
        if (payload['serviceDetail'] != null)
          'service_detail': payload['serviceDetail'],
      };
      final createdLog = await ErpService.createDoc('Vehicle Log', body);
      logName = createdLog['name'] as String;
      await _checkpoint(job.id, {'vehicleLogName': logName});
      await _postNoteIfAny('Vehicle Log', logName, payload['note']);

      try {
        await ErpService.submitDoc('Vehicle Log', logName);
      } catch (_) {
        // Same tolerance as the live path — the log itself is saved, a
        // failed auto-submit doesn't lose anything.
      }
    }

    final draft = await ErpService.makeExpenseClaimFromVehicleLog(logName);
    final claimBody = Map<String, dynamic>.from(draft)..remove('name');
    claimBody['expenses'] = [
      {
        'expense_type': payload['expenseType'],
        'amount': payload['amount'],
        'expense_date': payload['expenseDate'],
      },
    ];
    await _attachPaymentAndDimension(
      claimBody,
      employee: employee,
      modeOfPayment: payload['modeOfPayment'] as String?,
      account: payload['account'] as String?,
    );

    final createdClaim = await ErpService.createDoc(
      'Expense Claim',
      claimBody,
    );
    final claimName = createdClaim['name'] as String;
    await ErpService.submitDoc('Expense Claim', claimName);
    return _ReplayResult('Expense Claim', claimName);
  }
}
