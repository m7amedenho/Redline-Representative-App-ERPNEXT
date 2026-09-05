// Basic smoke test: the app boots into the Splash screen and its intro
// animation morphs from the logo into the "مرحباً" greeting.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:red_erp/main.dart';
import 'package:red_erp/services/sync_status_service.dart';
import 'package:red_erp/widgets/app_logo.dart';

void main() {
  testWidgets('Splash screen reveals the logo then the greeting', (
    WidgetTester tester,
  ) async {
    // The real `RedErpApp` mounts the always-on `SyncStatusBar`, which
    // would otherwise start a real connectivity_plus subscription/network
    // ping — neither tears down within a single testWidgets body. See
    // `SyncStatusService.disableBackgroundWorkForTests`.
    SyncStatusService.disableBackgroundWorkForTests = true;
    await tester.pumpWidget(const RedErpApp());

    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.text('مرحباً'), findsOneWidget);

    // Run the intro animation and the post-delay navigation check to
    // completion so no timer/controller is left pending at teardown.
    // Pumped in stages since each `await` boundary in _runIntro schedules
    // its next timer only once the previous one fires.
    await tester.pump(const Duration(milliseconds: 2700));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Swap the tree out so `SyncStatusBar` unmounts and its
    // `SyncStatusService` listener detaches — that's what stops its
    // connectivity subscription/fallback timer, so nothing is left
    // pending at teardown.
    await tester.pumpWidget(const SizedBox());
  });
}
