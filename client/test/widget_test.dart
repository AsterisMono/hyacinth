// Unit tests for the Hyacinth config model.
//
// The M0 widget smoke test fired a real http.get against 10.0.2.2; that's been
// replaced here with a hermetic test of HyacinthConfig.fromJson, which is the
// load-bearing piece of M1 logic that's safe to test without a binding.

import 'package:flutter_test/flutter_test.dart';

import 'package:hyacinth/config/config_model.dart';

void main() {
  group('HyacinthConfig.fromJson', () {
    test('parses a complete payload', () {
      final config = HyacinthConfig.fromJson(<String, dynamic>{
        'content': 'https://example.com',
        'contentRevision': 'abc123',
        'brightness': 'auto',
        'screenTimeout': 'always-on',
      });

      expect(config.content, 'https://example.com');
      expect(config.contentRevision, 'abc123');
      expect(config.brightness, 'auto');
      expect(config.screenTimeout, 'always-on');
    });

    test('falls back to defaults for missing fields', () {
      final config = HyacinthConfig.fromJson(<String, dynamic>{});

      expect(config.content, '');
      expect(config.contentRevision, '');
      expect(config.brightness, 'auto');
      expect(config.screenTimeout, 'always-on');
    });

    test('value equality holds', () {
      final a = HyacinthConfig.fromJson(<String, dynamic>{
        'content': 'https://example.com',
        'contentRevision': 'r1',
        'brightness': 'auto',
        'screenTimeout': 'always-on',
      });
      final b = HyacinthConfig.fromJson(<String, dynamic>{
        'content': 'https://example.com',
        'contentRevision': 'r1',
        'brightness': 'auto',
        'screenTimeout': 'always-on',
      });
      final c = HyacinthConfig.fromJson(<String, dynamic>{
        'content': 'https://other.example.com',
        'contentRevision': 'r1',
        'brightness': 'auto',
        'screenTimeout': 'always-on',
      });

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('HyacinthConfig invariants', () {
    const a = HyacinthConfig(
      content: 'https://example.com',
      contentRevision: 'r1',
      brightness: 'auto',
      screenTimeout: 'always-on',
    );

    test('==/hashCode reflexivity', () {
      expect(a, equals(a));
      expect(a.hashCode, equals(a.hashCode));
    });

    test('different contentRevision => not equal', () {
      const b = HyacinthConfig(
        content: 'https://example.com',
        contentRevision: 'r2',
        brightness: 'auto',
        screenTimeout: 'always-on',
      );
      expect(a, isNot(equals(b)));
    });

    test('partial JSON missing brightness falls back to default', () {
      final cfg = HyacinthConfig.fromJson(<String, dynamic>{
        'content': 'https://example.com',
        'contentRevision': 'r1',
        'screenTimeout': 'always-on',
      });
      expect(cfg.brightness, 'auto');
    });

    test('toString is non-empty and contains the fields', () {
      final s = a.toString();
      expect(s, isNotEmpty);
      expect(s, contains('https://example.com'));
      expect(s, contains('r1'));
    });
  });
}
