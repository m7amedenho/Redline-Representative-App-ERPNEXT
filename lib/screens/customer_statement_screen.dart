import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/cache_service.dart';
import '../services/erp_service.dart';
import '../services/pdf_builder_service.dart';
import '../theme/app_theme.dart';
import '../utils/erp_error_handling.dart';
import '../widgets/cached_at_banner.dart';
import '../widgets/loading_indicator.dart';

class _StatementRow {
  const _StatementRow({
    required this.date,
    required this.voucherType,
    required this.voucherNo,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  final String date;
  final String voucherType;
  final String voucherNo;
  final num debit;
  final num credit;
  final num balance;
}

/// Customer account statement — `GET /api/resource/GL Entry` filtered by
/// `party_type`/`party`, running balance computed client-side (debit
/// increases what the customer owes, credit decreases it — standard
/// receivable-account convention). Field names (`posting_date`, `debit`,
/// `credit`, `voucher_type`, `voucher_no`, `is_cancelled`) are standard
/// ERPNext accounting fields, NOT confirmed against this site's schema —
/// see docs/API_INTEGRATION_NOTES.md "جولة عاشرة".
///
/// Each row expands (accordion) into the linked voucher's own detail,
/// fetched lazily on first expand and cached — an invoice shows its item
/// lines/total, a payment shows the account/mode it moved through. A
/// "تصدير PDF" action builds the same statement on-device (see
/// [PdfBuilderService]), matching exactly what's on screen.
class CustomerStatementScreen extends StatefulWidget {
  const CustomerStatementScreen({
    super.key,
    required this.customer,
    required this.customerLabel,
  });

  final String customer;
  final String customerLabel;

  @override
  State<CustomerStatementScreen> createState() => _CustomerStatementScreenState();
}

class _CustomerStatementScreenState extends State<CustomerStatementScreen> {
  bool _loading = true;
  String? _error;
  List<_StatementRow> _rows = [];
  bool _exportingPdf = false;

  /// Set only when this screen's data came from [CacheService] rather than
  /// a live fetch just now — shown as a "آخر تحديث" hint so the rep never
  /// mistakes a stale offline view for a live balance.
  DateTime? _cachedAt;

  final Map<String, Map<String, dynamic>?> _detailCache = {};
  final Set<String> _loadingDetail = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await CacheService.getListCached(
        cacheDoctype: 'GL Entry_statement',
        cacheKey: widget.customer,
        fetch: () => ErpService.getList(
          'GL Entry',
          filters: [
            ['party_type', '=', 'Customer'],
            ['party', '=', widget.customer],
            ['is_cancelled', '=', 0],
          ],
          fields: const [
            'posting_date',
            'voucher_type',
            'voucher_no',
            'debit',
            'credit',
            'remarks',
          ],
          orderBy: 'posting_date asc, creation asc',
          limit: 200,
        ),
      );
      final list = result.rows;

      num balance = 0;
      final rows = <_StatementRow>[];
      for (final entry in list) {
        final debit = (entry['debit'] as num?) ?? 0;
        final credit = (entry['credit'] as num?) ?? 0;
        balance += debit - credit;
        rows.add(
          _StatementRow(
            date: (entry['posting_date'] as String?) ?? '',
            voucherType: (entry['voucher_type'] as String?) ?? '',
            voucherNo: (entry['voucher_no'] as String?) ?? '',
            debit: debit,
            credit: credit,
            balance: balance,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _cachedAt = result.fromCache ? result.cachedAt : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final message = handleErpError(context, e);
      if (message == null) return;
      setState(() {
        _error = message;
        _loading = false;
      });
    }
  }

  Future<void> _loadDetail(_StatementRow row) async {
    if (row.voucherType.isEmpty || row.voucherNo.isEmpty) return;
    final key = '${row.voucherType}|${row.voucherNo}';
    if (_detailCache.containsKey(key) || _loadingDetail.contains(key)) return;
    setState(() => _loadingDetail.add(key));
    try {
      final doc = await ErpService.getDoc(row.voucherType, row.voucherNo);
      if (!mounted) return;
      setState(() => _detailCache[key] = doc);
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailCache[key] = null);
    } finally {
      if (mounted) setState(() => _loadingDetail.remove(key));
    }
  }

  Future<void> _exportPdf() async {
    if (_exportingPdf) return;
    setState(() => _exportingPdf = true);
    try {
      final bytes = await PdfBuilderService.buildCustomerStatementPdf(
        customerLabel: widget.customerLabel,
        currentBalance: _rows.isEmpty ? 0 : _rows.last.balance,
        rows: _rows
            .map(
              (r) => {
                'date': r.date,
                'voucherType': r.voucherType,
                'voucherNo': r.voucherNo,
                'debit': r.debit,
                'credit': r.credit,
                'balance': r.balance,
              },
            )
            .toList(),
      );
      if (!mounted) return;
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'كشف حساب - ${widget.customerLabel}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إنشاء ملف PDF: $e')));
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Text('كشف حساب — ${widget.customerLabel}'),
        actions: [
          if (_rows.isNotEmpty)
            IconButton(
              onPressed: _exportingPdf ? null : _exportPdf,
              icon: _exportingPdf
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf_rounded),
              tooltip: 'تصدير PDF',
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingIndicator();
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.accent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_rows.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد حركات مالية مسجلة لهذا العميل',
          style: TextStyle(color: AppColors.midGray),
        ),
      );
    }

    final currentBalance = _rows.last.balance;

    final cachedAt = _cachedAt;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (cachedAt != null) CachedAtBanner(cachedAt: cachedAt),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.black, Color(0xFF2A2A2A)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'المديونية الحالية',
                style: TextStyle(color: AppColors.midGray, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              Text(
                '${currentBalance.toStringAsFixed(2)} ج.م',
                style: const TextStyle(
                  color: AppColors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ..._rows.map(_buildRow),
      ],
    );
  }

  Widget _buildRow(_StatementRow row) {
    final key = '${row.voucherType}|${row.voucherNo}';
    final expandable = row.voucherType.isNotEmpty && row.voucherNo.isNotEmpty;

    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.voucherType.isEmpty
                    ? row.date
                    : '${row.voucherType} ${row.voucherNo}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                row.date,
                style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (row.debit > 0)
              Text(
                '+${row.debit.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            if (row.credit > 0)
              Text(
                '-${row.credit.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: AppColors.success,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            const SizedBox(height: 2),
            Text(
              'الرصيد: ${row.balance.toStringAsFixed(2)}',
              style: const TextStyle(color: AppColors.midGray, fontSize: 11),
            ),
          ],
        ),
      ],
    );

    final container = Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: !expandable
          ? Padding(padding: const EdgeInsets.all(14), child: header)
          : Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                title: header,
                onExpansionChanged: (open) {
                  if (open) _loadDetail(row);
                },
                children: [_buildDetail(key, row)],
              ),
            ),
    );

    return container;
  }

  Widget _buildDetail(String key, _StatementRow row) {
    if (_loadingDetail.contains(key)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final doc = _detailCache[key];
    if (!_detailCache.containsKey(key) || doc == null) {
      return const Text(
        'تعذر تحميل تفاصيل هذا المستند',
        style: TextStyle(color: AppColors.midGray, fontSize: 12),
      );
    }

    final items = doc['items'];
    if (items is List && items.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          ...items.whereType<Map>().map((item) {
            final name = (item['item_name'] ?? item['item_code'] ?? '—').toString();
            final qty = item['qty'];
            final rate = item['rate'];
            final amount = item['amount'];
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  Text(
                    qty != null && rate != null
                        ? '$qty × $rate = ${amount ?? ''}'
                        : (amount?.toString() ?? '—'),
                    style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
                  ),
                ],
              ),
            );
          }),
          if (doc['grand_total'] != null) ...[
            const SizedBox(height: 6),
            Text(
              'الإجمالي: ${doc['grand_total']}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ],
        ],
      );
    }

    // Payment Entry أو أي مستند تاني مالوش جدول أصناف — نعرض معلومات الدفع.
    final paidAmount = doc['paid_amount'] ?? doc['received_amount'];
    final modeOfPayment = doc['mode_of_payment'];
    final account = doc['paid_to'] ?? doc['bank_or_cash_account'];
    final hasPaymentInfo = paidAmount != null || modeOfPayment != null || account != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 8),
        if (!hasPaymentInfo)
          const Text(
            'لا تفاصيل إضافية لهذا المستند',
            style: TextStyle(color: AppColors.midGray, fontSize: 12),
          )
        else ...[
          if (paidAmount != null)
            Text('المبلغ: $paidAmount', style: const TextStyle(fontSize: 12.5)),
          if (modeOfPayment != null)
            Text(
              'طريقة الدفع: $modeOfPayment',
              style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
            ),
          if (account != null)
            Text(
              'الحساب: $account',
              style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
            ),
        ],
      ],
    );
  }
}
