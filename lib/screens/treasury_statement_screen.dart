import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_indicator.dart';
import 'document_detail_screen.dart';

class _LedgerRow {
  const _LedgerRow({
    required this.postingDate,
    required this.voucherType,
    required this.voucherNo,
    required this.debit,
    required this.credit,
    required this.runningBalance,
    this.against,
    this.remarks,
  });

  final String postingDate;
  final String voucherType;
  final String voucherNo;
  final num debit;
  final num credit;
  final num runningBalance;
  final String? against;
  final String? remarks;
}

/// Full statement (كشف حساب) for one Treasury — every real GL Entry
/// posted against its linked `account`, oldest first, with a running
/// balance computed the standard way for an asset/cash account (balance
/// increases with debit, decreases with credit — the same convention
/// `erpnext.accounts.utils.get_balance_on` uses server-side, just derived
/// here from the same real entries instead of a single opaque number, so
/// the rep can see exactly what made up the balance).
class TreasuryStatementScreen extends StatefulWidget {
  const TreasuryStatementScreen({
    super.key,
    required this.treasuryName,
    required this.account,
  });

  final String treasuryName;
  final String account;

  @override
  State<TreasuryStatementScreen> createState() =>
      _TreasuryStatementScreenState();
}

class _TreasuryStatementScreenState extends State<TreasuryStatementScreen> {
  List<_LedgerRow> _rows = [];
  bool _loading = true;
  String? _error;

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
      final entries = await ErpService.getList(
        'GL Entry',
        filters: [
          ['account', '=', widget.account],
          ['is_cancelled', '=', 0],
        ],
        fields: const [
          'posting_date',
          'voucher_type',
          'voucher_no',
          'debit',
          'credit',
          'against',
          'remarks',
        ],
        orderBy: 'posting_date asc, creation asc',
        limit: 500,
      );

      num running = 0;
      final rows = <_LedgerRow>[];
      for (final entry in entries) {
        final debit = (entry['debit'] as num?) ?? 0;
        final credit = (entry['credit'] as num?) ?? 0;
        running += debit - credit;
        rows.add(
          _LedgerRow(
            postingDate: (entry['posting_date'] as String?) ?? '—',
            voucherType: (entry['voucher_type'] as String?) ?? '—',
            voucherNo: (entry['voucher_no'] as String?) ?? '—',
            debit: debit,
            credit: credit,
            runningBalance: running,
            against: entry['against'] as String?,
            remarks: entry['remarks'] as String?,
          ),
        );
      }

      if (!mounted) return;
      // Newest first for display — computed the running balance oldest-
      // first above (so each row's balance is correct), then flip once.
      setState(() => _rows = rows.reversed.toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر جلب كشف الحساب: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentBalance = _rows.isNotEmpty ? _rows.first.runningBalance : 0;
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: Text('كشف حساب — ${widget.treasuryName}')),
      body: SafeArea(
        child: _loading
            ? const LoadingIndicator()
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        style: const TextStyle(color: AppColors.accent),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      TextButton(onPressed: _load, child: const Text('حاول مرة أخرى')),
                    ],
                  ),
                ),
              )
            : RefreshIndicator(
                color: AppColors.accent,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: AppColors.black,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'الرصيد الحالي',
                            style: TextStyle(color: AppColors.white, fontSize: 12.5),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            currentBalance.toStringAsFixed(2),
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_rows.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.white,
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        child: const Center(
                          child: Text(
                            'لا توجد حركات مسجّلة على هذه الخزنة حتى الآن',
                            style: TextStyle(color: AppColors.midGray),
                          ),
                        ),
                      )
                    else
                      ..._rows.map((row) {
                        final isIn = row.debit > 0;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: AppColors.white,
                            borderRadius: BorderRadius.circular(AppRadius.card),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(AppRadius.card),
                              onTap: row.voucherType == '—'
                                  ? null
                                  : () => context.push(
                                      documentDetailRoute(
                                        row.voucherType,
                                        row.voucherNo,
                                      ),
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: (isIn ? AppColors.success : AppColors.accent)
                                            .withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        isIn
                                            ? Icons.arrow_downward_rounded
                                            : Icons.arrow_upward_rounded,
                                        size: 18,
                                        color: isIn ? AppColors.success : AppColors.accent,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${row.voucherType} — ${row.voucherNo}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                            ),
                                          ),
                                          if ((row.against ?? row.remarks) != null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              (row.against ?? row.remarks)!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: AppColors.midGray,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 2),
                                          Text(
                                            row.postingDate,
                                            style: const TextStyle(
                                              color: AppColors.midGray,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${isIn ? '+' : '-'}${(isIn ? row.debit : row.credit).toStringAsFixed(2)}',
                                          style: TextStyle(
                                            color: isIn
                                                ? AppColors.success
                                                : AppColors.accent,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'الرصيد: ${row.runningBalance.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: AppColors.midGray,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }
}
