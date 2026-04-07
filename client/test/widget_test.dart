// Basic smoke test for the M0 Hyacinth client.

import 'package:flutter_test/flutter_test.dart';

import 'package:hyacinth/main.dart';

void main() {
  testWidgets('App renders and shows initial loading state',
      (WidgetTester tester) async {
    await tester.pumpWidget(const HyacinthApp());

    expect(find.text('Hyacinth M0'), findsOneWidget);
    expect(find.text('loading...'), findsOneWidget);
  });
}
