/// Per-operator permission policy for Qaidi Net.
///
/// This class is deliberately independent from storage and UI so it can be
/// unit-tested. Integrators must load the saved overrides and call [allows]
/// at the operation boundary (not only when deciding whether to show a button).
class OperatorPermissionPolicy {
  OperatorPermissionPolicy._();

  static const storageKey = 'operatorPermissionOverrides';

  static const capabilities = <String>{
    'sales.create_cash',
    'sales.create_credit',
    'sales.refund',
    'payments.collect',
    'ledger.adjust',
    'inventory.manage',
    'clients.manage',
    'reports.view',
    'messages.send',
    'settings.manage',
    'users.manage',
    'backup.create',
    'backup.restore',
  };

  /// Override schema:
  /// {
  ///   'operator-id': {'allow': ['sales.create_cash'], 'deny': ['ledger.adjust']}
  /// }
  /// Explicit deny wins. Unknown/blank operators and unknown capabilities deny.
  static bool allows({
    required String operatorId,
    required String capability,
    required Map<String, dynamic> overrides,
    bool isManager = false,
  }) {
    if (!capabilities.contains(capability)) return false;
    if (isManager) return true;
    if (operatorId.trim().isEmpty) return false;

    final rawOperator = overrides[operatorId];
    if (rawOperator is! Map) return false;
    final operator = Map<String, dynamic>.from(rawOperator);
    final denied = _strings(operator['deny']);
    if (denied.contains(capability)) return false;
    return _strings(operator['allow']).contains(capability);
  }

  static Set<String> _strings(dynamic value) => value is List
      ? value.whereType<String>().toSet()
      : <String>{};

  /// Produces a copy; it never mutates the caller's settings map.
  static Map<String, dynamic> setPermission({
    required Map<String, dynamic> overrides,
    required String operatorId,
    required String capability,
    required bool allowed,
  }) {
    if (operatorId.trim().isEmpty || !capabilities.contains(capability)) {
      throw ArgumentError('Unknown operator or capability');
    }
    final next = Map<String, dynamic>.from(overrides);
    operatorId = operatorId.trim();
    final existing = next[operatorId];
    final operator = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    final allow = _strings(operator['allow']);
    final deny = _strings(operator['deny']);
    if (allowed) {
      allow.add(capability);
      deny.remove(capability);
    } else {
      allow.remove(capability);
      deny.add(capability);
    }
    operator['allow'] = allow.toList()..sort();
    operator['deny'] = deny.toList()..sort();
    next[operatorId] = operator;
    return next;
  }
}
