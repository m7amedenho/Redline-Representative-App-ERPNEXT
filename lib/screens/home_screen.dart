import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/auth_service.dart';
import '../services/erp_service.dart';
import '../theme/app_theme.dart';
import 'document_detail_screen.dart';
import 'treasury_screen.dart';

class _QuickAction {
  const _QuickAction(this.icon, this.label, {this.route});

  final IconData icon;
  final String label;

  /// Null means "not built yet" — tapping shows the coming-soon SnackBar.
  final String? route;
}

/// Single flat grid, 3 icons per row — the user explicitly rejected the
/// categorized/sectioned layout tried in Round 10.
const _quickActions = [
  _QuickAction(
    Icons.add_shopping_cart_rounded,
    'طلبية مبيعات',
    route: '/sales-order',
  ),
  _QuickAction(
    Icons.receipt_long_rounded,
    'إصدار فاتورة',
    route: '/sales-invoice',
  ),
  _QuickAction(
    Icons.payments_rounded,
    'تحصيل من عميل',
    route: '/payment-entry',
  ),
  _QuickAction(Icons.groups_rounded, 'إدارة العملاء', route: '/customers'),
  _QuickAction(
    Icons.event_note_rounded,
    'فواتير المستحقات',
    route: '/due-invoices',
  ),
  _QuickAction(
    Icons.add_location_alt_rounded,
    'تسجيل زيارة',
    route: '/customer-visits',
  ),
  _QuickAction(
    Icons.person_add_rounded,
    'تسجيل عميل جديد',
    route: '/customer-registration',
  ),
  _QuickAction(
    Icons.local_shipping_rounded,
    'طلب مواد',
    route: '/material-request',
  ),
  _QuickAction(Icons.wallet_rounded, 'تسجيل مصروف', route: '/expenses'),
  _QuickAction(
    Icons.account_balance_wallet_rounded,
    'الخزنة',
    route: '/treasury',
  ),
  _QuickAction(
    Icons.fact_check_rounded,
    'بانتظار موافقتي',
    route: '/pending-approvals',
  ),
  _QuickAction(
    Icons.history_rounded,
    'حركة المخزون',
    route: '/stock-movement',
  ),
];

/// Shown instead of [_quickActions] for a `WF - Region Manager` — a
/// manager doesn't create orders/invoices/customers themselves, so those
/// rep-only entry points would just be clutter for them. Everything here
/// already works for them today with zero extra code (see
/// `document_detail_screen.dart`'s dynamic `get_transitions`-driven
/// approve/reject buttons) — this list is purely about which entry points
/// make sense to surface, not new functionality.
const _managerQuickActions = [
  _QuickAction(Icons.groups_rounded, 'لوحة فريقي', route: '/team-dashboard'),
  _QuickAction(
    Icons.event_note_rounded,
    'فواتير المستحقات',
    route: '/due-invoices',
  ),
  _QuickAction(
    Icons.fact_check_rounded,
    'بانتظار موافقتي',
    route: '/pending-approvals',
  ),
  _QuickAction(
    Icons.history_rounded,
    'حركة المخزون',
    route: '/stock-movement',
  ),
  _QuickAction(
    Icons.account_balance_wallet_rounded,
    'الخزنة',
    route: '/treasury',
  ),
];

class _Activity {
  const _Activity({
    required this.doctype,
    required this.name,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.creation,
  });

  final String doctype;
  final String name;
  final IconData icon;
  final String title;
  final String subtitle;
  final String amount;
  final DateTime? creation;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _navIndex = 0;
  int _unreadNotifications = 0;

  // Default text stays if `/me` fails or doesn't return a usable name —
  // this is cosmetic, not a blocking failure. Response shape is unconfirmed,
  // see docs/API_INTEGRATION_NOTES.md.
  String _displayName = 'أهلًا،  ...';

  List<_Activity> _activities = [];
  bool _loadingActivities = true;

  List<TreasuryInfo> _treasuries = [];
  Map<String, num> _treasuryBalances = {};
  bool _loadingTreasuries = true;

  bool _isRegionManager = false;
  bool _resolvingRole = true;

  ({num? targetAmount, num achievedAmount})? _performance;
  bool _loadingPerformance = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadUnreadNotifications();
    _loadRecentActivities();
    _loadTreasuries();
    _loadRole();
    _loadPerformance();
  }

  /// A region manager gets a different home screen entirely (team-focused
  /// quick actions instead of a rep's data-entry ones) — see
  /// [_buildQuickActions]. `WF - Region Manager` is the same real role
  /// already used to gate approval actions generically everywhere else in
  /// this app; nothing new to define here, just read it.
  Future<void> _loadRole() async {
    try {
      final roles = await AuthService.currentUserRoles();
      if (!mounted) return;
      setState(() {
        _isRegionManager = roles.contains('WF - Region Manager');
        _resolvingRole = false;
      });
    } catch (_) {
      if (mounted) setState(() => _resolvingRole = false);
    }
  }

  /// This month's target vs. achieved for the current rep — a manager
  /// doesn't get this card (they get a whole team dashboard instead), see
  /// [_buildPerformanceCard].
  Future<void> _loadPerformance() async {
    try {
      final salesPerson = await ErpService.resolveCurrentSalesPerson();
      if (salesPerson == null) {
        if (mounted) setState(() => _loadingPerformance = false);
        return;
      }
      final result = await ErpService.getMonthPerformanceForSalesPerson(
        salesPerson,
      );
      if (!mounted) return;
      setState(() {
        _performance = result;
        _loadingPerformance = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPerformance = false);
    }
  }

  Future<void> _loadTreasuries() async {
    setState(() => _loadingTreasuries = true);
    try {
      final list = await fetchTreasuries(limit: 6);
      if (!mounted) return;
      setState(() => _treasuries = list);
      final balances = await fetchTreasuryBalances(
        list.map((t) => t.name).toList(),
      );
      if (mounted) setState(() => _treasuryBalances = balances);
    } catch (_) {
      // Silent — the section just shows its empty state, see _buildTreasurySection.
    } finally {
      if (mounted) setState(() => _loadingTreasuries = false);
    }
  }

  /// Pulls the rep's most recent documents across the three doctypes this
  /// app actually creates (Sales Invoice/Payment Entry/Sales Order),
  /// merges them by creation time, and shows the newest few — real data
  /// instead of a hardcoded feed. There's no dedicated "activity feed"
  /// endpoint, so this is assembled client-side from doctypes already used
  /// elsewhere in the app; the server's own permission engine still decides
  /// which documents this user can see (same as everywhere else in the app).
  Future<void> _loadRecentActivities() async {
    setState(() => _loadingActivities = true);

    final results = await Future.wait([
      _fetchActivitySource(
        doctype: 'Sales Invoice',
        icon: Icons.receipt_long_rounded,
        title: 'فاتورة جديدة',
        subtitleFields: const ['customer_name', 'customer'],
        amountField: 'grand_total',
      ),
      _fetchActivitySource(
        doctype: 'Payment Entry',
        icon: Icons.payments_rounded,
        title: 'تحصيل من عميل',
        subtitleFields: const ['party_name', 'party'],
        amountField: 'paid_amount',
      ),
      _fetchActivitySource(
        doctype: 'Sales Order',
        icon: Icons.local_shipping_rounded,
        title: 'طلبية جديدة',
        subtitleFields: const ['customer_name', 'customer'],
        amountField: 'grand_total',
      ),
    ]);

    final combined = results.expand((r) => r).toList()
      ..sort(
        (a, b) =>
            (b.creation ?? DateTime(0)).compareTo(a.creation ?? DateTime(0)),
      );

    if (!mounted) return;
    setState(() {
      _activities = combined.take(6).toList();
      _loadingActivities = false;
    });
  }

  Future<List<_Activity>> _fetchActivitySource({
    required String doctype,
    required IconData icon,
    required String title,
    required List<String> subtitleFields,
    required String amountField,
  }) async {
    try {
      final list = await ErpService.getList(
        doctype,
        fields: ['name', ...subtitleFields, amountField, 'creation'],
        orderBy: 'creation desc',
        limit: 5,
      );
      return list.map((d) {
        final amount = d[amountField];
        String subtitle = doctype;
        for (final field in subtitleFields) {
          final value = d[field] as String?;
          if (value != null && value.isNotEmpty) {
            subtitle = value;
            break;
          }
        }
        return _Activity(
          doctype: doctype,
          name: d['name'] as String,
          icon: icon,
          title: title,
          subtitle: subtitle,
          amount: amount != null ? '$amount ج.م' : '—',
          creation: DateTime.tryParse((d['creation'] as String?) ?? ''),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  String _relativeTime(DateTime? time) {
    if (time == null) return '';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays < 7) return 'منذ ${diff.inDays} يوم';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadUnreadNotifications() async {
    try {
      final unread = await ErpService.getList(
        'Notification Log',
        filters: const [
          ['read', '=', 0],
        ],
        fields: const ['name'],
        limit: 100,
      );
      if (!mounted) return;
      setState(() => _unreadNotifications = unread.length);
    } catch (_) {
      // Silent — cosmetic badge only, see _loadProfile above.
    }
  }

  Future<void> _loadProfile() async {
    try {
      final me = await AuthService.me();
      final fullName =
          me['full_name'] ??
          me['user_full_name'] ??
          (me['first_name'] != null
              ? '${me['first_name']} ${me['last_name'] ?? ''}'.trim()
              : null);
      if (!mounted || fullName == null) return;
      final name = fullName.toString().trim();
      if (name.isEmpty) return;
      setState(() => _displayName = 'أهلًا، $name');
    } catch (_) {
      // Silent — cosmetic only, see comment above.
    }
  }

  Future<void> _openNotifications() async {
    await context.push('/notifications');
    if (!mounted) return;
    setState(() => _unreadNotifications = 0);
  }

  Future<void> _openAccount() async {
    await context.push('/account');
  }

  void _showComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('هذه الشاشة قيد التطوير حاليًا')),
    );
  }

  void _openActivity(_Activity activity) {
    context.push(documentDetailRoute(activity.doctype, activity.name));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            _buildTreasurySection(),
            const SizedBox(height: 24),
            _buildSectionTitle('إجراءات سريعة'),
            const SizedBox(height: 12),
            _resolvingRole
                ? const SizedBox(
                    height: 80,
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : _buildQuickActions(),
            if (!_isRegionManager) ...[
              const SizedBox(height: 24),
              _buildPerformanceCard(),
            ],
            const SizedBox(height: 24),
            _buildSectionTitle('آخر النشاطات'),
            const SizedBox(height: 12),
            _buildRecentActivities(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _navIndex,
        onTap: (i) {
          if (i == 0) {
            setState(() => _navIndex = 0);
          } else if (i == 2) {
            context.push('/treasury');
          } else if (i == 3) {
            _openNotifications();
          } else if (i == 4) {
            _openAccount();
          } else {
            _showComingSoon();
          }
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'الرئيسية',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_rounded),
            label: 'الطلبيات',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_rounded),
            label: 'الخزنة',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications_rounded),
            label: 'الإشعارات',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'الحساب',
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
            color: AppColors.black,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.person_rounded,
            color: AppColors.white,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _displayName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.black,
                ),
              ),
            ],
          ),
        ),
        Semantics(
          label: _unreadNotifications > 0
              ? 'الإشعارات، $_unreadNotifications غير مقروءة'
              : 'الإشعارات',
          button: true,
          child: Material(
            color: AppColors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _openNotifications,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    const Icon(
                      Icons.notifications_none_rounded,
                      color: AppColors.black,
                    ),
                    if (_unreadNotifications > 0)
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$_unreadNotifications',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Real replacement for the old "قريبًا" placeholder — a horizontal
  /// carousel of the treasuries this account actually has, via `Treasury`
  /// (see treasury_screen.dart for the confirmed field names). Which
  /// treasuries come back is entirely up to the server's own permission
  /// logic for this DocType; this just displays whatever it returns.
  Widget _buildTreasurySection() {
    if (_loadingTreasuries) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }

    if (_treasuries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              color: AppColors.midGray,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'لا توجد خزائن مرتبطة بحسابك حاليًا',
                style: TextStyle(color: AppColors.midGray, fontSize: 12.5),
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _treasuries.length,
        separatorBuilder: (context, i) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final treasury = _treasuries[i];
          return GestureDetector(
            onTap: () => treasury.account == null
                ? context.push('/treasury')
                : context.push(
                    '/treasury-statement',
                    extra: {
                      'name': treasury.treasuryName,
                      'account': treasury.account,
                    },
                  ),
            child: Container(
              width: 220,
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Icon(
                        Icons.account_balance_wallet_rounded,
                        color: AppColors.white,
                        size: 22,
                      ),
                      Builder(
                        builder: (context) {
                          final balance = _treasuryBalances[treasury.name];
                          return Text(
                            balance != null
                                ? balance.toStringAsFixed(0)
                                : '—',
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        treasury.treasuryName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (treasury.treasuryType != null)
                            treasury.treasuryType!,
                          if (treasury.currency != null) treasury.currency!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.midGray,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: AppColors.black,
      ),
    );
  }

  Widget _buildQuickActions() {
    final actions = _isRegionManager ? _managerQuickActions : _quickActions;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: actions.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemBuilder: (context, i) {
        final action = actions[i];
        return Semantics(
          button: true,
          label: action.label,
          child: ExcludeSemantics(
            child: Column(
              children: [
                Material(
                  color: AppColors.white,
                  shape: const CircleBorder(),
                  elevation: 1,
                  shadowColor: Colors.black.withValues(alpha: 0.06),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => action.route == null
                        ? _showComingSoon()
                        : context.push(action.route!),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Icon(
                        action.icon,
                        color: AppColors.accent,
                        size: 24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  action.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.black,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Real target-vs-achieved for this calendar month — see
  /// [ErpService.getMonthPerformanceForSalesPerson] for exactly how each
  /// number is derived (and why a missing target shows as its own state,
  /// never a misleading 0/0).
  Widget _buildPerformanceCard() {
    if (_loadingPerformance) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
          ),
        ),
      );
    }

    final performance = _performance;
    if (performance == null) return const SizedBox.shrink();

    final achieved = performance.achievedAmount;
    final target = performance.targetAmount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'أدائي هذا الشهر',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 10),
          if (target == null) ...[
            Text(
              'لا يوجد هدف محدد لهذا الشهر — المحقق: ${achieved.toStringAsFixed(0)} ج.م',
              style: const TextStyle(color: AppColors.midGray, fontSize: 12.5),
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${achieved.toStringAsFixed(0)} ج.م',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                Text(
                  'الهدف: ${target.toStringAsFixed(0)} ج.م',
                  style: const TextStyle(color: AppColors.midGray, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: target > 0 ? (achieved / target).clamp(0, 1) : 0,
                minHeight: 8,
                backgroundColor: AppColors.lightGray,
                color: achieved >= target ? AppColors.success : AppColors.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecentActivities() {
    if (_loadingActivities) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }

    if (_activities.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: const Center(
          child: Text(
            'لا توجد نشاطات حديثة',
            style: TextStyle(color: AppColors.midGray),
          ),
        ),
      );
    }

    return Column(
      children: _activities.map((activity) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
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
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: () => _openActivity(activity),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        activity.icon,
                        color: AppColors.black,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            activity.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            activity.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.midGray,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          activity.amount,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _relativeTime(activity.creation),
                          style: const TextStyle(
                            color: AppColors.midGray,
                            fontSize: 11,
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
      }).toList(),
    );
  }
}
