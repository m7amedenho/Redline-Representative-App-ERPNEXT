import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../local_db/sync_job_type.dart';
import '../services/auth_service.dart';
import '../services/calendar_service.dart';
import '../services/erp_service.dart';
import '../services/pdf_builder_service.dart';
import '../services/sync_engine.dart';
import '../services/sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/doc_status.dart';
import '../utils/erp_error_handling.dart';
import '../utils/html_text.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_picker.dart';
import '../widgets/swipe_to_confirm_button.dart';
import 'treasury_screen.dart';

/// Route path for [DocumentDetailScreen] — doctype/name are URL-encoded
/// since DocType names like "Sales Order" contain spaces.
String documentDetailRoute(String doctype, String name) =>
    '/document/${Uri.encodeComponent(doctype)}/${Uri.encodeComponent(name)}';

/// Generic document view for any DocType — status (workflow or plain
/// docstatus), available workflow actions, and a comment thread. Used
/// after creating a document (instead of just a SnackBar) and when a
/// notification points at a specific document.
///
/// Workflow endpoints (`frappe.model.workflow.get_transitions`/
/// `apply_workflow`) are confirmed to exist in frappe-app-openapi, but this
/// site's actual workflow name/states/action labels are unknown — the
/// available actions are read dynamically from `get_transitions`, nothing
/// is hardcoded. Comments are created via a plain `POST
/// /api/resource/Comment` (not `frappe.desk.form.utils.add_comment` — that
/// RPC needs Desk Access, which field-rep accounts deliberately never get).
/// See docs/API_INTEGRATION_NOTES.md.
class DocumentDetailScreen extends StatefulWidget {
  const DocumentDetailScreen({
    super.key,
    required this.doctype,
    required this.name,
  });

  final String doctype;
  final String name;

  @override
  State<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends State<DocumentDetailScreen> {
  Map<String, dynamic>? _doc;
  bool _loadingDoc = true;
  String? _docError;

  List<Map<String, dynamic>> _transitions = [];
  bool _loadingTransitions = false;
  bool _applyingAction = false;
  bool _sendingDocument = false;
  bool _editingDiscount = false;
  int? _editingItemIndex;
  bool _sharingPdf = false;
  bool _collectingPayment = false;
  final Set<int> _addingReminderIndices = {};
  bool _addingAllReminders = false;
  bool _attachingPhoto = false;
  bool _uploadingImages = false;

  /// Per-item-code discount limit for the CURRENT user's own resolved tier
  /// only (not the full `custom_role_discount_limits` table) — prefetched
  /// once when the document loads (see [_loadItemDiscountLimits]) instead
  /// of lazily per tap, so the per-item discount icon can be hidden
  /// entirely for items with no matching row for this user's role, and so
  /// the edit dialog can validate in real time without a network round
  /// trip. Only items with an actual matching row are present as keys.
  final Map<String, num> _itemDiscountLimits = {};
  String? _resolvedDiscountTier;

  List<String> _workflowStates = [];
  final Map<String, String?> _workflowStateAllowEdit = {};
  bool _loadingWorkflowStates = false;
  List<String> _userRoles = [];
  String? _originState;
  String? _originActorName;

  List<Map<String, dynamic>> _comments = [];
  bool _loadingComments = true;
  final _commentController = TextEditingController();
  bool _sendingComment = false;
  final Map<String, String> _pickedMentions = {};

  @override
  void initState() {
    super.initState();
    _loadDocument();
    _loadComments();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _loadingDoc = true;
      _docError = null;
    });
    try {
      final doc = await ErpService.getDoc(widget.doctype, widget.name);
      if (!mounted) return;
      setState(() => _doc = doc);
      await Future.wait([
        _loadTransitions(),
        _loadWorkflowStates(),
        _loadItemDiscountLimits(),
        _loadUserRoles(),
        _loadOriginState(),
      ]);
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() => _docError = message);
    } finally {
      if (mounted) setState(() => _loadingDoc = false);
    }
  }

  /// Pull-to-refresh — same fetch as [_loadDocument] but never swaps the
  /// whole body out for the full-page [LoadingIndicator]; `RefreshIndicator`
  /// already shows its own spinner while this runs.
  Future<void> _refresh() async {
    try {
      final doc = await ErpService.getDoc(widget.doctype, widget.name);
      if (!mounted) return;
      setState(() => _doc = doc);
      await Future.wait([
        _loadTransitions(),
        _loadWorkflowStates(),
        _loadItemDiscountLimits(),
        _loadUserRoles(),
        _loadOriginState(),
        _loadComments(),
      ]);
    } catch (_) {
      // Best-effort — a failed pull-to-refresh just leaves the screen as-is.
    }
  }

  Future<void> _loadTransitions() async {
    final doc = _doc;
    if (doc == null) return;
    setState(() => _loadingTransitions = true);
    try {
      final list = await ErpService.callMethodListPost(
        '/api/method/frappe.model.workflow.get_transitions',
        params: {'doc': jsonEncode(doc)},
      );
      if (!mounted) return;
      setState(() {
        _transitions = list
            .whereType<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
      });
    } catch (_) {
      // No workflow configured on this DocType (or the call failed) — just
      // means no action buttons show, not a blocking error.
      if (mounted) setState(() => _transitions = []);
    } finally {
      if (mounted) setState(() => _loadingTransitions = false);
    }
  }

  /// The ordered list of state labels from this DocType's actual `Workflow`
  /// definition — used to draw the step-by-step progress diagram below.
  /// Empty (and the diagram just doesn't show) if this DocType has no
  /// active workflow, matching [_loadTransitions]'s same graceful fallback.
  Future<void> _loadWorkflowStates() async {
    setState(() => _loadingWorkflowStates = true);
    try {
      final workflow = await ErpService.getWorkflowDefinition(widget.doctype);
      final states = workflow?['states'];
      _workflowStateAllowEdit.clear();
      if (states is List) {
        final rows = states.whereType<Map>().toList();
        _workflowStates = rows
            .map((s) => s['state']?.toString())
            .whereType<String>()
            .toList();
        for (final row in rows) {
          final state = row['state']?.toString();
          if (state != null) {
            _workflowStateAllowEdit[state] = row['allow_edit']?.toString();
          }
        }
      } else {
        _workflowStates = [];
      }
    } catch (_) {
      _workflowStates = [];
    }
    if (mounted) setState(() => _loadingWorkflowStates = false);
  }

  Future<void> _loadUserRoles() async {
    final roles = await AuthService.currentUserRoles();
    if (mounted) setState(() => _userRoles = roles);
  }

  /// See `ErpService.getLastWorkflowTransition` — best-effort, null just
  /// means the stepper falls back to assuming a normal adjacent transition
  /// with no actor caption shown.
  Future<void> _loadOriginState() async {
    final transition = await ErpService.getLastWorkflowTransition(
      widget.doctype,
      widget.name,
    );
    if (!mounted) return;
    setState(() {
      _originState = transition?.fromState;
      _originActorName = null;
    });
    final actor = transition?.actor;
    if (actor == null) return;
    // Best-effort: resolve the raw user id (an email) to a readable name —
    // a failure here just means the caption falls back to showing the
    // email itself instead of silently disappearing.
    try {
      final user = await ErpService.getDoc('User', actor);
      final fullName = user['full_name'] as String?;
      if (mounted) {
        setState(() => _originActorName = fullName ?? actor);
      }
    } catch (_) {
      if (mounted) setState(() => _originActorName = actor);
    }
  }

  /// Whether the CURRENT user can edit this document right now, per the
  /// real `Workflow Document State.allow_edit` role for whatever state the
  /// document is actually in — never a hardcoded state name. Only offered
  /// for the doctypes that actually have a real edit screen to send the
  /// user to (Sales Order/Sales Invoice/Customer); other doctypes fall
  /// back to their existing read-only + workflow-action-only behavior.
  bool get _canEditCurrentState {
    if (widget.doctype != 'Sales Order' &&
        widget.doctype != 'Sales Invoice' &&
        widget.doctype != 'Customer') {
      return false;
    }
    final doc = _doc;
    if (doc == null) return false;
    final state = doc['workflow_state'] as String?;
    if (state == null) return false;
    final allowEdit = _workflowStateAllowEdit[state];
    if (allowEdit == null || allowEdit.isEmpty) return false;
    return _userRoles.contains(allowEdit);
  }

  /// Prefetches [_itemDiscountLimits] for every line item — one `Item` doc
  /// fetch per unique `item_code`, and the current user's tier resolved
  /// once (not per item). Best-effort: any failure (network, permission)
  /// just means the affected item's discount icon stays hidden, matching
  /// the fail-closed intent of "hide the control when no limit is known"
  /// rather than fail-open into showing an unvalidated editor.
  Future<void> _loadItemDiscountLimits() async {
    final doc = _doc;
    if (doc == null || !_canEditItemDiscount) return;
    final items = doc['items'];
    if (items is! List) return;

    final itemCodes = items
        .whereType<Map>()
        .map((i) => i['item_code']?.toString())
        .whereType<String>()
        .toSet();
    if (itemCodes.isEmpty) return;

    final roles = await AuthService.currentUserRoles();
    final tier = AuthService.resolveDiscountTier(roles);
    if (!mounted) return;
    setState(() => _resolvedDiscountTier = tier);
    if (tier == null) return;

    final limits = <String, num>{};
    for (final itemCode in itemCodes) {
      try {
        final itemDoc = await ErpService.getDoc('Item', itemCode);
        final rows = itemDoc['custom_role_discount_limits'];
        if (rows is! List) continue;
        for (final row in rows.whereType<Map>()) {
          if (row['role'] == tier) {
            final limit = row['max_discount_percent'] as num?;
            if (limit != null) limits[itemCode] = limit;
            break;
          }
        }
      } catch (_) {
        // Ignored — this item's icon just stays hidden.
      }
    }
    if (!mounted) return;
    setState(() {
      _itemDiscountLimits.clear();
      _itemDiscountLimits.addAll(limits);
    });
  }

  Future<void> _applyAction(String action) async {
    final doc = _doc;
    if (doc == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: Text(action),
        content: const Text('هل أنت متأكد من تنفيذ هذا الإجراء؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'تأكيد',
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _applyingAction = true);

    Future<void> queueOffline() async {
      await SyncEngine().enqueue(
        type: SyncJobType.genericApiCall,
        payload: {
          'operation': 'applyWorkflow',
          'doctype': widget.doctype,
          'name': widget.name,
          'doc': jsonEncode(doc),
          'action': action,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا يوجد اتصال — سيُنفَّذ "$action" تلقائيًا عند توفر الاتصال',
          ),
        ),
      );
    }

    try {
      if (!SyncStatusService().isOnline) {
        await queueOffline();
        return;
      }

      final updated = await ErpService.callMethodPost(
        '/api/method/frappe.model.workflow.apply_workflow',
        params: {'doc': jsonEncode(doc), 'action': action},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تم تنفيذ "$action" بنجاح')));
      if (updated.isNotEmpty) setState(() => _doc = updated);
      await _loadTransitions();
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await queueOffline();
        return;
      }
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _applyingAction = false);
    }
  }

  /// The explicit "send" action — creation screens now only ever save a
  /// plain Draft (see sales_order_screen.dart etc.), so moving a document
  /// past Draft is always this deliberate, separate step, never automatic.
  /// Reuses `ErpService.tryAutoProgress` (single available transition →
  /// `apply_workflow`; no workflow at all → plain `docstatus:1` submit) —
  /// only shown (see [_buildBody]) when there's at most one transition, so
  /// it never silently guesses which of several branching approval paths
  /// to take.
  /// يرجع النتيجة الحقيقية (نجح/فشل) — [SwipeToConfirmButton] بيعكسها
  /// كحالة حمراء بدل ما يفترض النجاح لمجرد إن حركة السحب خلصت.
  Future<bool> _sendDocument() async {
    final doc = _doc;
    if (doc == null) return false;

    setState(() => _sendingDocument = true);
    final beforeState = doc['workflow_state'];
    final result = await ErpService.tryAutoProgress(widget.doctype, doc);
    final updated = result.doc;
    if (!mounted) return true;
    setState(() => _doc = updated);
    await Future.wait([
      _loadTransitions(),
      _loadWorkflowStates(),
      _loadOriginState(),
    ]);
    if (!mounted) return true;
    // `docstatus` alone doesn't prove anything here — in a real multi-step
    // workflow it stays 0 through every intermediate approved state, only
    // flipping to 1 at final approval. Whether the send actually worked is
    // whether `workflow_state` itself moved.
    final sent = updated['workflow_state'] != beforeState;
    if (sent) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم إرسال المستند بنجاح')));
    } else {
      // Show the REAL reason it failed (e.g. an actual insufficient-stock
      // rejection from the server) instead of a generic, unhelpful
      // "تعذر إرسال المستند" — that message was hiding genuinely useful
      // errors, confirmed from a real report.
      final error = result.error;
      if (error != null) {
        final message = handleErpError(context, error);
        if (message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر إرسال المستند — راجعه يدويًا')),
        );
      }
    }
    if (mounted) setState(() => _sendingDocument = false);
    return sent;
  }

  /// Whether the discount-editing action should show at all — only makes
  /// sense on the doctypes that actually carry these fields
  /// (`additional_discount_percentage`/`discount_amount`, standard on Sales
  /// Order/Sales Invoice), and not on a cancelled document. Whether the
  /// current user actually has Write permission to change it isn't checked
  /// here — same as everywhere else in this app, the attempt is made and
  /// the server's own rejection (if any) is shown via [handleErpError].
  /// The document-level "extra discount" button (`additional_discount_percentage`/
  /// `discount_amount`) — Sales Invoice only. Explicitly excludes Sales
  /// Order per direct instruction: this business doesn't use a document-level
  /// discount concept on orders, only on invoices (per-item discounts,
  /// governed by [_canEditItemDiscount] below, are a separate feature and
  /// still apply to both).
  ///
  /// Gated on [_resolvedDiscountTier] (manager tiers only, see
  /// [AuthService.resolveDiscountTier]) — previously had no role check at
  /// all, letting a sales rep apply an unbounded document-level discount
  /// with no limit, unlike the per-item path below which was always
  /// tier-gated and limit-enforced.
  bool get _canEditDiscount {
    final doc = _doc;
    if (doc == null) return false;
    if (widget.doctype != 'Sales Invoice') return false;
    if (_resolvedDiscountTier == null) return false;
    final docstatus = (doc['docstatus'] as num?)?.toInt() ?? 0;
    return docstatus != 2;
  }

  /// Per-item discount editing — Sales Order and Sales Invoice both, unlike
  /// [_canEditDiscount] above.
  bool get _canEditItemDiscount {
    final doc = _doc;
    if (doc == null) return false;
    if (widget.doctype != 'Sales Order' && widget.doctype != 'Sales Invoice') {
      return false;
    }
    final docstatus = (doc['docstatus'] as num?)?.toInt() ?? 0;
    return docstatus != 2;
  }

  Future<void> _editDiscount() async {
    final doc = _doc;
    if (doc == null || _editingDiscount) return;

    final percentController = TextEditingController(
      text: (doc['additional_discount_percentage'] as num?)?.toString() ?? '',
    );
    final amountController = TextEditingController(
      text: (doc['discount_amount'] as num?)?.toString() ?? '',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: const Text('تعديل الخصم'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: percentController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              // `autocorrect`/`enableSuggestions` off: Samsung's One UI
              // keyboard prediction bar has a known interaction bug with
              // Flutter's text-input platform channel on numeric-decimal
              // fields that can freeze the main thread (matches the real
              // ANR reported on this exact device model, SM-A165F).
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'نسبة الخصم %'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'قيمة الخصم'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'حفظ',
              style: TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    final percent = double.tryParse(percentController.text.trim()) ?? 0;
    final amount = double.tryParse(amountController.text.trim()) ?? 0;
    percentController.dispose();
    amountController.dispose();
    if (confirmed != true) return;

    // Was previously missing entirely — the request (up to the 25s hard
    // timeout in ErpService) ran with zero visual feedback, which read as
    // the app hanging even though it was just waiting on the network.
    final discountData = {
      'additional_discount_percentage': percent,
      'discount_amount': amount,
    };

    setState(() => _editingDiscount = true);
    try {
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'update',
            'doctype': widget.doctype,
            'name': widget.name,
            'data': discountData,
          },
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — سيُحفظ الخصم تلقائيًا'),
          ),
        );
        return;
      }
      final updated = await ErpService.updateDoc(
        widget.doctype,
        widget.name,
        discountData,
      );
      if (!mounted) return;
      setState(() => _doc = updated.isNotEmpty ? updated : _doc);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تحديث الخصم بنجاح')));
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'update',
            'doctype': widget.doctype,
            'name': widget.name,
            'data': discountData,
          },
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — سيُحفظ الخصم تلقائيًا'),
          ),
        );
        return;
      }
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _editingDiscount = false);
    }
  }

  /// Built entirely on-device from the document data already loaded on this
  /// screen ([_doc]) — no server round trip. Replaces the old server-side
  /// `frappe.utils.print_format.download_pdf` call, which reps on real
  /// field connections reported as slow/unreliable; generating locally
  /// removes that network hop (and its failure surface) completely.
  Future<void> _sharePdf() async {
    if (_sharingPdf) return;
    final doc = _doc;
    if (doc == null) return;
    setState(() => _sharingPdf = true);
    try {
      final bytes = await PdfBuilderService.buildDocumentPdf(
        doctype: widget.doctype,
        name: widget.name,
        doc: doc,
      );
      if (!mounted) return;
      await Printing.sharePdf(bytes: bytes, filename: '${widget.name}.pdf');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء ملف PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharingPdf = false);
    }
  }

  /// Photographs the physical document (e.g. a signed paper copy, or a
  /// receipt) with the camera and attaches it straight to this ALREADY-
  /// SAVED record via `ErpService.uploadFile` — same "evidence captured
  /// after saving, not during" pattern as GPS capture on send. Private
  /// attachment (not publicly linkable), same default every other
  /// attachment in this app's ecosystem would get from Desk's own
  /// "Attach" button.
  /// Copies the picker's own (possibly OS-clearable) cache file into a
  /// durable app-support folder and queues a `photoAttach` job — replayed
  /// by `SyncEngine` once online, which deletes the local copy only after
  /// a confirmed-success upload.
  Future<void> _queuePhotoOffline(String sourcePath) async {
    final supportDir = await getApplicationSupportDirectory();
    final photosDir = Directory(p.join(supportDir.path, 'pending_photos'));
    await photosDir.create(recursive: true);
    final destPath = p.join(
      photosDir.path,
      '${DateTime.now().microsecondsSinceEpoch}${p.extension(sourcePath)}',
    );
    await File(sourcePath).copy(destPath);
    await SyncEngine().enqueue(
      type: SyncJobType.photoAttach,
      payload: {'doctype': widget.doctype, 'docname': widget.name},
      localPhotoPath: destPath,
    );
  }

  /// Returns `true` if it was QUEUED for later rather than uploaded live —
  /// throws on a real failure.
  Future<bool> _uploadOrQueuePhoto(String sourcePath) async {
    if (!SyncStatusService().isOnline) {
      await _queuePhotoOffline(sourcePath);
      return true;
    }
    try {
      await ErpService.uploadFile(
        filePath: sourcePath,
        doctype: widget.doctype,
        docname: widget.name,
      );
      return false;
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await _queuePhotoOffline(sourcePath);
        return true;
      }
      rethrow;
    }
  }

  Future<void> _capturePhotoAndAttach() async {
    if (_attachingPhoto) return;
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (photo == null) return;

    setState(() => _attachingPhoto = true);
    try {
      final queued = await _uploadOrQueuePhoto(photo.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            queued
                ? 'لا يوجد اتصال — تم حفظ الصورة وسترفع تلقائيًا'
                : 'تم إرفاق الصورة بالمستند بنجاح',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _attachingPhoto = false);
    }
  }

  /// Same idea as [_capturePhotoAndAttach] but from the gallery and
  /// multiple images at once (`pickMultiImage`) — for attaching existing
  /// photos (a customer's shop front, guarantee documents, etc.) instead
  /// of shooting fresh ones. Uploads sequentially so one failure doesn't
  /// silently drop the rest — reports how many actually made it.
  Future<void> _pickAndUploadImages() async {
    if (_uploadingImages) return;
    final photos = await ImagePicker().pickMultiImage(imageQuality: 85);
    if (photos.isEmpty) return;

    setState(() => _uploadingImages = true);
    var uploaded = 0;
    var queued = 0;
    Object? lastError;
    for (final photo in photos) {
      try {
        if (await _uploadOrQueuePhoto(photo.path)) {
          queued++;
        } else {
          uploaded++;
        }
      } catch (e) {
        lastError = e;
      }
    }
    if (!mounted) return;
    if (uploaded > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إرفاق $uploaded صورة بالمستند')),
      );
    }
    if (queued > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('لا يوجد اتصال — تم حفظ $queued صورة وسترفع تلقائيًا'),
        ),
      );
    }
    if (lastError != null) {
      final message = handleErpError(context, lastError);
      if (message != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
    setState(() => _uploadingImages = false);
  }

  /// Collect a payment against THIS specific invoice — reuses the standard
  /// ERPNext "Create > Payment" RPC (`ErpService.getPaymentEntryForDoc`,
  /// same one Desk's own invoice view calls), which already returns a
  /// draft with the reference row for this exact document pre-filled and
  /// its amount already allocated. The rep still explicitly picks which
  /// treasury (real, company-owned cash box/bank/e-wallet — never their
  /// own personal account) the money went into, and can adjust the amount
  /// down for a partial collection — never sent to the server without this
  /// explicit confirmation step.
  Future<void> _collectPayment() async {
    if (_collectingPayment) return;
    setState(() => _collectingPayment = true);
    try {
      final draft = await ErpService.getPaymentEntryForDoc(
        widget.doctype,
        widget.name,
      );
      if (!mounted) return;

      final defaultAmount = (draft['paid_amount'] as num?) ?? 0;
      final amountController = TextEditingController(
        text: defaultAmount.toStringAsFixed(2),
      );
      final receiptNumberController = TextEditingController();
      TreasuryInfo? treasury;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            title: const Text('تحصيل دفعة'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'المبلغ المحصّل',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: receiptNumberController,
                  decoration: const InputDecoration(
                    labelText: 'رقم الإيصال الورقي *',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await pickTreasury(context);
                    if (picked != null) {
                      setDialogState(() => treasury = picked);
                    }
                  },
                  icon: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 16,
                  ),
                  label: Text(treasury?.treasuryName ?? 'اختر الخزنة '),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('إلغاء'),
              ),
              TextButton(
                onPressed: receiptNumberController.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: const Text(
                  'تأكيد التحصيل',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      final amount = double.tryParse(amountController.text.trim()) ?? 0;
      final receiptNumber = receiptNumberController.text.trim();
      amountController.dispose();
      receiptNumberController.dispose();
      if (confirmed != true || amount <= 0) return;

      final payload = Map<String, dynamic>.from(draft);
      payload['paid_amount'] = amount;
      payload['received_amount'] = amount;
      payload['custom_رقم_الإيصال_الورقي'] = receiptNumber;
      final refs = payload['references'];
      if (refs is List && refs.isNotEmpty) {
        final firstRef = Map<String, dynamic>.from(refs.first as Map);
        firstRef['allocated_amount'] = amount;
        payload['references'] = [firstRef];
      }
      if (treasury != null) {
        if (treasury!.modeOfPayment != null) {
          payload['mode_of_payment'] = treasury!.modeOfPayment;
        }
        if (treasury!.account != null) payload['paid_to'] = treasury!.account;
      }

      final created = await ErpService.createDoc('Payment Entry', payload);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تسجيل التحصيل بنجاح')));
      await _loadDocument();
      final createdName = created['name'] as String?;
      if (createdName != null && mounted) {
        context.push(documentDetailRoute('Payment Entry', createdName));
      }
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _collectingPayment = false);
    }
  }

  /// See [CalendarService.addPaymentReminder] — best-effort, tells the rep
  /// plainly (not silently) when it couldn't add the reminder (permission
  /// denied or no calendar on the device) instead of pretending it worked.
  Future<bool> _addCalendarReminder(
    int index,
    String customerName,
    num amount,
    String dueDateStr,
  ) async {
    final dueDate = DateTime.tryParse(dueDateStr);
    if (dueDate == null) return false;
    setState(() => _addingReminderIndices.add(index));
    try {
      final added = await CalendarService.addPaymentReminder(
        customerName: customerName,
        documentName: widget.name,
        amount: amount,
        dueDate: dueDate,
      );
      if (!mounted) return added;
      if (!_addingAllReminders) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added
                  ? 'تمت إضافة التذكير للتقويم'
                  : 'تعذر إضافة التذكير — تأكد من صلاحية التقويم على الجهاز',
            ),
          ),
        );
      }
      return added;
    } catch (e) {
      if (!mounted) return false;
      if (!_addingAllReminders) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر إضافة التذكير: $e')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _addingReminderIndices.remove(index));
    }
  }

  /// إضافة كل صفوف جدول الدفعات دفعة واحدة — تسلسليًا (مش parallel) عشان
  /// [CalendarService] بيحل هوية التقويم القابل للكتابة مرة واحدة داخليًا
  /// ومفيش ضمان إنه Thread-safe لاستدعاءات متزامنة.
  Future<void> _addAllCalendarReminders(
    List<Map<String, dynamic>> rows,
    String customerName,
  ) async {
    setState(() => _addingAllReminders = true);
    var succeeded = 0;
    var total = 0;
    for (var i = 0; i < rows.length; i++) {
      final dueDate = rows[i]['due_date'] as String?;
      if (dueDate == null) continue;
      final amount =
          (rows[i]['outstanding'] as num?) ??
          (rows[i]['payment_amount'] as num?) ??
          0;
      total++;
      final added = await _addCalendarReminder(i, customerName, amount, dueDate);
      if (added) succeeded++;
    }
    if (!mounted) return;
    setState(() => _addingAllReminders = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          total == 0
              ? 'لا توجد مواعيد استحقاق لإضافتها'
              : 'تمت إضافة $succeeded من $total تذكيرًا للتقويم',
        ),
      ),
    );
  }

  /// Human-readable label for a `WF - *` discount tier — same set
  /// [AuthService.resolveDiscountTier] resolves from. Used only for
  /// display in the discount dialog so the rep sees their own role in
  /// plain Arabic, not the raw role name.
  String _tierLabel(String tier) =>
      const {
        'WF - Sales Rep': 'مندوب مبيعات',
        'WF - Region Manager': 'مدير منطقة',
        'WF - Accounts Manager': 'مدير حسابات',
        'WF - General Manager': 'مدير عام',
      }[tier] ??
      tier;

  /// Per-line discount — separate from [_editDiscount] above (that one is
  /// the document-level "extra discount" total; this is each item's own
  /// `discount_percentage`, which is what ERPNext's real `Item.max_discount`
  /// validation actually checks against, and what
  /// `Item.custom_role_discount_limits` (role-tiered limits) is meant to
  /// guide. [limit] is always non-null here — the calling icon in
  /// [_buildItemsSection] only renders when [_itemDiscountLimits] already
  /// has a matching entry for this item and the user's own tier (prefetched
  /// in [_loadItemDiscountLimits]), so there's nothing left to fetch at tap
  /// time and no risk of showing an editor for an item with no limit
  /// configured for this user's role at all.
  ///
  /// Hard-blocks rather than warning after save: the percent field is
  /// validated on every keystroke, and "حفظ" is disabled outright whenever
  /// the typed value exceeds [limit] — never sent to the server in the
  /// first place.
  ///
  /// Confirmed by direct testing against the real server: sending
  /// `discount_percentage` alone does nothing — the server derives the
  /// stored discount from `rate` vs `price_list_rate`, so `rate` has to be
  /// sent consistently alongside it (`rate = price_list_rate * (1 -
  /// discount% / 100)`) or the discount silently resets to 0. Also
  /// confirmed: updating one line requires resending the *entire* `items`
  /// array (an unqualified partial update doesn't work).
  Future<void> _editItemDiscount(
    int index,
    Map<String, dynamic> item,
    num limit,
  ) async {
    final doc = _doc;
    if (doc == null || _editingItemIndex != null) return;

    final priceListRate =
        (item['price_list_rate'] as num?) ?? (item['rate'] as num?) ?? 0;
    final tierLabel = _resolvedDiscountTier != null
        ? _tierLabel(_resolvedDiscountTier!)
        : null;

    final percentController = TextEditingController(
      text: (item['discount_percentage'] as num?)?.toString() ?? '',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final percent = double.tryParse(percentController.text.trim());
          final exceeds = percent != null && percent > limit;
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            title: const Text('تعديل خصم الصنف'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tierLabel != null
                      ? 'أقصى خصم مسموح لك ($tierLabel): $limit%'
                      : 'أقصى خصم مسموح لمستواك: $limit%',
                  style: const TextStyle(
                    color: AppColors.midGray,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: percentController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'نسبة الخصم %',
                    errorText: exceeds
                        ? 'أكبر من الحد المسموح ($limit%)'
                        : null,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('إلغاء'),
              ),
              TextButton(
                onPressed: exceeds
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: const Text(
                  'حفظ',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );

    final percent = double.tryParse(percentController.text.trim()) ?? 0;
    percentController.dispose();
    if (confirmed != true) return;

    setState(() => _editingItemIndex = index);
    final items = (doc['items'] as List)
        .whereType<Map>()
        .map((i) => Map<String, dynamic>.from(i))
        .toList();
    items[index]['discount_percentage'] = percent;
    items[index]['rate'] = priceListRate * (1 - percent / 100);
    final itemsData = {'items': items};

    try {
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'update',
            'doctype': widget.doctype,
            'name': widget.name,
            'data': itemsData,
          },
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — سيُحفظ خصم الصنف تلقائيًا'),
          ),
        );
        return;
      }
      final updated = await ErpService.updateDoc(
        widget.doctype,
        widget.name,
        itemsData,
      );
      if (!mounted) return;
      setState(() => _doc = updated.isNotEmpty ? updated : _doc);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تحديث خصم الصنف بنجاح')));
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'update',
            'doctype': widget.doctype,
            'name': widget.name,
            'data': itemsData,
          },
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — سيُحفظ خصم الصنف تلقائيًا'),
          ),
        );
        return;
      }
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _editingItemIndex = null);
    }
  }

  Future<void> _loadComments() async {
    setState(() => _loadingComments = true);
    try {
      final list = await ErpService.getList(
        'Comment',
        filters: [
          ['reference_doctype', '=', widget.doctype],
          ['reference_name', '=', widget.name],
          ['comment_type', '=', 'Comment'],
        ],
        fields: const ['name', 'content', 'comment_by', 'creation'],
        orderBy: 'creation desc',
        limit: 100,
      );
      if (!mounted) return;
      setState(() => _comments = list);
    } catch (_) {
      // Best-effort — comments section just stays empty on failure.
    } finally {
      if (mounted) setState(() => _loadingComments = false);
    }
  }

  /// ❓ Not confirmed against this server — Frappe's own frontend inserts
  /// mentions into a comment's HTML `content` as
  /// `<span class="mention" data-id="user@email">@Full Name</span>`, which
  /// is what's used here, but the exact markup this site's `Comment`
  /// handling expects to actually trigger a notification hasn't been
  /// verified. Worst case if it's wrong: the comment still posts fine
  /// (plain REST create, same as any comment), it just won't notify anyone.
  Future<void> _pickMention() async {
    final result = await showSearchPicker(
      context: context,
      title: 'منشن مستخدم',
      hintText: 'ابحث باسم المستخدم...',
      search: (query) async {
        final list = await ErpService.getList(
          'User',
          filters: [
            ['enabled', '=', 1],
            if (query.isNotEmpty) ['full_name', 'like', '%$query%'],
          ],
          fields: const ['name', 'full_name'],
          limit: 20,
        );
        return list
            .map(
              (u) => PickedRecord(
                name: u['name'] as String,
                label: (u['full_name'] as String?) ?? u['name'] as String,
              ),
            )
            .toList();
      },
    );
    if (result == null) return;

    final label = '@${result.label}';
    _pickedMentions[label] = result.name;

    _commentController.text = '${_commentController.text}$label ';
    _commentController.selection = TextSelection.collapsed(
      offset: _commentController.text.length,
    );
  }

  Future<void> _sendComment() async {
    String text = _commentController.text.trim();
    if (text.isEmpty) return;

    for (final entry in _pickedMentions.entries) {
      final label = entry.key;
      final id = entry.value;
      if (text.contains(label)) {
        text = text.replaceAll(
          label,
          '<span class="mention" data-id="$id">$label</span>',
        );
      }
    }

    final commentData = {
      'comment_type': 'Comment',
      'reference_doctype': widget.doctype,
      'reference_name': widget.name,
      'content': text,
    };

    setState(() => _sendingComment = true);
    try {
      if (!SyncStatusService().isOnline) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'create',
            'doctype': 'Comment',
            'data': commentData,
          },
        );
        if (!mounted) return;
        _commentController.clear();
        _pickedMentions.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يوجد اتصال — سيُرسل التعليق تلقائيًا'),
          ),
        );
        return;
      }

      // Plain REST create instead of `frappe.desk.form.utils.add_comment` —
      // that RPC lives under the `frappe.desk` namespace and was getting
      // rejected with PermissionError for accounts without Desk Access,
      // which this app's field-rep accounts deliberately never get (fixed
      // security decision, not something to work around). A normal
      // `/api/resource/Comment` create only needs Create permission on the
      // Comment DocType itself, same as everything else in this app.
      await ErpService.createDoc('Comment', commentData);
      if (!mounted) return;
      _commentController.clear();
      _pickedMentions.clear();
      await _loadComments();
    } catch (e) {
      if (e is ErpException && e.isConnectivityFailure) {
        await SyncEngine().enqueue(
          type: SyncJobType.genericApiCall,
          payload: {
            'operation': 'create',
            'doctype': 'Comment',
            'data': commentData,
          },
        );
        if (!mounted) return;
        _commentController.clear();
        _pickedMentions.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الاتصال — سيُرسل التعليق تلقائيًا'),
          ),
        );
        return;
      }
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _sendingComment = false);
    }
  }

  String _relativeTime(String? iso) {
    final time = DateTime.tryParse(iso ?? '');
    if (time == null) return '';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays < 7) return 'منذ ${diff.inDays} يوم';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  /// Status priority: this app's custom `workflow_state` first (most
  /// specific to how this site actually processes documents), then the
  /// standard ERPNext `status` field (e.g. "To Deliver and Bill", "Paid",
  /// "Overdue" — confirmed present on both Sales Order and Sales Invoice),
  /// falling back to a plain docstatus label only if neither exists.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: Text(widget.doctype)),
      body: SafeArea(
        child: _loadingDoc
            ? const LoadingIndicator()
            : _docError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _docError!,
                        style: const TextStyle(color: AppColors.accent),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _loadDocument,
                        child: const Text('حاول مرة أخرى'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  Expanded(child: _buildBody()),
                  _buildCommentInput(),
                ],
              ),
      ),
    );
  }

  Widget _buildBody() {
    final doc = _doc!;
    final status = docStatusInfo(doc);
    final subtitle =
        (doc['customer_name'] ??
                doc['customer'] ??
                doc['party_name'] ??
                doc['party'])
            ?.toString();
    final amount = (doc['grand_total'] ?? doc['paid_amount'])?.toString();

    // Exactly one available transition for the CURRENT user is the only
    // unambiguous "send" case — gets the swipe button. Zero transitions
    // does NOT mean "safe to swipe" (that was the bug: a rep viewing a
    // document waiting on someone else's approval could still "swipe" and
    // get a false failure) — it means nothing is actionable right now, so
    // it either shows the read-only "already sent" pill, or nothing at all
    // if this is genuinely the very first state and hasn't been sent yet.
    // Two or more available transitions is a branching/ambiguous case the
    // app never guesses at — those get the existing per-action buttons
    // instead so the user picks explicitly.
    final docstatus = (doc['docstatus'] as num?)?.toInt() ?? 0;
    final canSend =
        docstatus == 0 && _transitions.length == 1 && !_loadingTransitions;
    final showActionChips = _transitions.length > 1;
    final canEditDocument = _canEditCurrentState;
    final isInitialState =
        _workflowStates.isNotEmpty &&
        doc['workflow_state'] == _workflowStates.first;
    final isWaitingOnSomeoneElse =
        docstatus == 0 &&
        _transitions.isEmpty &&
        !_loadingTransitions &&
        !canEditDocument &&
        !isInitialState;

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: status.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        status.label,
                        style: TextStyle(
                          color: status.color,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.midGray,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (amount != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'الإجمالي: $amount',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_buildItemsSection(doc) case final section?) section,
          if (_buildTotalsSection(doc) case final section?) section,
          if (_buildPaymentScheduleSection(doc) case final section?) section,
          if (widget.doctype == 'Sales Order' ||
              widget.doctype == 'Sales Invoice' ||
              widget.doctype == 'Customer' ||
              widget.doctype == 'Payment Entry' ||
              widget.doctype == 'Material Request') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (widget.doctype != 'Customer') ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sharingPdf ? null : _sharePdf,
                      icon: _sharingPdf
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.picture_as_pdf_rounded, size: 16),
                      label: Text(
                        _sharingPdf ? 'جاري التجهيز...' : 'مشاركة / طباعة PDF',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _attachingPhoto ? null : _capturePhotoAndAttach,
                    icon: _attachingPhoto
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.camera_alt_rounded, size: 16),
                    label: Text(
                      _attachingPhoto ? 'جاري الإرفاق...' : 'تصوير وإرفاق',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _uploadingImages ? null : _pickAndUploadImages,
              icon: _uploadingImages
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.photo_library_rounded, size: 16),
              label: Text(
                _uploadingImages ? 'جاري الرفع...' : 'رفع صور من المعرض',
              ),
            ),
          ],
          if (widget.doctype == 'Sales Invoice' &&
              docstatus == 1 &&
              ((doc['outstanding_amount'] as num?) ?? 0) > 0) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _collectingPayment ? null : _collectPayment,
              style: FilledButton.styleFrom(backgroundColor: AppColors.success),
              icon: _collectingPayment
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.white,
                      ),
                    )
                  : const Icon(Icons.payments_rounded, size: 16),
              label: Text(
                _collectingPayment
                    ? 'جاري التسجيل...'
                    : 'تحصيل دفعة (المستحق: ${doc['outstanding_amount']})',
              ),
            ),
          ],
          if (_canEditDiscount) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _editingDiscount ? null : _editDiscount,
              icon: _editingDiscount
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.percent_rounded, size: 16),
              label: Text(_editingDiscount ? 'جاري الحفظ...' : 'تعديل الخصم'),
            ),
          ],
          if (canEditDocument) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final route = switch (widget.doctype) {
                  'Sales Invoice' => '/sales-invoice',
                  'Customer' => '/customer-registration',
                  _ => '/sales-order',
                };
                await context.push(route, extra: doc);
                if (mounted) _loadDocument();
              },
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: const Text('تعديل المستند'),
            ),
          ],
          if (canSend) ...[
            const SizedBox(height: 20),
            Opacity(
              opacity: _sendingDocument ? 0.5 : 1,
              child: IgnorePointer(
                ignoring: _sendingDocument,
                child: SwipeToConfirmButton(
                  // Dynamic — whatever this specific transition's action
                  // label actually is (e.g. "إرسال للاعتماد" the first time,
                  // "إعادة إرسال للاعتماد" after a revision request), never
                  // a hardcoded "send" string.
                  label: 'اسحب لـ ${_transitions.first['action'] ?? 'الإرسال'}',
                  confirmedLabel: 'تم الإرسال',
                  onConfirmed: _sendDocument,
                ),
              ),
            ),
          ] else if (isWaitingOnSomeoneElse) ...[
            const SizedBox(height: 20),
            Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.success,
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_rounded, color: AppColors.white, size: 18),
                  SizedBox(width: 6),
                  Text(
                    'تم الإرسال',
                    style: TextStyle(
                      color: AppColors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_loadingWorkflowStates) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              ),
            ),
          ] else if (_workflowStates.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text(
              'مسار الاعتماد',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            _WorkflowStepper(
              states: _workflowStates,
              currentState: doc['workflow_state'] as String?,
              originState: _originState,
            ),
            if (_originActorName != null) ...[
              const SizedBox(height: 8),
              Text(
                'آخر إجراء بواسطة: $_originActorName',
                style: const TextStyle(
                  color: AppColors.midGray,
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
          if (_loadingTransitions) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              ),
            ),
          ] else if (showActionChips) ...[
            const SizedBox(height: 20),
            const Text(
              'الإجراء التالي',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _transitions.map((t) {
                final action = t['action']?.toString();
                if (action == null) return const SizedBox.shrink();
                return ElevatedButton(
                  onPressed: _applyingAction
                      ? null
                      : () => _applyAction(action),
                  child: Text(action),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'التعليقات',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (_loadingComments)
            const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          else if (_comments.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: const Center(
                child: Text(
                  'لا توجد تعليقات بعد',
                  style: TextStyle(color: AppColors.midGray),
                ),
              ),
            )
          else
            ..._comments.map((c) {
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            (c['comment_by'] as String?) ?? '—',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        Text(
                          _relativeTime(c['creation'] as String?),
                          style: const TextStyle(
                            color: AppColors.midGray,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      stripHtml((c['content'] as String?) ?? ''),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  /// Generic — shows up whenever `doc['items']` is a list (Sales Order/
  /// Sales Invoice today), without hardcoding which doctype it applies to.
  /// Other doctypes (Payment Entry, Expense Claim...) just don't have this
  /// key and the section stays absent, same as before.
  Widget? _buildItemsSection(Map<String, dynamic> doc) {
    final items = doc['items'];
    if (items is! List || items.isEmpty) return null;
    final rows = items
        .whereType<Map>()
        .map((i) => Map<String, dynamic>.from(i))
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'الأصناف',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          ...rows.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            final name = (item['item_name'] ?? item['item_code'] ?? '—')
                .toString();
            final qty = item['qty'];
            final rate = item['rate'];
            final amount = item['amount'];
            final discountPercentage = item['discount_percentage'] as num?;
            final itemCode = item['item_code'] as String?;
            final discountLimit = itemCode != null
                ? _itemDiscountLimits[itemCode]
                : null;
            final busy = _editingItemIndex == index;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          qty != null && rate != null
                              ? '$qty × $rate = ${amount ?? ''}'
                              : (amount?.toString() ?? '—'),
                          style: const TextStyle(
                            color: AppColors.midGray,
                            fontSize: 12,
                          ),
                        ),
                        if (discountPercentage != null &&
                            discountPercentage > 0)
                          Text(
                            'خصم الصنف: $discountPercentage%',
                            style: const TextStyle(
                              color: AppColors.accent,
                              fontSize: 11.5,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_canEditItemDiscount && discountLimit != null)
                    busy
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            onPressed: () =>
                                _editItemDiscount(index, item, discountLimit),
                            icon: const Icon(Icons.percent_rounded, size: 18),
                            color: AppColors.midGray,
                            tooltip: 'تعديل خصم الصنف',
                          ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// Generic — shows up whenever any of the standard total fields are
  /// present, regardless of doctype.
  Widget? _buildTotalsSection(Map<String, dynamic> doc) {
    final netTotal = doc['net_total'];
    final discountAmount = doc['discount_amount'];
    final discountPercent = doc['additional_discount_percentage'];
    final grandTotal = doc['grand_total'];
    if (netTotal == null && discountAmount == null && grandTotal == null)
      return null;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (netTotal != null) _totalsRow('الصافي', netTotal),
          if (discountAmount is num && discountAmount > 0)
            _totalsRow(
              (discountPercent is num && discountPercent > 0)
                  ? 'الخصم ($discountPercent%)'
                  : 'الخصم',
              discountAmount,
            ),
          if (grandTotal != null)
            _totalsRow('الإجمالي النهائي', grandTotal, bold: true),
        ],
      ),
    );
  }

  /// The real, saved `payment_schedule` child table (due dates the server
  /// itself computed on submit) — not the client-side *estimate* shown on
  /// the create screens before a document exists. Each row gets a button
  /// to drop a reminder straight into the phone's own calendar (see
  /// [CalendarService]), so the rep gets an actual notification on/near
  /// the due date without this app needing to run in the background.
  Widget? _buildPaymentScheduleSection(Map<String, dynamic> doc) {
    final schedule = doc['payment_schedule'];
    if (schedule is! List || schedule.isEmpty) return null;
    final rows = schedule
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    final customerName =
        (doc['customer_name'] ?? doc['customer'] ?? doc['party_name'] ?? '—')
            .toString();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'جدول الدفعات',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              TextButton.icon(
                onPressed: _addingAllReminders
                    ? null
                    : () => _addAllCalendarReminders(rows, customerName),
                icon: _addingAllReminders
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.event_available_rounded, size: 16),
                label: Text(_addingAllReminders ? 'جاري الإضافة...' : 'إضافة الكل للتقويم'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...rows.asMap().entries.map((entry) {
            final index = entry.key;
            final row = entry.value;
            final dueDate = row['due_date'] as String?;
            final amount =
                (row['outstanding'] as num?) ?? (row['payment_amount'] as num?);
            final busy = _addingReminderIndices.contains(index);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dueDate ?? '—',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        if (amount != null)
                          Text(
                            '${amount.toStringAsFixed(2)} ج.م',
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  busy
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          onPressed: dueDate == null || _addingAllReminders
                              ? null
                              : () => _addCalendarReminder(
                                  index,
                                  customerName,
                                  amount ?? 0,
                                  dueDate,
                                ),
                          icon: const Icon(
                            Icons.event_available_rounded,
                            size: 20,
                          ),
                          color: AppColors.accent,
                          tooltip: 'إضافة تذكير للتقويم',
                        ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _totalsRow(String label, dynamic value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: bold ? AppColors.black : AppColors.midGray,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentInput() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: _pickMention,
              icon: const Icon(Icons.alternate_email_rounded),
              color: AppColors.midGray,
              tooltip: 'منشن مستخدم',
            ),
            Expanded(
              child: TextField(
                controller: _commentController,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'اكتب تعليقًا...'),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: AppColors.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _sendingComment ? null : _sendComment,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _sendingComment
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.white,
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          color: AppColors.white,
                          size: 18,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal step-by-step approval diagram — e.g. "المندوب → مدير المنطقة
/// → مدير الحسابات → مدير الشركة" — built entirely from [states], the real,
/// ordered state list read live from this site's own `Workflow` definition
/// (see `ErpService.getWorkflowDefinition`). Assumes the states' order in
/// that definition reflects a linear progression, which is true for the
/// common single-path approval workflow this represents but won't fully
/// capture a workflow with real branches.
/// Minimal step-by-step approval progress — a filled circle per state
/// connected by a line that animates its own fill color as steps complete,
/// plus a one-time staggered fade/slide-in per step when this document
/// first loads. Deliberately understated (no extra icons/shadows/gradients)
/// per explicit request for something simple and clean.
class _WorkflowStepper extends StatelessWidget {
  const _WorkflowStepper({
    required this.states,
    required this.currentState,
    this.originState,
  });

  final List<String> states;
  final String? currentState;

  /// The real `workflow_state` value immediately before [currentState],
  /// read from this document's own `Version` audit trail
  /// (`ErpService.getPreviousWorkflowState`) — null falls back to the old
  /// "assume the previous state in the list" behavior. This is what lets
  /// the stepper draw a real branch (e.g. a manager's "طلب تعديل" sending
  /// the document back from partway through) instead of blindly marking
  /// every earlier-indexed state as done, which is wrong whenever the
  /// current state sits later in the list than states it actually skipped.
  final String? originState;

  static const _transition = Duration(milliseconds: 350);

  @override
  Widget build(BuildContext context) {
    final currentIndex = currentState == null
        ? -1
        : states.indexOf(currentState!);
    final rawOriginIndex = originState == null
        ? -1
        : states.indexOf(originState!);
    // Only trust the looked-up origin when it actually precedes the
    // current state in the list — a null/not-found/backward-jump origin
    // (e.g. a rep resubmitting from "مطلوب تعديل" back to an earlier-
    // indexed state) falls back to the safe default of "nothing beyond the
    // current state is known to be done".
    final originIndex = (rawOriginIndex >= 0 && rawOriginIndex < currentIndex)
        ? rawOriginIndex
        : currentIndex - 1;
    // True only when the actual last hop skipped over states this list
    // would otherwise show as "done" — the real bug behind states like
    // "في انتظار الحسابات" wrongly appearing completed after a "طلب
    // تعديل" sent back from "في انتظار مدير المنطقة".
    // Requires the origin to actually be BEHIND the current position in
    // the list — a backward jump (e.g. resubmitting from "مطلوب تعديل" to
    // an earlier-indexed state) isn't "done" history at all, so it gets no
    // marker here; it's simply today's current/future step, not a flagged
    // past one.
    final anomalousOriginIndex =
        (rawOriginIndex >= 0 &&
            rawOriginIndex < currentIndex &&
            rawOriginIndex != currentIndex - 1)
        ? rawOriginIndex
        : -1;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(states.length, (i) {
          final isAnomalousOrigin = i == anomalousOriginIndex;
          final isDone =
              currentIndex >= 0 && i < currentIndex && i <= originIndex;
          final isCurrent = i == currentIndex;
          final color = isAnomalousOrigin
              ? AppColors.accent
              : isDone
              ? AppColors.success
              : isCurrent
              ? AppColors.accent
              : AppColors.midGray;
          // The anomalous origin is filled (matches a "done" circle) but
          // must show a warning icon and never a green checkmark/connecting
          // line — those would falsely claim it was a normal completed step
          // instead of the one whose action actually branched the document
          // away to the current state.
          final showCheck = isDone && !isAnomalousOrigin;

          final step = TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            // Each step takes a little longer to fully appear than the one
            // before it — a soft cascading entrance since they all start
            // together but "catch up" in sequence, without needing an
            // AnimationController just for a one-time stagger.
            duration: Duration(milliseconds: 280 + i * 90),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 8),
                child: child,
              ),
            ),
            child: SizedBox(
              width: 84,
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: _transition,
                    curve: Curves.easeOut,
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: isDone || isCurrent ? color : AppColors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 2),
                    ),
                    child: AnimatedSwitcher(
                      duration: _transition,
                      child: isAnomalousOrigin
                          ? const Icon(
                              Icons.priority_high_rounded,
                              key: ValueKey('error'),
                              color: AppColors.white,
                              size: 15,
                            )
                          : showCheck
                          ? const Icon(
                              Icons.check_rounded,
                              key: ValueKey('done'),
                              color: AppColors.white,
                              size: 15,
                            )
                          : Center(
                              key: const ValueKey('num'),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: isCurrent
                                      ? AppColors.white
                                      : AppColors.midGray,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    states[i],
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: (isCurrent || isAnomalousOrigin)
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: isAnomalousOrigin
                          ? AppColors.accent
                          : isCurrent
                          ? AppColors.black
                          : AppColors.midGray,
                    ),
                  ),
                ],
              ),
            ),
          );

          if (i == states.length - 1) return step;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              step,
              AnimatedContainer(
                duration: _transition,
                curve: Curves.easeOut,
                width: 28,
                height: 2,
                margin: const EdgeInsets.only(top: 12),
                color: showCheck ? AppColors.success : AppColors.lightGray,
              ),
            ],
          );
        }),
      ),
    );
  }
}
