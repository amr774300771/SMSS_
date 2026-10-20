import 'package:flutter_test/flutter_test.dart';
import 'package:cardbot_qaidi/phone_normalizer.dart';

void main() {
  group('normalizeYemeniPhone', () {
    test('normalizes Arabic-Indic and Eastern Arabic-Indic digits', () {
      expect(normalizeYemeniPhone('٧٧١٢٣٤٥٦٧'), '771234567');
      expect(normalizeYemeniPhone('۷۷۱۲۳۴۵۶۷'), '771234567');
    });

    test('normalizes local and international Yemen prefixes consistently', () {
      expect(normalizeYemeniPhone('0771234567'), '771234567');
      expect(normalizeYemeniPhone('+967 771 234 567'), '771234567');
      expect(normalizeYemeniPhone('00967-771-234-567'), '771234567');
    });

    test('does not let blank or non-numeric input match other blank values', () {
      expect(normalizeYemeniPhone(''), isEmpty);
      expect(normalizeYemeniPhone('---'), isEmpty);
    });

    test('strips punctuation while retaining the last ten digits for long values', () {
      expect(normalizeYemeniPhone('(967) 771-234-567'), '771234567');
    });
  });
}
