import 'whatsapp_utils.dart';

class TrustedContactCandidate {
  final String phone;
  final String name;
  const TrustedContactCandidate({required this.phone, this.name = ''});
}

class TrustedImportPreview {
  final List<TrustedContactCandidate> valid;
  final List<String> duplicates;
  final List<String> invalid;
  const TrustedImportPreview({
    required this.valid,
    required this.duplicates,
    required this.invalid,
  });
}

/// Accepts one phone per line/comma/semicolon; optionally use `name | phone`.
TrustedImportPreview parseTrustedImport(
  String text, {
  Set<String> existingNumbers = const {},
}) {
  final existing =
      existingNumbers.map(_canonicalPhone).whereType<String>().toSet();
  final seen = <String>{};
  final valid = <TrustedContactCandidate>[];
  final duplicates = <String>[];
  final invalid = <String>[];

  for (final item in text.split(RegExp(r'[\r\n,،;؛]+'))) {
    final raw = item.trim();
    if (raw.isEmpty) continue;
    final separator = raw.lastIndexOf('|');
    final name = separator < 0 ? '' : raw.substring(0, separator).trim();
    final rawPhone = separator < 0 ? raw : raw.substring(separator + 1).trim();
    final canonical = _canonicalPhone(rawPhone);
    if (canonical == null) {
      invalid.add(raw);
      continue;
    }
    if (existing.contains(canonical) || !seen.add(canonical)) {
      duplicates.add(raw);
      continue;
    }
    valid.add(TrustedContactCandidate(
      phone: _storedPhone(rawPhone, canonical),
      name: name,
    ));
  }

  return TrustedImportPreview(
    valid: valid,
    duplicates: duplicates,
    invalid: invalid,
  );
}

String? _canonicalPhone(String raw) => normalizeWhatsAppNumber(raw);

String _storedPhone(String raw, String canonical) {
  final ascii = String.fromCharCodes(raw.trim().runes.map((rune) {
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
    return rune;
  }));
  final digits = ascii.replaceAll(RegExp(r'[^0-9]'), '');
  final international = ascii.trimLeft().startsWith('+') ||
      digits.startsWith('00') ||
      digits.startsWith('967');
  if (!international) return digits;
  return '+$canonical';
}
