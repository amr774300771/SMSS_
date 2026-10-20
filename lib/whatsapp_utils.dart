/// Normalizes a phone number for WhatsApp's canonical wa.me URL.
/// International numbers must include + or 00 (or already start with Yemen's
/// 967 country code). Unprefixed Yemeni mobile numbers are assumed local.
String? normalizeWhatsAppNumber(String raw) {
  final ascii = String.fromCharCodes(raw.trim().runes.map((rune) {
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
    return rune;
  }));
  final digits = ascii.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;

  final explicitInternational = ascii.trimLeft().startsWith('+') ||
      digits.startsWith('00') ||
      digits.startsWith('967');
  if (digits.startsWith('00')) {
    final international = digits.substring(2);
    return _validInternationalNumber(international) ? international : null;
  }
  if (explicitInternational) {
    return _validInternationalNumber(digits) ? digits : null;
  }

  // Yemen mobile number without a country code: 7xxxxxxxx.
  if (digits.length == 9 && digits.startsWith('7')) return '967$digits';
  // Yemen local dialing form with a trunk zero: 07xxxxxxxx.
  if (digits.length == 10 && digits.startsWith('07')) {
    return '967${digits.substring(1)}';
  }
  return null;
}

/// Builds the canonical HTTPS deep link that Android opens through ACTION_VIEW.
Uri? whatsappChatUri(String raw, {String? message}) {
  final number = normalizeWhatsAppNumber(raw);
  if (number == null) return null;
  return Uri.https(
    'wa.me',
    '/$number',
    message == null || message.isEmpty ? null : {'text': message},
  );
}

bool _validInternationalNumber(String digits) =>
    digits.length >= 8 && digits.length <= 15 && !digits.startsWith('0');
