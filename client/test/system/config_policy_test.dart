import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/system/config_policy.dart';

void main() {
  group('parseBrightness', () {
    test('"auto" → BrightnessAuto', () {
      expect(parseBrightness('auto'), isA<BrightnessAuto>());
    });

    test('"AUTO" with whitespace → BrightnessAuto', () {
      expect(parseBrightness('  AUTO  '), isA<BrightnessAuto>());
    });

    test('"0" → BrightnessManual(0)', () {
      expect(parseBrightness('0'), const BrightnessManual(0));
    });

    test('"50" → BrightnessManual(50)', () {
      expect(parseBrightness('50'), const BrightnessManual(50));
    });

    test('"100" → BrightnessManual(100)', () {
      expect(parseBrightness('100'), const BrightnessManual(100));
    });

    test('"150" clamps to 100', () {
      expect(parseBrightness('150'), const BrightnessManual(100));
    });

    test('"-5" clamps to 0', () {
      expect(parseBrightness('-5'), const BrightnessManual(0));
    });

    test('decimal "75.4" rounds to 75', () {
      expect(parseBrightness('75.4'), const BrightnessManual(75));
    });

    test('"abc" → safe default BrightnessAuto', () {
      expect(parseBrightness('abc'), isA<BrightnessAuto>());
    });

    test('empty string → safe default BrightnessAuto', () {
      expect(parseBrightness(''), isA<BrightnessAuto>());
    });
  });

  group('parseScreenTimeout', () {
    test('"always-on" → TimeoutAlwaysOn', () {
      expect(parseScreenTimeout('always-on'), isA<TimeoutAlwaysOn>());
    });

    test('"ALWAYS-ON" → TimeoutAlwaysOn', () {
      expect(parseScreenTimeout('ALWAYS-ON'), isA<TimeoutAlwaysOn>());
    });

    test('"30s" → 30 seconds', () {
      expect(
        parseScreenTimeout('30s'),
        const TimeoutDuration(Duration(seconds: 30)),
      );
    });

    test('"5m" → 5 minutes', () {
      expect(
        parseScreenTimeout('5m'),
        const TimeoutDuration(Duration(minutes: 5)),
      );
    });

    test('"1h" → 1 hour', () {
      expect(
        parseScreenTimeout('1h'),
        const TimeoutDuration(Duration(hours: 1)),
      );
    });

    test('bare integer "60" → 60 seconds', () {
      expect(
        parseScreenTimeout('60'),
        const TimeoutDuration(Duration(seconds: 60)),
      );
    });

    test('"abc" → safe default TimeoutAlwaysOn', () {
      expect(parseScreenTimeout('abc'), isA<TimeoutAlwaysOn>());
    });

    test('empty string → safe default TimeoutAlwaysOn', () {
      expect(parseScreenTimeout(''), isA<TimeoutAlwaysOn>());
    });
  });
}
