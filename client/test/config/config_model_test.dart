// Tests for HyacinthConfig — equality (the M3 diff guard's foundation),
// JSON parsing of the union-typed fields, and copyWith.

import 'package:flutter_test/flutter_test.dart';
import 'package:hyacinth/config/config_model.dart';

void main() {
  const sample = HyacinthConfig(
    content: 'https://x.example/',
    contentRevision: 'r1',
    brightness: 'auto',
    screenTimeout: 'always-on',
  );

  test('equality: identical fields are ==', () {
    expect(
      sample ==
          const HyacinthConfig(
            content: 'https://x.example/',
            contentRevision: 'r1',
            brightness: 'auto',
            screenTimeout: 'always-on',
          ),
      isTrue,
    );
  });

  test('equality: any field difference breaks ==', () {
    expect(sample == sample.copyWith(content: 'https://y.example/'), isFalse);
    expect(sample == sample.copyWith(contentRevision: 'r2'), isFalse);
    expect(sample == sample.copyWith(brightness: '40'), isFalse);
    expect(sample == sample.copyWith(screenTimeout: '30s'), isFalse);
  });

  test('hashCode is consistent with ==', () {
    expect(
      sample.hashCode,
      const HyacinthConfig(
        content: 'https://x.example/',
        contentRevision: 'r1',
        brightness: 'auto',
        screenTimeout: 'always-on',
      ).hashCode,
    );
  });

  test('copyWith only overrides named fields', () {
    final c = sample.copyWith(brightness: '50');
    expect(c.brightness, '50');
    expect(c.content, sample.content);
    expect(c.contentRevision, sample.contentRevision);
    expect(c.screenTimeout, sample.screenTimeout);
  });

  test('fromJson handles numeric brightness from server', () {
    final cfg = HyacinthConfig.fromJson(<String, dynamic>{
      'content': 'https://x.example/',
      'contentRevision': 'r1',
      'brightness': 42,
      'screenTimeout': 'always-on',
    });
    expect(cfg.brightness, '42');
  });

  test('fromJson handles string brightness "auto"', () {
    final cfg = HyacinthConfig.fromJson(<String, dynamic>{
      'content': 'https://x.example/',
      'contentRevision': 'r1',
      'brightness': 'auto',
      'screenTimeout': '30s',
    });
    expect(cfg.brightness, 'auto');
    expect(cfg.screenTimeout, '30s');
  });
}
