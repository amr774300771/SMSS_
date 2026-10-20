/// Utilities for comparing Yemeni phone numbers without changing the stored value.
///
/// Supports ASCII, Arabic-Indic (٠١٢٣), Eastern Arabic-Indic (۰۱۲۳), and
/// Yemeni international prefixes (967 / 00967). An empty or non-numeric value
/// stays empty so it can never accidentally match another empty phone number.
String normalizeYemeniPhone(String value) {
  final localized = String.fromCharCodes(value.runes.map((rune) {
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
    return rune;
  }));

  var digits = localized.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '';
  if (digits.startsWith('00967')) {
    digits = digits.substring(5);
  } else if (digits.startsWith('967')) {
    digits = digits.substring(3);
  }
  digits = digits.replaceFirst(RegExp(r'^0+'), '');
  return digits.length <= 10 ? digits : digits.substring(digits.length - 10);
}
