import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/window_size.dart';

void main() {
  group('windowSizeFromWidth', () {
    test('0dp -> compact', () {
      expect(windowSizeFromWidth(0), WindowSizeClass.compact);
    });

    test('599dp -> compact', () {
      expect(windowSizeFromWidth(599), WindowSizeClass.compact);
    });

    test('600dp -> medium', () {
      expect(windowSizeFromWidth(600), WindowSizeClass.medium);
    });

    test('839dp -> medium', () {
      expect(windowSizeFromWidth(839), WindowSizeClass.medium);
    });

    test('840dp -> expanded', () {
      expect(windowSizeFromWidth(840), WindowSizeClass.expanded);
    });
  });
}
