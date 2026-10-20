import 'package:cardbot_qaidi/account_statement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> profileData() => {
        'permissions': {'clients': <Map<String, dynamic>>[]},
        'trusted': {'clients': <Map<String, dynamic>>[]},
        'transactions': [
          {
            'phone': '777123456',
            'clientName': 'سارة محمد',
            'type': 'sale_credit',
            'delta': 500,
            'amount': 500,
            'createdAt': '2026-10-16T09:30:00.000',
            'paymentMethod': 'credit',
            'packageId': '500',
            'reference': 'SALE-001',
          },
          {
            'phone': '777123456',
            'clientName': 'سارة محمد',
            'type': 'receipt',
            'delta': -200,
            'amount': 200,
            'createdAt': '2026-10-17T09:30:00.000',
            'paymentMethod': 'cash',
            'reference': 'RCPT-001',
          },
        ],
      };

  Widget page(Map<String, dynamic> data) => MaterialApp(
        home: AccountStatementPage(
          data: data,
          phone: '777123456',
          onRefresh: () async {},
          onSell: () async {},
        ),
      );

  testWidgets('unified client profile shows balance, summary and statement',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(page(profileData()));

    expect(find.text('ملف العميل'), findsOneWidget);
    expect(find.text('سارة محمد'), findsOneWidget);
    expect(find.text('777123456'), findsOneWidget);
    expect(find.text('المطلوب تحصيله'), findsOneWidget);
    expect(find.text('300 ر.ي'), findsOneWidget);
    expect(find.text('مبيعات آجل'), findsOneWidget);
    expect(find.text('500 ر.ي'), findsOneWidget);
    expect(find.text('دفعات مستلمة'), findsOneWidget);
    expect(find.text('200 ر.ي'), findsOneWidget);
    expect(find.text('كشف الحساب'), findsOneWidget);
    expect(find.text('استلام دفعة'), findsOneWidget);
    expect(find.text('صرف كرت'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('استلام دفعة من العميل'), findsOneWidget);
    expect(find.text('بيع كرت — آجل'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'empty client profile still shows settled balance and empty state',
      (tester) async {
    await tester.pumpWidget(page({
      'permissions': {'clients': <Map<String, dynamic>>[]},
      'trusted': {'clients': <Map<String, dynamic>>[]},
      'transactions': <Map<String, dynamic>>[],
    }));

    expect(find.text('الحساب مسدد'), findsOneWidget);
    expect(find.text('0 ر.ي'), findsNWidgets(3));
    expect(find.text('لا توجد حركات مسجلة لهذا العميل بعد.'), findsOneWidget);
  });
}
