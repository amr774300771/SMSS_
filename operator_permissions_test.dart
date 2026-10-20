import 'package:flutter_test/flutter_test.dart';
import 'package:cardbot_qaidi/operator_permissions.dart';

void main() {
  group('OperatorPermissionPolicy', () {
    test('defaults to deny for missing operators and permissions', () {
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-1',
          capability: 'sales.create_cash',
          overrides: const {},
        ),
        isFalse,
      );
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: '',
          capability: 'sales.create_cash',
          overrides: const {},
        ),
        isFalse,
      );
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'manager-1',
          capability: 'unknown.capability',
          overrides: const {},
          isManager: true,
        ),
        isFalse,
      );
    });

    test('allows explicit per-operator grant only', () {
      final overrides = {
        'seller-1': {'allow': ['sales.create_cash'], 'deny': <String>[]},
      };
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-1',
          capability: 'sales.create_cash',
          overrides: overrides,
        ),
        isTrue,
      );
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-1',
          capability: 'sales.create_credit',
          overrides: overrides,
        ),
        isFalse,
      );
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-2',
          capability: 'sales.create_cash',
          overrides: overrides,
        ),
        isFalse,
      );
    });

    test('explicit deny wins and manager override is supported', () {
      final overrides = {
        'seller-1': {
          'allow': ['ledger.adjust'],
          'deny': ['ledger.adjust'],
        },
      };
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-1',
          capability: 'ledger.adjust',
          overrides: overrides,
        ),
        isFalse,
      );
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: '',
          capability: 'ledger.adjust',
          overrides: const {},
          isManager: true,
        ),
        isTrue,
      );
    });

    test('updates a permission without mutating the original map', () {
      final original = <String, dynamic>{};
      final updated = OperatorPermissionPolicy.setPermission(
        overrides: original,
        operatorId: 'seller-1',
        capability: 'payments.collect',
        allowed: true,
      );
      expect(original, isEmpty);
      expect(
        OperatorPermissionPolicy.allows(
          operatorId: 'seller-1',
          capability: 'payments.collect',
          overrides: updated,
        ),
        isTrue,
      );
    });
  });
}
