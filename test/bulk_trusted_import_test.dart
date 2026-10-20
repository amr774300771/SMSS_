import 'package:flutter_test/flutter_test.dart';

import '../lib/bulk_trusted_import.dart';

void main() {
  test('parses multiple Yemeni numbers, Arabic digits, and optional names', () {
    final result = parseTrustedImport(
      '0771234567\nأحمد | +967771234568، ٧٧١٢٣٤٥٦٩',
    );

    expect(result.valid.map((entry) => entry.phone), [
      '0771234567',
      '+967771234568',
      '771234569',
    ]);
    expect(result.valid[1].name, 'أحمد');
    expect(result.duplicates, isEmpty);
    expect(result.invalid, isEmpty);
  });

  test('separates numbers already present from invalid input', () {
    final result = parseTrustedImport(
      '0771234567, not-a-phone, 0771234567',
      existingNumbers: const {'+967771234567'},
    );

    expect(result.valid, isEmpty);
    expect(result.duplicates, ['0771234567', '0771234567']);
    expect(result.invalid, ['not-a-phone']);
  });

  test('removes duplicates within the batch and accepts international numbers',
      () {
    final result = parseTrustedImport(
      '+967771234567; +12025550123; 0771234567',
    );

    expect(result.valid.map((entry) => entry.phone), [
      '+967771234567',
      '+12025550123',
    ]);
    expect(result.duplicates, ['0771234567']);
  });
}
