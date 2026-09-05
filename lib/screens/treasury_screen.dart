import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_picker.dart';

/// A treasury/cash-box the current user has access to — `Treasury` is a
/// custom DocType (app "Red App") confirmed from the site's own schema: a
/// tree structure (`lft`/`rgt`/`is_group`, like Warehouse) where each leaf
/// node links an `account`, `mode_of_payment`, `currency`, and who can use
/// it (`linked_employees`/`allowed_users` child tables). Field names below
/// are all confirmed from that schema dump — not from either OpenAPI spec,
/// since this DocType is custom to this site.
class TreasuryInfo {
  const TreasuryInfo({
    required this.name,
    required this.treasuryName,
    this.treasuryType,
    this.currency,
    this.modeOfPayment,
    this.account,
    this.isActive,
  });

  final String name;
  final String treasuryName;
  final String? treasuryType;
  final String? currency;
  final String? modeOfPayment;
  final String? account;
  final bool? isActive;
}

/// Fetches the leaf treasuries (`is_group = 0`, same convention as the
/// Warehouse picker elsewhere in the app) via the generic REST wrapper.
/// **Assumption, not confirmed**: which treasuries come back for a given
/// user depends entirely on whatever permission logic the `red_app`
/// backend applies server-side for `Treasury` (via its `allowed_users`/
/// `linked_employees` child tables) — this call doesn't filter client-side,
/// it trusts the server the same way every other list in this app does.
Future<List<TreasuryInfo>> fetchTreasuries({int limit = 50}) async {
  final list = await ErpService.getList(
    'Treasury',
    filters: const [
      ['is_group', '=', 0],
    ],
    fields: const [
      'name',
      'treasury_name',
      'treasury_type',
      'currency',
      'mode_of_payment',
      'account',
      'is_active',
    ],
    limit: limit,
  );
  return list
      .map(
        (t) => TreasuryInfo(
          name: t['name'] as String,
          treasuryName: (t['treasury_name'] as String?) ?? t['name'] as String,
          treasuryType: t['treasury_type'] as String?,
          currency: t['currency'] as String?,
          modeOfPayment: t['mode_of_payment'] as String?,
          account: t['account'] as String?,
          isActive: t['is_active'] == 1 || t['is_active'] == true,
        ),
      )
      .toList();
}

/// Lets the current user pick one of their own treasuries (cash box / bank
/// account / e-wallet — see [TreasuryInfo]) — used wherever the app records
/// money actually received (collecting a payment from a customer), so the
/// rep says explicitly which real, company-owned account it went into
/// rather than the server silently defaulting to whatever generic account
/// Frappe would otherwise pick. Returns null if the user cancels, or if
/// they have no treasuries at all (caller should fall back to submitting
/// without an explicit `mode_of_payment`/`paid_to` override in that case —
/// this is a convenience layered on top of the plain Payment Entry flow,
/// not something every one of this app's DocTypes strictly requires).
Future<TreasuryInfo?> pickTreasury(BuildContext context) async {
  final treasuries = await fetchTreasuries();
  if (treasuries.isEmpty) return null;
  if (!context.mounted) return null;

  final byName = {for (final t in treasuries) t.name: t};
  final result = await showSearchPicker(
    context: context,
    title: 'اختر الخزنة',
    hintText: 'ابحث باسم الخزنة...',
    search: (query) async => treasuries
        .where((t) => query.isEmpty || t.treasuryName.contains(query))
        .map(
          (t) => PickedRecord(
            name: t.name,
            label: t.treasuryName,
            subtitle: [
              if (t.modeOfPayment != null) t.modeOfPayment!,
              if (t.currency != null) t.currency!,
            ].join(' · '),
          ),
        )
        .toList(),
  );
  if (result == null) return null;
  return byName[result.name];
}

/// Live GL balance for each of the given treasury names — best-effort,
/// returns whatever the server was actually able to compute (silently
/// skips a name the caller lacks permission for, or the whole map if the
/// call fails entirely — a missing balance is shown as "—" by callers, not
/// as zero, so it's never mistaken for a genuine zero balance).
Future<Map<String, num>> fetchTreasuryBalances(List<String> names) async {
  if (names.isEmpty) return {};
  try {
    final result = await ErpService.callMethod(
      '/api/method/red_app.red_app.doctype.treasury.treasury.get_treasury_balances',
      params: {'names': jsonEncode(names)},
    );
    return result.map((key, value) => MapEntry(key, (value as num?) ?? 0));
  } catch (_) {
    return {};
  }
}

class TreasuryScreen extends StatefulWidget {
  const TreasuryScreen({super.key});

  @override
  State<TreasuryScreen> createState() => _TreasuryScreenState();
}

class _TreasuryScreenState extends State<TreasuryScreen> {
  List<TreasuryInfo> _treasuries = [];
  Map<String, num> _balances = {};
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
      final list = await fetchTreasuries();
      if (!mounted) return;
      setState(() => _treasuries = list);
      final balances = await fetchTreasuryBalances(
        list.map((t) => t.name).toList(),
      );
      if (mounted) setState(() => _balances = balances);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر جلب الخزائن: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('الخزنة')),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 24),
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.accent), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('حاول مرة أخرى')),
            ],
          ),
        ),
      );
    }

    if (_treasuries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'لا توجد خزائن مرتبطة بحسابك حاليًا',
            style: TextStyle(color: AppColors.midGray),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.accent,
      child: ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: _treasuries.length,
        separatorBuilder: (context, i) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _TreasuryCard(
          treasury: _treasuries[i],
          balance: _balances[_treasuries[i].name],
        ),
      ),
    );
  }
}

class _TreasuryCard extends StatelessWidget {
  const _TreasuryCard({required this.treasury, this.balance});

  final TreasuryInfo treasury;

  /// Null means "not loaded yet / failed" — shown as "—", never as 0, so
  /// it's never mistaken for a genuine zero balance.
  final num? balance;

  @override
  Widget build(BuildContext context) {
    final active = treasury.isActive ?? true;
    final account = treasury.account;
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.card),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: account == null
            ? null
            : () => context.push(
                '/treasury-statement',
                extra: {'name': treasury.treasuryName, 'account': account},
              ),
        child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.lightGray,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.account_balance_wallet_rounded, color: AppColors.black, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  treasury.treasuryName,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (treasury.treasuryType != null) treasury.treasuryType!,
                    if (treasury.modeOfPayment != null) treasury.modeOfPayment!,
                    if (treasury.currency != null) treasury.currency!,
                  ].join(' · '),
                  style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  balance != null
                      ? '${balance!.toStringAsFixed(2)} ${treasury.currency ?? ''}'
                      : '—',
                  style: const TextStyle(
                    color: AppColors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                if (treasury.account != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    treasury.account!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.midGray, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: (active ? AppColors.success : AppColors.midGray).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              active ? 'نشطة' : 'غير نشطة',
              style: TextStyle(
                color: active ? AppColors.success : AppColors.midGray,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}
