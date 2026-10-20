/// Rules shared by package forms and unit tests.
/// Package IDs are canonical decimal prices (for example, 500 -> "500").
abstract final class PackageRules {
  static int? parsePrice(String raw) {
    final localized = String.fromCharCodes(raw.trim().runes.map((rune) {
      if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
      if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
      return rune;
    }));
    final hasGrouping = RegExp(r'[,\u066C\s]').hasMatch(localized);
    if (hasGrouping &&
        !RegExp(r'^[0-9]{1,3}(?:[,\u066C\s][0-9]{3})+$').hasMatch(localized)) {
      return null;
    }
    final normalized = localized.replaceAll(RegExp(r'[,\u066C\s]'), '');
    if (normalized.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(normalized)) {
      return null;
    }
    final value = int.tryParse(normalized);
    return value != null && value > 0 ? value : null;
  }

  static int? parseNonNegativeAmount(String raw) {
    final localized = String.fromCharCodes(raw.trim().runes.map((rune) {
      if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
      if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
      return rune;
    }));
    final hasGrouping = RegExp(r'[,\u066C\s]').hasMatch(localized);
    if (hasGrouping &&
        !RegExp(r'^[0-9]{1,3}(?:[,\u066C\s][0-9]{3})+$').hasMatch(localized)) {
      return null;
    }
    final normalized = localized.replaceAll(RegExp(r'[,\u066C\s]'), '');
    if (normalized.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(normalized)) {
      return null;
    }
    return int.tryParse(normalized);
  }

  static String normalizeKeyword(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll('\u0640', '')
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Returns a human-readable validation failure, or null when valid.
  static String? validatePackages(
    List<Map<String, dynamic>> packages, {
    List<Map<String, dynamic>> allowUnchangedLegacy = const [],
  }) {
    if (packages.isEmpty)
      return 'يجب أن تحتوي القائمة على باقة واحدة على الأقل.';
    if (packages.length > 200) return 'الحد الأقصى هو 200 باقة.';

    final ids = <String>{};
    final keywords = <String, String>{};
    final priorKeywords = <(String, String)>[];
    for (final package in packages) {
      final id = '${package['id'] ?? ''}'.trim();
      final price = int.tryParse('${package['price'] ?? ''}');
      final unchangedLegacy = allowUnchangedLegacy.any((old) =>
          '${old['id'] ?? ''}' == id &&
          '${old['price'] ?? ''}' == '${package['price'] ?? ''}' &&
          '${old['label'] ?? id}' == '${package['label'] ?? id}' &&
          _sameStringList(old['keywords'], package['keywords']));
      if (price == null || price <= 0 || (id != '$price' && !unchangedLegacy)) {
        return 'معرّف الباقة يجب أن يساوي سعرها؛ صحّح الباقة $id.';
      }
      if (!ids.add(id)) return 'معرّف الباقة $id مستخدم بالفعل.';

      final aliases = package['keywords'];
      if (aliases is! List || aliases.isEmpty) {
        return 'أضف كلمة طلب واحدة على الأقل للباقة $id.';
      }
      for (final value in aliases) {
        final alias = '$value'.trim();
        final normalized = normalizeKeyword(alias);
        if (alias.isEmpty || alias.length > 80) {
          return 'توجد كلمة طلب فارغة أو أطول من 80 حرفاً للباقة $id.';
        }
        final previousOwner = keywords[normalized];
        if (previousOwner != null && previousOwner != id) {
          return 'كلمة الطلب «$alias» مستخدمة في الباقة $previousOwner أيضاً.';
        }
        if (previousOwner == id) {
          return 'كلمة الطلب «$alias» مكررة داخل الباقة $id.';
        }
        for (final (previousWord, previousId) in priorKeywords) {
          if (previousId != id &&
              (_keywordMatches(alias, previousWord) ||
                  _keywordMatches(previousWord, alias))) {
            return 'عبارة الطلب «$alias» تتداخل مع كلمة «$previousWord» للباقة $previousId.';
          }
        }
        keywords[normalized] = id;
        priorKeywords.add((normalized, id));
      }
    }
    return null;
  }

  static bool _sameStringList(dynamic first, dynamic second) {
    if (first is! List || second is! List || first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index++) {
      if ('${first[index]}' != '${second[index]}') return false;
    }
    return true;
  }

  /// Mirrors the native engine's whole-word matching and highest-price-first rule.
  static String? matchPackageId(
    String message,
    List<Map<String, dynamic>> packages,
  ) {
    final ordered = List<Map<String, dynamic>>.of(packages)
      ..sort((a, b) => (int.tryParse('${b['price']}') ?? 0)
          .compareTo(int.tryParse('${a['price']}') ?? 0));
    final input = normalizeKeyword(message);
    for (final package in ordered) {
      final id = '${package['id']}';
      final rawAliases = package['keywords'];
      final aliases = rawAliases is List ? rawAliases : <dynamic>[id];
      for (final raw in aliases) {
        final alias = normalizeKeyword('$raw');
        if (alias.isEmpty) continue;
        final pattern = RegExp(
          r'(?<![\p{L}\p{N}])' + RegExp.escape(alias) + r'(?![\p{L}\p{N}])',
          caseSensitive: false,
          unicode: true,
        );
        if (pattern.hasMatch(input)) return id;
      }
    }
    return null;
  }

  static bool _keywordMatches(String message, String alias) {
    final pattern = RegExp(
      r'(?<![\p{L}\p{N}])' + RegExp.escape(alias) + r'(?![\p{L}\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
    return pattern.hasMatch(message);
  }
}
