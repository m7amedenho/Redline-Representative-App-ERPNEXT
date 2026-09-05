import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/account_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/customer_registration_screen.dart';
import 'screens/customer_statement_screen.dart';
import 'screens/customer_visits_screen.dart';
import 'screens/customers_screen.dart';
import 'screens/document_detail_screen.dart';
import 'screens/due_invoices_screen.dart';
import 'screens/expenses_screen.dart';
import 'screens/home_screen.dart';
import 'screens/material_request_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/payment_entry_screen.dart';
import 'screens/pending_approvals_screen.dart';
import 'screens/sales_invoice_screen.dart';
import 'screens/sales_order_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/stock_movement_screen.dart';
import 'screens/sync_queue_screen.dart';
import 'screens/team_dashboard_screen.dart';
import 'screens/treasury_screen.dart';
import 'screens/treasury_statement_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/sync_engine.dart';
import 'theme/app_theme.dart';
import 'widgets/search_picker.dart';
import 'widgets/sync_status_bar.dart';

void main() {
  // Touches the singleton so it starts listening for connectivity and
  // attempts to drain any jobs left over from a previous session — before
  // `runApp`, not from inside a widget, so `flutter_test`'s `pumpWidget`
  // (which never calls this `main`) never touches it.
  SyncEngine();
  runApp(const RedErpApp());
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(path: '/auth', builder: (context, state) => const AuthScreen()),
    GoRoute(
      path: '/welcome',
      builder: (context, state) => const WelcomeScreen(),
    ),
    GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/notifications',
      builder: (context, state) => const NotificationsScreen(),
    ),
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountScreen(),
    ),
    GoRoute(
      path: '/sales-order',
      builder: (context, state) => SalesOrderScreen(
        editDoc: state.extra as Map<String, dynamic>?,
      ),
    ),
    GoRoute(
      path: '/sales-invoice',
      builder: (context, state) => SalesInvoiceScreen(
        editDoc: state.extra as Map<String, dynamic>?,
      ),
    ),
    GoRoute(
      path: '/payment-entry',
      builder: (context, state) => PaymentEntryScreen(
        presetCustomer: state.extra as PickedRecord?,
      ),
    ),
    GoRoute(
      path: '/due-invoices',
      builder: (context, state) => const DueInvoicesScreen(),
    ),
    GoRoute(
      path: '/material-request',
      builder: (context, state) => const MaterialRequestScreen(),
    ),
    GoRoute(
      path: '/customers',
      builder: (context, state) => const CustomersScreen(),
    ),
    GoRoute(
      path: '/expenses',
      builder: (context, state) => const ExpensesScreen(),
    ),
    GoRoute(
      path: '/customer-visits',
      builder: (context, state) => const CustomerVisitsScreen(),
    ),
    GoRoute(
      path: '/treasury',
      builder: (context, state) => const TreasuryScreen(),
    ),
    GoRoute(
      path: '/treasury-statement',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return TreasuryStatementScreen(
          treasuryName: extra['name'] as String,
          account: extra['account'] as String,
        );
      },
    ),
    GoRoute(
      path: '/customer-registration',
      builder: (context, state) => CustomerRegistrationScreen(
        editDoc: state.extra as Map<String, dynamic>?,
      ),
    ),
    GoRoute(
      path: '/pending-approvals',
      builder: (context, state) => const PendingApprovalsScreen(),
    ),
    GoRoute(
      path: '/stock-movement',
      builder: (context, state) => const StockMovementScreen(),
    ),
    GoRoute(
      path: '/team-dashboard',
      builder: (context, state) => const TeamDashboardScreen(),
    ),
    GoRoute(
      path: '/customer-statement/:customer',
      builder: (context, state) => CustomerStatementScreen(
        customer: state.pathParameters['customer']!,
        customerLabel:
            state.uri.queryParameters['label'] ??
            state.pathParameters['customer']!,
      ),
    ),
    GoRoute(
      path: '/document/:doctype/:name',
      builder: (context, state) => DocumentDetailScreen(
        doctype: state.pathParameters['doctype']!,
        name: state.pathParameters['name']!,
      ),
    ),
    GoRoute(
      path: '/sync-queue',
      builder: (context, state) => const SyncQueueScreen(),
    ),
  ],
);

class RedErpApp extends StatelessWidget {
  const RedErpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Red ERP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      routerConfig: _router,
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SyncStatusBar(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
