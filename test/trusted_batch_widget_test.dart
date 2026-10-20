import 'dart:convert';

import 'package:cardbot_qaidi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeChannel = MethodChannel('com.qadinet.cardbot/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic>? savedTrusted;
  Map<String, dynamic>? savedPermissions;

  Map<String, dynamic> state({
    Map<String, dynamic>? trusted,
    Map<String, dynamic>? permissions,
  }) =>
      {
        'packages': {
          'packages': [
            {'id': '500', 'price': 500, 'label': '500'},
          ],
        },
        'trusted': trusted ?? {'filterEnabled': false, 'clients': []},
        'permissions': permissions ??
            {
              'global': {
                'allowAllClients': true,
                'allowedPackages': ['500'],
                'paymentMethods': ['cash', 'credit'],
                'maxDebt': 25000,
                'maxDailyTransactions': 8,
                'maxDailyAmount': 70000,
                'timeRestriction': {'enabled': false},
              },
              'clients': [],
            },
      };

  setUp(() {
    savedTrusted = null;
    savedPermissions = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      if (call.method == 'snapshot') return state();
      if (call.method == 'saveClientAndTrusted') {
        savedTrusted = jsonDecode(call.arguments['trusted'] as String)
            as Map<String, dynamic>;
        savedPermissions = jsonDecode(call.arguments['permissions'] as String)
            as Map<String, dynamic>;
        return state(trusted: savedTrusted, permissions: savedPermissions);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });

  testWidgets('previews valid and invalid numbers then adds trusted batch',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: EnginePage(data: state(), onRefresh: () async {}),
    ));
    await tester.tap(find.text('العملاء الموثقون'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة عدة أرقام دفعة واحدة'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '0771234567\nرقم-غير-صالح');
    await tester.tap(find.text('معاينة الأرقام'));
    await tester.pumpAndSettle();

    expect(find.textContaining('جديد: 1'), findsOneWidget);
    expect(find.textContaining('غير صالح: 1'), findsOneWidget);
    await tester.tap(find.text('إضافة 1'));
    await tester.pumpAndSettle();

    final clients = (savedTrusted!['clients'] as List).cast<Map>();
    expect(clients.single['phone'], '0771234567');
    final permissionClients =
        (savedPermissions!['clients'] as List).cast<Map>();
    expect(permissionClients.single['phone'], '0771234567');
    expect(permissionClients.single['allowedPackages'], ['500']);
    expect(permissionClients.single['maxDebt'], 25000);
  });
}
