/// Pure helpers for the extended merchant controls.
/// Pricing precedence: explicit customer/package price, group/package price,
/// customer discount, then group discount, then the package's base price.
abstract final class SelectedFeatures {
  static String phoneKey(String phone) {
    final digits = _asciiDigits(phone).replaceAll(RegExp(r'\D'), '');
    var national = digits;
    if (national.startsWith('00967')) {
      national = national.substring(5);
    } else if (national.startsWith('967')) {
      national = national.substring(3);
    }
    national = national.replaceFirst(RegExp(r'^0+'), '');
    return national.length <= 10
        ? national
        : national.substring(national.length - 10);
  }

  static String _asciiDigits(String value) => value.replaceAllMapped(
        RegExp(r'[٠-٩۰-۹]'),
        (match) {
          final digit = match[0]!.codeUnitAt(0);
          final base = digit >= 0x06F0 ? 0x06F0 : 0x0660;
          return '${digit - base}';
        },
      );

  static int effectivePrice({
    required Map<String, dynamic> permissions,
    required String phone,
    required String packageId,
    required int basePrice,
  }) {
    final key = phoneKey(phone);
    final clients = permissions['clients'] is List
        ? permissions['clients'] as List
        : const <dynamic>[];
    Map<String, dynamic>? client;
    for (final value in clients) {
      if (value is Map && phoneKey('${value['phone'] ?? ''}') == key) {
        client = Map<String, dynamic>.from(value);
        break;
      }
    }
    if (client != null) {
      final explicit = _priceFrom(client['packagePrices'], packageId);
      if (explicit != null) return explicit;
    }

    final global = permissions['global'] is Map
        ? Map<String, dynamic>.from(permissions['global'] as Map)
        : <String, dynamic>{};
    final groups = global['priceGroups'] is List
        ? global['priceGroups'] as List
        : const <dynamic>[];
    final groupId = '${client?['priceGroup'] ?? ''}';
    Map<String, dynamic>? group;
    for (final value in groups) {
      if (value is Map && '${value['id'] ?? ''}' == groupId) {
        group = Map<String, dynamic>.from(value);
        break;
      }
    }
    if (group != null) {
      final groupPrice = _priceFrom(group['packagePrices'], packageId);
      if (groupPrice != null) return groupPrice;
    }

    final customerDiscount =
        client == null ? null : _discount(client['discountPercent']);
    if (customerDiscount != null) {
      return _discounted(basePrice, customerDiscount);
    }
    final groupDiscount =
        group == null ? null : _discount(group['discountPercent']);
    if (groupDiscount != null) return _discounted(basePrice, groupDiscount);
    return basePrice;
  }

  static int? _priceFrom(dynamic source, String packageId) {
    if (source is! Map || !source.containsKey(packageId)) return null;
    final price = int.tryParse('${source[packageId]}');
    return price != null && price > 0 ? price : null;
  }

  static int? _discount(dynamic value) {
    if (value == null || '$value'.trim().isEmpty) return null;
    final parsed = num.tryParse('$value');
    if (parsed == null || parsed < 0 || parsed > 100) return null;
    return parsed.round();
  }

  static int _discounted(int price, int percent) =>
      (price * (100 - percent) / 100).round();

  static List<String> keywordConflicts(List<Map<String, dynamic>> packages) {
    final conflicts = <String>[];
    final seen = <String, (String, String)>{};
    for (final package in packages) {
      final id = '${package['id'] ?? ''}';
      final words = package['keywords'] is List
          ? (package['keywords'] as List).map((e) => '$e').toList()
          : <String>[];
      for (final word in words) {
        final normalized = _normalize(word);
        if (normalized.isEmpty) continue;
        final exact = seen[normalized];
        if (exact != null && exact.$1 != id) {
          conflicts.add('«$word» مشتركة بين الباقتين ${exact.$1} و$id');
        } else if (exact != null) {
          conflicts.add('«$word» مكررة داخل الباقة $id');
        }
        for (final entry in seen.entries) {
          if (entry.value.$1 != id &&
              entry.key != normalized &&
              (_wholeWord(normalized, entry.key) ||
                  _wholeWord(entry.key, normalized))) {
            conflicts.add(
                '«$word» تتداخل مع «${entry.value.$2}» للباقة ${entry.value.$1}');
          }
        }
        seen.putIfAbsent(normalized, () => (id, word));
      }
    }
    return conflicts.toSet().toList();
  }

  static bool isPackageExcluded({
    required Map<String, dynamic> package,
    required String phone,
    required String message,
  }) {
    final key = phoneKey(phone);
    final excludedPhones = package['excludedPhones'] is List
        ? (package['excludedPhones'] as List).map((e) => phoneKey('$e'))
        : const <String>[];
    if (excludedPhones.contains(key)) return true;
    final normalizedMessage = _normalize(message);
    final excludedWords = package['excludedKeywords'] is List
        ? (package['excludedKeywords'] as List).map((e) => _normalize('$e'))
        : const <String>[];
    return excludedWords
        .any((word) => word.isNotEmpty && _wholeWord(normalizedMessage, word));
  }

  static String _normalize(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll('ـ', '')
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  static bool _wholeWord(String message, String phrase) {
    try {
      return RegExp(
        r'(?<![\p{L}\p{N}])' + RegExp.escape(phrase) + r'(?![\p{L}\p{N}])',
        caseSensitive: false,
        unicode: true,
      ).hasMatch(message);
    } catch (_) {
      return false;
    }
  }
}
