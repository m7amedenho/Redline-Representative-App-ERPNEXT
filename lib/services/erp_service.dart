import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Same rationale as `AuthService._hardNetworkTimeout` — a Dart-level
/// backstop in case the underlying socket hangs longer than Dio's own
/// connect/receive timeouts actually enforce on some Android networks.
const _hardNetworkTimeout = Duration(seconds: 25);

/// Friendly, Arabic-only error meant to be shown directly to the user.
class ErpException implements Exception {
  const ErpException(
    this.message, {
    this.serverRejected = false,
    this.sessionExpired = false,
  });

  final String message;
  final bool serverRejected;

  /// True when the access token was rejected AND the silent refresh also
  /// failed — the caller should redirect to `/auth` instead of just
  /// showing an error banner.
  final bool sessionExpired;

  @override
  String toString() => message;

  /// True for a network/timeout failure (no response ever came back) —
  /// the case an offline-capable screen should queue instead of showing a
  /// raw error. False for a genuine server rejection (`serverRejected`):
  /// the server DID respond, so retrying identically offline-and-later
  /// would just fail the same way — that has to surface to the rep now.
  bool get isConnectivityFailure => !serverRejected;
}

/// Generic REST (`/api/resource/<DocType>`) + RPC (`/api/method/...`) client
/// for the ERPNext/Frappe backend, plus typed wrappers for the specific
/// confirmed endpoints used by the sales-rep screens.
///
/// `/api/resource/<DocType>` itself is standard, stable Frappe framework
/// behavior (not guessed) — but individual DocTypes' field names are NOT in
/// either OpenAPI spec (those specs only cover `/api/method/...`), so the
/// field names used when building request bodies for Sales Order/Sales
/// Invoice/Material Request/Expense Claim/Vehicle Log are the standard
/// ERPNext field names, not verified against this specific site. See
/// docs/API_INTEGRATION_NOTES.md.
class ErpService {
  ErpService._();

  static Dio? _dio;

  @visibleForTesting
  static void debugOverrideDio(Dio dio) => _dio = dio;

  static Future<Response> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    dynamic data,
    Map<String, dynamic>? formParams,
    bool isRetry = false,
  }) async {
    final domain = await AuthService.currentDomain();
    final token = await AuthService.currentAccessToken();

    if (domain == null || token == null) {
      throw const ErpException(
        'لا توجد جلسة محفوظة.',
        serverRejected: true,
        sessionExpired: true,
      );
    }

    final dio = _dio ??= Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: const {'Accept': 'application/json'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    dio.options.baseUrl = domain;

    // Handle both possible shapes Dio can hand back a 4xx in: a normal
    // Response (when `validateStatus` allows it through, as configured
    // above) or a DioException that still carries `.response` (Dio's
    // default behavior). Either way we want the same retry-then-map logic,
    // so this isn't sensitive to exactly how the Dio instance was built.
    Response response;
    try {
      response = await dio
          .request(
            path,
            queryParameters: query,
            data: formParams ?? data,
            options: Options(
              method: method,
              headers: {'Authorization': 'Bearer $token'},
              contentType: formParams != null
                  ? Headers.formUrlEncodedContentType
                  : null,
            ),
          )
          .timeout(_hardNetworkTimeout);
    } on DioException catch (e) {
      if (e.response == null) {
        throw _mapDioException(e);
      }
      response = e.response!;
    } on TimeoutException {
      throw const ErpException(
        'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
      );
    }

    if (response.statusCode == 401 && !isRetry) {
      try {
        await AuthService.refreshSession();
      } on AuthException {
        throw const ErpException(
          'انتهت صلاحية الجلسة، برجاء تسجيل الدخول مرة أخرى.',
          serverRejected: true,
          sessionExpired: true,
        );
      }
      return _send(
        method,
        path,
        query: query,
        data: data,
        formParams: formParams,
        isRetry: true,
      );
    }

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw _mapErrorResponse(response);
    }

    return response;
  }

  // ---- Generic REST -------------------------------------------------

  static Future<Map<String, dynamic>> createDoc(
    String doctype,
    Map<String, dynamic> data,
  ) async {
    final response = await _send('POST', '/api/resource/$doctype', data: data);
    return _unwrapDoc(response.data);
  }

  static Future<Map<String, dynamic>> updateDoc(
    String doctype,
    String name,
    Map<String, dynamic> data,
  ) async {
    final response = await _send(
      'PUT',
      '/api/resource/$doctype/${Uri.encodeComponent(name)}',
      data: data,
    );
    return _unwrapDoc(response.data);
  }

  /// Submits an already-saved document (docstatus 0 → 1) via the plain
  /// resource PUT endpoint — the standard REST mechanism, same one
  /// [updateDoc] already uses for everything else. Only meant for
  /// doctypes this app deliberately submits with NO workflow gate
  /// (Expense Claim, Vehicle Log business rule — explicit product
  /// decision, not a shortcut) since a workflow-governed doctype must go
  /// through `apply_workflow` instead to respect its states.
  static Future<Map<String, dynamic>> submitDoc(String doctype, String name) {
    return updateDoc(doctype, name, {'docstatus': 1});
  }

  /// Real server reachability, not just "the phone has a network
  /// interface" — a `connectivity_plus` signal alone is a common false
  /// positive on Egyptian mobile networks (captive portals, dead-SIM data)
  /// and tells you nothing about whether THIS specific ERPNext domain is
  /// actually reachable. `frappe.ping` is Frappe's own built-in
  /// unauthenticated health-check method, so this is cheap: no doctype
  /// permission, no meaningful payload. Never throws — any failure (no
  /// session, timeout, DNS, 5xx) just means "not reachable right now".
  static Future<bool> ping() async {
    try {
      final response = await _send('GET', '/api/method/ping');
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// `hrms.hr.doctype.vehicle_log.vehicle_log.make_expense_claim` —
  /// confirmed real whitelisted method (see the app's own source): computes
  /// `fuel_qty × price + sum(service_detail.expense_amount)`, returns an
  /// unsaved `Expense Claim` dict with `employee`/`vehicle_log` already set
  /// and ONE combined expense row, and throws if a claim already exists
  /// for this Vehicle Log (duplicate-claim guard) or if the computed total
  /// is zero. Callers should replace the single generic row with properly
  /// categorized ones before inserting — this method only hands back the
  /// safe linkage + computed total, not the final row shape.
  static Future<Map<String, dynamic>> makeExpenseClaimFromVehicleLog(
    String vehicleLogName,
  ) {
    return callMethod(
      '/api/method/hrms.hr.doctype.vehicle_log.vehicle_log.make_expense_claim',
      params: {'docname': vehicleLogName},
    );
  }

  static Future<Map<String, dynamic>> getDoc(
    String doctype,
    String name,
  ) async {
    final response = await _send(
      'GET',
      '/api/resource/$doctype/${Uri.encodeComponent(name)}',
    );
    return _unwrapDoc(response.data);
  }

  /// The full `Workflow` definition for a DocType — the actual ordered list
  /// of states this site configured (`states` child table, DocType
  /// "Workflow Document State", field `state`), used to draw a real
  /// progress stepper instead of showing only the current state in
  /// isolation. `Workflow`/`Workflow Document State`/`Workflow Transition`
  /// are standard Frappe framework DocTypes (not custom to this site), so
  /// their field names are framework knowledge, not a guess — but this
  /// site's specific workflow name/state list/order is read live, nothing
  /// hardcoded. Returns null if this DocType has no active workflow.
  static Future<Map<String, dynamic>?> getWorkflowDefinition(
    String doctype,
  ) async {
    try {
      final matches = await getList(
        'Workflow',
        filters: [
          ['document_type', '=', doctype],
          ['is_active', '=', 1],
        ],
        fields: const ['name'],
        limit: 1,
      );
      if (matches.isEmpty) return null;
      final workflowName = matches.first['name'] as String?;
      if (workflowName == null) return null;
      final doc = await getDoc('Workflow', workflowName);
      return doc.isEmpty ? null : doc;
    } catch (_) {
      return null;
    }
  }

  /// The state immediately before the document's current `workflow_state`,
  /// plus who actually made that change — both read from the document's
  /// real `Version` audit trail (standard Frappe framework DocType, same
  /// mechanism that previously confirmed a real docstatus/workflow_state
  /// jump on `SAL-ORD-2026-00009`). Used to correct the approval-progress
  /// stepper when the current state was reached by a branch (e.g. a
  /// manager's "طلب تعديل" sending the document back to a shared revision
  /// state from one of several possible steps) rather than the next state
  /// in the states list, and to show who actually took that action — never
  /// hardcoded, always this specific document's own history. Returns null
  /// on any failure or if no state-changing Version exists yet — callers
  /// must treat null as "assume a normal adjacent transition", never as an
  /// error.
  static Future<({String fromState, String? actor})?>
  getLastWorkflowTransition(String doctype, String name) async {
    try {
      final versions = await getList(
        'Version',
        filters: [
          ['ref_doctype', '=', doctype],
          ['docname', '=', name],
        ],
        fields: const ['data', 'owner'],
        orderBy: 'creation desc',
        limit: 20,
      );
      for (final version in versions) {
        final raw = version['data'];
        if (raw is! String) continue;
        final parsed = jsonDecode(raw);
        final changed = parsed is Map ? parsed['changed'] : null;
        if (changed is! List) continue;
        for (final entry in changed) {
          if (entry is List &&
              entry.length >= 2 &&
              entry[0] == 'workflow_state') {
            final fromState = entry[1]?.toString();
            if (fromState == null) return null;
            return (fromState: fromState, actor: version['owner'] as String?);
          }
        }
      }
    } catch (_) {
      // Fails open to null — the stepper just falls back to treating the
      // transition as a normal adjacent one.
    }
    return null;
  }

  /// Best-effort: this app has no notion of "the current company" (multi-
  /// company ERPNext sites need one explicitly), so it falls back to
  /// whichever `Company` record comes back first — correct for the common
  /// single-company setup, not guaranteed on a multi-company site.
  static Future<String?> resolveDefaultCompany() async {
    try {
      final companies = await getList(
        'Company',
        fields: const ['name'],
        limit: 1,
      );
      if (companies.isEmpty) return null;
      return companies.first['name'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort: right after creating a document, try to move it past
  /// Draft immediately — matching this app's "swipe = send" UX (the swipe
  /// button already says "send", not "save") instead of silently leaving
  /// every create stuck as a draft that needs a separate manual step.
  ///
  /// Uses whatever workflow is configured on this DocType (confirmed
  /// generic endpoints `frappe.model.workflow.get_transitions`/
  /// `apply_workflow`). If there's more than one available next action,
  /// this does NOT guess which one means "send" — it leaves the document
  /// as-is so the user picks on [DocumentDetailScreen] instead of the app
  /// silently taking the wrong branch on a multi-step approval workflow.
  /// Only falls back to a plain `docstatus` submit when there is truly no
  /// workflow at all (`get_transitions` returned nothing) and the document
  /// is still a draft.
  ///
  /// Never throws — the create itself already succeeded, so a failure here
  /// always still returns the (unchanged) `doc`. But it DOES report the
  /// real failure via `error` instead of swallowing it: a caller that only
  /// looked at "did workflow_state change" and showed a generic "تعذر
  /// إرسال المستند" on failure was hiding genuinely useful causes (e.g. a
  /// real insufficient-stock error from a `update_stock` invoice) behind
  /// that one meaningless message — confirmed from a real report where
  /// that's exactly what happened.
  static Future<({Map<String, dynamic> doc, Object? error})> tryAutoProgress(
    String doctype,
    Map<String, dynamic> doc,
  ) async {
    // `get_transitions` itself can throw outright for a DocType with no
    // workflow configured at all — it's not guaranteed to just return an
    // empty list. Treating that failure as "no workflow" (same as an empty
    // list) rather than "give up entirely" is what makes the plain-submit
    // fallback below actually run for non-workflow DocTypes — previously a
    // thrown exception here skipped the fallback too and left the document
    // stuck in Draft, which is the exact bug being fixed.
    List<String> actions = const [];
    try {
      final transitions = await callMethodListPost(
        '/api/method/frappe.model.workflow.get_transitions',
        params: {'doc': jsonEncode(doc)},
      );
      actions = transitions
          .whereType<Map>()
          .map((t) => t['action']?.toString())
          .whereType<String>()
          .toList();
    } catch (_) {
      actions = const [];
    }

    try {
      if (actions.length == 1) {
        final updated = await callMethodPost(
          '/api/method/frappe.model.workflow.apply_workflow',
          params: {'doc': jsonEncode(doc), 'action': actions.first},
        );
        if (updated.isNotEmpty) return (doc: updated, error: null);
      } else if (actions.isEmpty && doc['docstatus'] == 0) {
        // `get_transitions` returning nothing is NOT proof this DocType has
        // no workflow — it also comes back empty on a transient failure
        // (network hiccup, a stale/partial local `doc`, a transition whose
        // `condition` didn't evaluate as expected) even when a real,
        // multi-step approval workflow IS configured. Blindly submitting
        // (`docstatus: 1`) in that case is catastrophic: Frappe's own
        // docstatus↔workflow_state sync then snaps `workflow_state` to
        // whichever state is mapped to docstatus 1 — typically the FINAL
        // approved state — completely skipping every approval step in
        // between. Confirmed on a real document via its Version audit log
        // (a single update changed docstatus 0→1 and workflow_state
        // "مسودة"→"معتمد نهائيا" together, with no intermediate
        // apply_workflow step). So the plain-submit fallback is only safe
        // once a real `Workflow` definition for this DocType is POSITIVELY
        // confirmed NOT to exist — deliberately not reusing
        // [getWorkflowDefinition] here, since that helper fails open (`null`
        // = "no workflow") on any error too, same class of bug as above:
        // a transient failure fetching the Workflow list would otherwise
        // still let this fallback fire. Here, any failure to confirm keeps
        // `confirmedNoWorkflow` false — "unknown" is treated the same as
        // "a workflow exists", never as license to submit.
        var confirmedNoWorkflow = false;
        try {
          final matches = await getList(
            'Workflow',
            filters: [
              ['document_type', '=', doctype],
              ['is_active', '=', 1],
            ],
            fields: const ['name'],
            limit: 1,
          );
          confirmedNoWorkflow = matches.isEmpty;
        } catch (_) {
          confirmedNoWorkflow = false;
        }
        if (confirmedNoWorkflow) {
          final name = doc['name'] as String?;
          if (name != null) {
            final updated = await updateDoc(doctype, name, {'docstatus': 1});
            return (doc: updated, error: null);
          }
        }
      }
    } catch (e) {
      // The create itself already succeeded — the document is never lost —
      // but the real reason THIS step failed (e.g. a workflow permission
      // restriction, or a genuine business-rule rejection like
      // insufficient stock) is reported back instead of discarded.
      return (doc: doc, error: e);
    }
    return (doc: doc, error: null);
  }

  static Future<List<Map<String, dynamic>>> getList(
    String doctype, {
    List<List<dynamic>>? filters,
    List<String>? fields,
    int limit = 50,
    String? orderBy,
  }) async {
    final query = <String, dynamic>{'limit_page_length': limit};
    if (filters != null) query['filters'] = jsonEncode(filters);
    if (fields != null) query['fields'] = jsonEncode(fields);
    if (orderBy != null) query['order_by'] = orderBy;

    final response = await _send('GET', '/api/resource/$doctype', query: query);
    final data = response.data;
    if (data is Map && data['data'] is List) {
      return List<Map<String, dynamic>>.from(
        (data['data'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
    }
    return const [];
  }

  // ---- Generic RPC (/api/method/...) ---------------------------------

  static Future<Map<String, dynamic>> callMethod(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _send('GET', path, query: params);
    return _unwrapDoc(response.data);
  }

  /// Same as [callMethod] but for RPCs whose payload is a bare JSON array
  /// rather than an object (e.g. `get_outstanding_reference_documents`).
  static Future<List<dynamic>> callMethodList(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _send('GET', path, query: params);
    final data = response.data;
    dynamic inner = data;
    if (data is Map) {
      inner = data['message'] ?? data['data'];
    }
    if (inner is List) return inner;
    return const [];
  }

  /// Same as [callMethod], but sends `params` as a POST form body instead of
  /// a GET query string. Required for RPCs whose params can carry a full
  /// document JSON (e.g. `get_transitions`/`apply_workflow` with a real
  /// Sales Order's `doc`) — confirmed live that a real order (items +
  /// payment schedule, several KB once its Arabic text is percent-encoded)
  /// sent via GET gets rejected by the server's front-end proxy with a
  /// bare `414 Request-URI Too Large` before Frappe even sees it, which is
  /// what was silently surfacing as "تعذر إرسال المستند" in the app. A
  /// POST body has no such length limit.
  static Future<Map<String, dynamic>> callMethodPost(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _send('POST', path, formParams: params ?? const {});
    return _unwrapDoc(response.data);
  }

  /// POST counterpart of [callMethodList] — see [callMethodPost].
  static Future<List<dynamic>> callMethodListPost(
    String path, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _send('POST', path, formParams: params ?? const {});
    final data = response.data;
    dynamic inner = data;
    if (data is Map) {
      inner = data['message'] ?? data['data'];
    }
    if (inner is List) return inner;
    return const [];
  }

  /// Fallback price list when a customer has no `default_price_list` of
  /// their own: the site-wide `Selling Settings.selling_price_list` (a
  /// standard singleton DocType). NOT `get_party_details`'s `price_list`
  /// key — that call needs a `company` we don't have in this app, and
  /// silently omits pricing without one. Callers should read
  /// `Customer.default_price_list` first (already fetched alongside
  /// `credit_limit` wherever a customer is picked) and only call this when
  /// that's empty.
  static Future<String?> getSellingSettingsPriceList() async {
    try {
      final settings = await getDoc('Selling Settings', 'Selling Settings');
      final sitePriceList = settings['selling_price_list'] as String?;
      if (sitePriceList != null && sitePriceList.isNotEmpty)
        return sitePriceList;
    } catch (_) {
      // Ignored — pricing just stays unavailable.
    }
    return null;
  }

  /// Territories the current user can see. Tries three independent,
  /// individually fault-tolerant layers — a failure in one (e.g. a role
  /// without read access) falls through to the next rather than aborting
  /// the whole lookup, since a real rep account was confirmed to NOT have
  /// read permission on `User Permission` (layer 1 below), which used to
  /// take down the entire method including the layers that do work for
  /// that account. Never returns an exception's text as if it were a real
  /// territory — any layer that fails just contributes nothing.
  ///
  /// 1. Standard Frappe `User Permission` doctype (`allow: "Territory"`) —
  ///    confirmed live against the real server for an account that CAN
  ///    read it (a rep with a single assigned territory gets back exactly
  ///    one `for_value`).
  /// 2. `Territory.territory_manager` (standard field) or
  ///    `Territory.custom_sales_person` (custom field added this round) —
  ///    either pointing at the current user's own `Sales Person` record.
  /// 3. Last resort: a `Territory` whose name contains the Sales Person's
  ///    name (e.g. "خط رشاد سعيد" for "رشاد سعيد").
  ///
  /// Used only to decide whether a territory-filter picker is worth
  /// showing at all (more than one result) — the server's own permission
  /// engine still does the actual enforcement everywhere else in this app,
  /// this is purely a UI convenience for reps who legitimately see more
  /// than one territory.
  static Future<List<String>> getUserTerritories() async {
    final territories = <String>{};

    try {
      final userId = await AuthService.currentUserId();
      if (userId != null) {
        final rows = await getList(
          'User Permission',
          filters: [
            ['user', '=', userId],
            ['allow', '=', 'Territory'],
          ],
          fields: const ['for_value'],
          limit: 50,
        );
        for (final r in rows) {
          final val = r['for_value']?.toString();
          if (val != null) territories.add(val);
        }
      }
    } catch (_) {
      // This account may simply not have read access to User Permission —
      // fall through to the Territory-based layers below.
    }

    try {
      final salesPerson = await resolveCurrentSalesPerson();
      if (salesPerson != null) {
        final managerRows = await getList(
          'Territory',
          filters: [
            ['territory_manager', '=', salesPerson],
          ],
          fields: const ['name'],
          limit: 50,
        );
        for (final r in managerRows) {
          final val = r['name']?.toString();
          if (val != null) territories.add(val);
        }

        final customRows = await getList(
          'Territory',
          filters: [
            ['custom_sales_person', '=', salesPerson],
          ],
          fields: const ['name'],
          limit: 50,
        );
        for (final r in customRows) {
          final val = r['name']?.toString();
          if (val != null) territories.add(val);
        }

        if (territories.isEmpty) {
          final fallbackRows = await getList(
            'Territory',
            filters: [
              ['name', 'like', '%$salesPerson%'],
            ],
            fields: const ['name'],
            limit: 10,
          );
          for (final r in fallbackRows) {
            final val = r['name']?.toString();
            if (val != null) territories.add(val);
          }
        }
      }
    } catch (_) {
      // Best-effort — whatever layer 1 already found is still returned.
    }

    return territories.toList();
  }

  /// [getUserTerritories] expanded to every DESCENDANT territory (any depth,
  /// via the real NestedSet `lft`/`rgt` bounds) — a rep under a region
  /// manager sits in a sub-territory (e.g. "خط رشاد سعيد" under "وجه بحري"),
  /// not literally the manager's own territory name, so a manager-scoped
  /// query needs every territory below theirs, not just an exact-name match.
  /// For a rep with no sub-territories this is a no-op (their own leaf
  /// territory has no descendants) — safe to use unconditionally everywhere
  /// a customer/document list is scoped by territory, not just in
  /// manager-only screens.
  static Future<List<String>> getExpandedUserTerritories() async {
    final territories = await getUserTerritories();
    if (territories.isEmpty) return territories;

    final allTerritoryNames = Set<String>.from(territories);
    try {
      final territoryRows = await getList(
        'Territory',
        filters: [
          ['name', 'in', territories],
        ],
        fields: const ['name', 'lft', 'rgt'],
        limit: territories.length,
      );
      for (final row in territoryRows) {
        final lft = row['lft'] as num?;
        final rgt = row['rgt'] as num?;
        if (lft == null || rgt == null) continue;
        final descendants = await getList(
          'Territory',
          filters: [
            ['lft', '>', lft],
            ['rgt', '<', rgt],
          ],
          fields: const ['name'],
          limit: 200,
        );
        allTerritoryNames.addAll(
          descendants.map((d) => d['name'] as String?).whereType<String>(),
        );
      }
    } catch (_) {
      // Best-effort — the caller still gets the un-expanded list.
    }
    return allTerritoryNames.toList();
  }

  /// The `Sales Person` record linked to the current user — tries the
  /// reliable `custom_user` field first (Link → User, added this round),
  /// then falls back to matching `sales_person_name` against the user's
  /// own `full_name`/`first_name` for records not backfilled yet. Each
  /// layer is independently fault-tolerant, same rationale as
  /// [getUserTerritories]. Never returns an exception's text as if it were
  /// a real Sales Person name — returns null (never blocks document
  /// creation) on any failure or when nothing matches.
  static Future<String?> resolveCurrentSalesPerson() async {
    try {
      final userId = await AuthService.currentUserId();
      if (userId != null) {
        final rows = await getList(
          'Sales Person',
          filters: [
            ['custom_user', '=', userId],
          ],
          fields: const ['name'],
          limit: 1,
        );
        if (rows.isNotEmpty) return rows.first['name'] as String?;
      }
    } catch (_) {
      // Fall through to the name-matching fallback below.
    }

    try {
      final me = await AuthService.me();
      final fullName = me['full_name']?.toString();
      if (fullName != null && fullName.isNotEmpty) {
        final rows = await getList(
          'Sales Person',
          filters: [
            ['sales_person_name', 'like', '%$fullName%'],
          ],
          fields: const ['name'],
          limit: 1,
        );
        if (rows.isNotEmpty) return rows.first['name'] as String?;
      }

      final firstName = me['first_name']?.toString();
      if (firstName != null && firstName.isNotEmpty) {
        final rows = await getList(
          'Sales Person',
          filters: [
            ['sales_person_name', 'like', '%$firstName%'],
          ],
          fields: const ['name'],
          limit: 1,
        );
        if (rows.isNotEmpty) return rows.first['name'] as String?;
      }
    } catch (_) {
      // Ignored — see doc comment above.
    }

    return null;
  }

  /// The `Employee` record linked to the current user, via the standard
  /// `Employee.user_id` field (confirmed real field, not a custom one) —
  /// needed anywhere a doctype requires `employee` directly (Vehicle Log,
  /// Expense Claim) rather than `Sales Person`. Same fail-safe contract as
  /// [resolveCurrentSalesPerson]: never throws, returns null on any
  /// failure or no match rather than blocking document creation.
  static Future<String?> resolveCurrentEmployee() async {
    try {
      final userId = await AuthService.currentUserId();
      if (userId == null) return null;
      final rows = await getList(
        'Employee',
        filters: [
          ['user_id', '=', userId],
        ],
        fields: const ['name'],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first['name'] as String?;
    } catch (_) {
      // Ignored — caller treats null as "couldn't resolve, don't block".
    }
    return null;
  }

  /// This month's target vs. actual for one `Sales Person` — reusable for
  /// both the rep's own performance card and a region manager's team
  /// dashboard (called once per rep in their team). `targetAmount` is the
  /// rep's ANNUAL target (`Sales Person.targets`, real ERPNext field,
  /// summed across every row for the current Fiscal Year) divided evenly
  /// across 12 months. `Target Detail.distribution_id` (Link →
  /// `Monthly Distribution`, standard ERPNext monthly-percentage template)
  /// is genuinely mandatory server-side, so every target actually saved on
  /// this server necessarily has one attached — an "توزيع متساوٍ" (Equal
  /// Distribution, ~8.33%/month) template was created for exactly this so
  /// managers can save targets at all. An even 12-way split here matches
  /// that template's own math exactly, without an extra round trip to
  /// re-derive it per rep — not a shortcut around a missing feature. Null
  /// `targetAmount` means no target is configured at all for this rep this
  /// year — callers must show that as "no target set", never as a 0/0
  /// (misleadingly implies a target of zero was met). `achievedAmount` is
  /// real submitted Sales Invoice totals this calendar month, attributed
  /// by `owner` (there's no Permission Query Script on Sales Invoice to
  /// lean on — see docs — so this filters explicitly rather than trusting
  /// an unfiltered list). Returns null only on total failure to even load
  /// the Sales Person doc.
  static Future<({num? targetAmount, num achievedAmount})?>
  getMonthPerformanceForSalesPerson(String salesPersonName) async {
    try {
      final spDoc = await getDoc('Sales Person', salesPersonName);
      final userId = spDoc['custom_user'] as String?;

      num? monthlyTarget;
      final targets = spDoc['targets'];
      if (targets is List) {
        final today = DateTime.now().toIso8601String().split('T').first;
        final fiscalYears = await getList(
          'Fiscal Year',
          filters: [
            ['year_start_date', '<=', today],
            ['year_end_date', '>=', today],
          ],
          fields: const ['name'],
          limit: 1,
        );
        final currentFY = fiscalYears.isNotEmpty
            ? fiscalYears.first['name'] as String?
            : null;
        if (currentFY != null) {
          num annualSum = 0;
          var found = false;
          for (final row in targets.whereType<Map>()) {
            if (row['fiscal_year'] == currentFY) {
              final amt = row['target_amount'] as num?;
              if (amt != null) {
                annualSum += amt;
                found = true;
              }
            }
          }
          if (found) monthlyTarget = annualSum / 12;
        }
      }

      num achieved = 0;
      if (userId != null) {
        final now = DateTime.now();
        final firstOfMonth = DateTime(
          now.year,
          now.month,
          1,
        ).toIso8601String().split('T').first;
        final invoices = await getList(
          'Sales Invoice',
          filters: [
            ['owner', '=', userId],
            ['docstatus', '=', 1],
            ['posting_date', '>=', firstOfMonth],
          ],
          fields: const ['grand_total'],
          limit: 500,
        );
        for (final inv in invoices) {
          achieved += (inv['grand_total'] as num?) ?? 0;
        }
      }

      return (targetAmount: monthlyTarget, achievedAmount: achieved);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort "who's this employee's manager" resolution for
  /// `Expense Claim.expense_approver` — that field is a Link to **User**
  /// (confirmed), not Employee, so this is a real two-hop lookup:
  /// `Employee.reports_to` (the manager's Employee record) → that
  /// manager's own `user_id`. Purely a documentation/record field in this
  /// app (no approval gate is built on it, by explicit design), so a
  /// failure or missing manager just means the field stays empty — never
  /// blocks the expense from being recorded.
  static Future<String?> resolveExpenseApprover(String employeeName) async {
    try {
      final employee = await getDoc('Employee', employeeName);
      final managerEmployee = employee['reports_to'] as String?;
      if (managerEmployee == null || managerEmployee.isEmpty) return null;
      final manager = await getDoc('Employee', managerEmployee);
      return manager['user_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// `Company.cost_center` (default cost center) and
  /// `Company.default_payable_account` — both confirmed real fields,
  /// resolved via the employee's own `Company` since a bare REST insert of
  /// `Expense Claim` never gets Desk client JS's usual auto-fill for
  /// either. Both are genuinely required for the server to actually post
  /// GL entries for a paid Expense Claim (confirmed live: omitting
  /// `cost_center` on the expense line throws, and omitting
  /// `payable_account` fails GL entry construction even when
  /// `is_paid=1` bypasses the payable leg itself). Returns nulls on any
  /// failure — caller decides whether that's fatal.
  static Future<({String? costCenter, String? payableAccount})>
  resolveExpenseAccountingDefaults(String employeeName) async {
    try {
      final employee = await getDoc('Employee', employeeName);
      final company = employee['company'] as String?;
      if (company == null) return (costCenter: null, payableAccount: null);
      final companyDoc = await getDoc('Company', company);
      return (
        costCenter: companyDoc['cost_center'] as String?,
        payableAccount: companyDoc['default_payable_account'] as String?,
      );
    } catch (_) {
      return (costCenter: null, payableAccount: null);
    }
  }

  /// The current rep's own stock warehouses — `Sales Person.custom_car_warehouse`
  /// (مخزن السيارة الشخصي) + `custom_transit_warehouse` (مخزن الترانزيت بتاع
  /// منطقته), both confirmed real custom fields on this server. This is
  /// where goods a warehouse keeper transfers to the rep actually land —
  /// used for batch lookups (a batch only means something in the specific
  /// warehouse it's sitting in) and the "حركة المخزون" screen. Best-effort:
  /// returns an empty list on any failure rather than throwing, since
  /// nothing here should block the caller's own primary flow.
  static Future<List<String>> getCurrentRepWarehouses() async {
    try {
      final salesPerson = await resolveCurrentSalesPerson();
      if (salesPerson == null) return const [];
      final spDoc = await getDoc('Sales Person', salesPerson);
      final warehouses = <String>{};
      final car = spDoc['custom_car_warehouse'] as String?;
      final transit = spDoc['custom_transit_warehouse'] as String?;
      if (car != null && car.isNotEmpty) warehouses.add(car);
      if (transit != null && transit.isNotEmpty) warehouses.add(transit);
      return warehouses.toList();
    } catch (_) {
      return const [];
    }
  }

  /// Real, live available quantity per batch for [itemCode] in [warehouse]
  /// — `erpnext.stock.doctype.batch.batch.get_batch_qty` (confirmed
  /// whitelisted, real-time from stock ledger/reservations, not the
  /// possibly-stale `Batch.batch_qty` aggregate field). Returns
  /// `{batch_no, qty}` maps; callers filter to `qty > 0` themselves since
  /// this can include exhausted batches.
  static Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String itemCode,
    required String warehouse,
  }) async {
    final list = await callMethodList(
      '/api/method/erpnext.stock.doctype.batch.batch.get_batch_qty',
      params: {'item_code': itemCode, 'warehouse': warehouse},
    );
    return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // ---- Confirmed endpoint wrappers -----------------------------------

  /// `erpnext.accounts.party.get_party_details` — confirmed in
  /// erpnext-app-openapi. All query params are optional there; `party` and
  /// `party_type` are what we actually need for a sales rep picking a
  /// customer.
  static Future<Map<String, dynamic>> getPartyDetails({
    required String party,
    String partyType = 'Customer',
    String? company,
    String? priceList,
    String? doctype,
  }) {
    return callMethod(
      '/api/method/erpnext.accounts.party.get_party_details',
      params: {
        'party': party,
        'party_type': partyType,
        if (company != null) 'company': company,
        if (priceList != null) 'price_list': priceList,
        if (doctype != null) 'doctype': doctype,
      },
    );
  }

  /// `erpnext.selling.doctype.sales_order.sales_order.make_sales_invoice`
  /// — confirmed, `source_name` required. Returns a draft Sales Invoice
  /// doc that still needs to be POSTed to `/api/resource/Sales Invoice`
  /// to actually save it.
  static Future<Map<String, dynamic>> makeSalesInvoiceFromOrder(
    String sourceName,
  ) {
    return callMethod(
      '/api/method/erpnext.selling.doctype.sales_order.sales_order.make_sales_invoice',
      params: {'source_name': sourceName},
    );
  }

  /// `erpnext.accounts.doctype.sales_invoice.sales_invoice.make_sales_return`
  /// — confirmed, `source_name` required. Returns a draft credit-note doc
  /// (negative quantities) for the rep to review before submitting.
  static Future<Map<String, dynamic>> makeSalesReturn(String sourceName) {
    return callMethod(
      '/api/method/erpnext.accounts.doctype.sales_invoice.sales_invoice.make_sales_return',
      params: {'source_name': sourceName},
    );
  }

  /// `erpnext.selling.doctype.customer.customer.make_payment_entry` —
  /// confirmed, `source_name` (= customer name) required. Returns a draft
  /// Payment Entry doc that still needs to be POSTed to
  /// `/api/resource/Payment Entry`.
  static Future<Map<String, dynamic>> makePaymentEntryFromCustomer(
    String customerName,
  ) {
    return callMethod(
      '/api/method/erpnext.selling.doctype.customer.customer.make_payment_entry',
      params: {'source_name': customerName},
    );
  }

  /// `erpnext.accounts.doctype.payment_entry.payment_entry.get_outstanding_reference_documents`
  /// — the real bug behind "لا توجد فواتير مستحقة" always showing even for
  /// customers with real unpaid invoices, confirmed live this round:
  /// without `party_account` in `args`, this RPC throws
  /// (`cannot unpack non-iterable NoneType object`) — Desk's own JS
  /// resolves and injects `party_account` before calling this, which a
  /// bare REST call skips entirely. Resolved here from
  /// `Company.default_receivable_account`/`default_payable_account`
  /// (confirmed real fields) so the caller doesn't need to know about it.
  static Future<List<dynamic>> getOutstandingReferenceDocuments({
    required String party,
    required String company,
    String partyType = 'Customer',
    String paymentType = 'Receive',
  }) async {
    String? partyAccount;
    try {
      final companyDoc = await getDoc('Company', company);
      partyAccount = partyType == 'Customer'
          ? companyDoc['default_receivable_account'] as String?
          : companyDoc['default_payable_account'] as String?;
    } catch (_) {
      // Best-effort — the RPC below will very likely fail without it, but
      // a Company-lookup hiccup shouldn't be what blocks payment collection.
    }

    final args = jsonEncode({
      'party_type': partyType,
      'payment_type': paymentType,
      'party': party,
      'company': company,
      if (partyAccount != null) 'party_account': partyAccount,
    });
    return callMethodList(
      '/api/method/erpnext.accounts.doctype.payment_entry.payment_entry.get_outstanding_reference_documents',
      params: {'args': args},
    );
  }

  /// `erpnext.accounts.doctype.payment_entry.payment_entry.get_payment_entry`
  /// — the standard ERPNext "Create > Payment" RPC used from a specific
  /// Sales Invoice/Sales Order, not from the customer generally. Returns a
  /// draft Payment Entry already carrying a `references` row for just this
  /// one document (`allocated_amount` = its outstanding amount), unlike
  /// [makePaymentEntryFromCustomer] which starts blank and needs the
  /// outstanding invoices fetched separately.
  static Future<Map<String, dynamic>> getPaymentEntryForDoc(
    String doctype,
    String name,
  ) {
    return callMethod(
      '/api/method/erpnext.accounts.doctype.payment_entry.payment_entry.get_payment_entry',
      params: {'dt': doctype, 'dn': name},
    );
  }

  /// Uploads a local file and attaches it to an EXISTING document —
  /// `frappe.handler.upload_file`, the standard Frappe framework endpoint
  /// behind every "Attach" button in Desk (not ERPNext-specific, not
  /// guessed: `doctype`/`docname`/`is_private` are its confirmed standard
  /// multipart fields). Only meaningful for a document that already
  /// exists — a rep photographs the physical invoice/receipt AFTER saving
  /// it, same step position as everywhere else this app attaches evidence
  /// (GPS on send, not on typing).
  static Future<void> uploadFile({
    required String filePath,
    required String doctype,
    required String docname,
    bool isRetry = false,
  }) async {
    final domain = await AuthService.currentDomain();
    final token = await AuthService.currentAccessToken();
    if (domain == null || token == null) {
      throw const ErpException(
        'لا توجد جلسة محفوظة.',
        serverRejected: true,
        sessionExpired: true,
      );
    }

    final dio = _dio ??= Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    dio.options.baseUrl = domain;

    Response response;
    try {
      final formData = FormData.fromMap({
        'doctype': doctype,
        'docname': docname,
        'is_private': 1,
        'file': await MultipartFile.fromFile(filePath),
      });

      response = await dio
          .post(
            '/api/method/upload_file',
            data: formData,
            options: Options(
              headers: {'Authorization': 'Bearer $token'},
              validateStatus: (status) => status != null && status < 500,
            ),
          )
          .timeout(_hardNetworkTimeout);
    } on DioException catch (e) {
      throw _mapDioException(e);
    } on TimeoutException {
      throw const ErpException(
        'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
      );
    }

    // نفس منطق التجديد الصامت في `_send` — كان ناقص هنا خالص، يعني أي رفع
    // صورة بعد انتهاء صلاحية التوكن كان بيفشل فورًا بدل ما يجدد الجلسة
    // ويعيد المحاولة زي كل نداء تاني في السيرفس ده.
    if (response.statusCode == 401 && !isRetry) {
      try {
        await AuthService.refreshSession();
      } on AuthException {
        throw const ErpException(
          'انتهت صلاحية الجلسة، برجاء تسجيل الدخول مرة أخرى.',
          serverRejected: true,
          sessionExpired: true,
        );
      }
      return uploadFile(
        filePath: filePath,
        doctype: doctype,
        docname: docname,
        isRetry: true,
      );
    }

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw _mapErrorResponse(response);
    }
  }

  /// `erpnext.stock.doctype.material_request.material_request.make_in_transit_stock_entry`
  /// — confirmed, `source_name` AND `in_transit_warehouse` both required.
  static Future<Map<String, dynamic>> makeInTransitStockEntry({
    required String sourceName,
    required String inTransitWarehouse,
  }) {
    return callMethod(
      '/api/method/erpnext.stock.doctype.material_request.material_request.make_in_transit_stock_entry',
      params: {
        'source_name': sourceName,
        'in_transit_warehouse': inTransitWarehouse,
      },
    );
  }

  /// `erpnext.stock.doctype.stock_entry.stock_entry.make_stock_in_entry`
  /// — confirmed via the app catalog (`commit` app endpoint discovery),
  /// `source_name` required. Leg 2 of the in-transit transfer: takes the
  /// leg-1 Stock Entry (transit warehouse → source) created by
  /// [makeInTransitStockEntry] and returns a draft moving stock from the
  /// transit warehouse into the rep's real destination warehouse.
  static Future<Map<String, dynamic>> makeStockInEntry(String sourceName) {
    return callMethod(
      '/api/method/erpnext.stock.doctype.stock_entry.stock_entry.make_stock_in_entry',
      params: {'source_name': sourceName},
    );
  }

  /// **Not confirmed.** `red_app` is a custom app not covered by either
  /// OpenAPI spec; this path follows the same `<app>.api.<method>` naming
  /// convention as `mobile_control`'s endpoints, but the real path needs
  /// to be confirmed against the actual server (see integration notes).
  /// Any failure here (404, different shape, ...) is treated as "credit
  /// info unavailable" rather than a hard error, since it's a secondary
  /// enhancement on the customer list, not a blocker.
  static Future<Map<String, dynamic>?> getCustomerCreditStatus(
    String customer,
  ) async {
    try {
      return await callMethod(
        '/api/method/red_app.api.get_customer_credit_status',
        params: {'customer': customer},
      );
    } on ErpException {
      return null;
    }
  }

  // ---- Response unwrapping / error mapping ---------------------------

  /// REST creates/reads wrap the doc in `{"data": {...}}`; RPC methods
  /// wrap their return value in `{"message": ...}` per Frappe convention.
  /// Handles both through the one shared `_send` path.
  static Map<String, dynamic> _unwrapDoc(dynamic data) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final inner = map['data'] ?? map['message'];
      if (inner is Map) return Map<String, dynamic>.from(inner);
      if (map.containsKey('name') || map.containsKey('doctype')) return map;
    }
    return const <String, dynamic>{};
  }

  static ErpException _mapErrorResponse(Response response) {
    final data = response.data;
    if (data is Map) {
      final excType = data['exc_type']?.toString() ?? '';
      final exception = data['exception']?.toString() ?? '';
      if (excType == 'PermissionError' ||
          exception.contains('PermissionError')) {
        return const ErpException(
          'ليس لديك صلاحية لتنفيذ هذا الإجراء.',
          serverRejected: true,
        );
      }
      final serverMessage = data['message'];
      if (serverMessage is String && serverMessage.trim().isNotEmpty) {
        // Frappe's own validation messages (e.g. "Insufficient stock",
        // mandatory field errors) are already short and in the site's
        // configured language — safe to surface directly.
        return ErpException(serverMessage, serverRejected: true);
      }
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      return const ErpException(
        'انتهت صلاحية الجلسة أو ليس لديك صلاحية كافية.',
        serverRejected: true,
        sessionExpired: true,
      );
    }

    return const ErpException(
      'حدث خطأ غير متوقع أثناء الاتصال بالسيرفر، حاول مرة أخرى.',
      serverRejected: true,
    );
  }

  static ErpException _mapDioException(DioException e) {
    if (e.response != null) {
      return _mapErrorResponse(e.response!);
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ErpException(
          'انتهت مهلة الاتصال بالسيرفر، تأكد من الشبكة وحاول مرة أخرى.',
        );
      case DioExceptionType.connectionError:
        return const ErpException(
          'تعذر الاتصال بالسيرفر، تأكد من اتصالك بالإنترنت.',
        );
      default:
        return const ErpException('حدث خطأ غير متوقع، حاول مرة أخرى لاحقًا.');
    }
  }
}
