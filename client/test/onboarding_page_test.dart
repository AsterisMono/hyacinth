// Widget test for the onboarding wizard. Verifies the first step renders
// with its explainer copy and a Continue button. A deeper step-by-step test
// is deferred because later steps fire real permission requests via the
// plugin channel, which isn't wired up in the Flutter test binding.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/app_state.dart';
import 'package:hyacinth/onboarding/onboarding_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the explain step first', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(home: OnboardingPage(appState: state)),
    );
    await tester.pump();

    expect(find.text('Welcome to Hyacinth'), findsOneWidget);
    expect(
      find.textContaining('Always-on display for your Ita-Bag'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    state.dispose();
  });
}
