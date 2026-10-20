import 'package:cardbot_qaidi/whatsapp_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeWhatsAppNumber', () {
    test('adds Yemen country code to local mobile numbers', () {
      expect(normalizeWhatsAppNumber('777 123 456'), '967777123456');
      expect(normalizeWhatsAppNumber('0777-123-456'), '967777123456');
      expect(normalizeWhatsAppNumber('٠٧٧٧١٢٣٤٥٦'), '967777123456');
    });

    test('preserves an explicit international number', () {
      expect(normalizeWhatsAppNumber('+967 777 123 456'), '967777123456');
      expect(normalizeWhatsAppNumber('00967777123456'), '967777123456');
      expect(normalizeWhatsAppNumber('+966 55 123 4567'), '966551234567');
    });

    test('rejects ambiguous or malformed local numbers', () {
      expect(normalizeWhatsAppNumber('1234567'), isNull);
      expect(normalizeWhatsAppNumber('0551234567'), isNull);
      expect(normalizeWhatsAppNumber(''), isNull);
    });
  });
}
