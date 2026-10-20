import 'dart:io';

import 'package:cardbot_qaidi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cardbot_qaidi/skeleton_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = Directory.systemTemp.createTempSync('qadinet-widget-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox('preferences');
  });

  tearDownAll(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) hiveDirectory.deleteSync(recursive: true);
  });

  testWidgets('settings keep all four options in collapsible groups',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        data: {
          'trigger': {'triggerEnabled': false},
        },
        onRefresh: () async {},
      ),
    ));

    expect(find.text('عام'), findsOneWidget);
    expect(find.text('الواجهة'), findsOneWidget);
    expect(find.text('السلوك'), findsOneWidget);
    expect(find.text('متقدم'), findsOneWidget);

    await tester.tap(find.text('عام'));
    await tester.pumpAndSettle();
    expect(find.text('محرك استقبال SMS'), findsOneWidget);

    await tester.ensureVisible(find.text('الواجهة'));
    await tester.tap(find.text('الواجهة'));
    await tester.pumpAndSettle();
    expect(find.text('وضع الخصوصية السريع'), findsOneWidget);
    expect(find.text('وضع الاستخدام بيد واحدة'), findsOneWidget);
    expect(find.text('الوضع الليلي'), findsOneWidget);
  });

  testWidgets(
      'active client menu retains manual debt action in requested order',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClientsPage(
          data: {
            'permissions': {
              'global': {},
              'clients': [
                {'phone': '777123456', 'name': 'عميل اختبار'},
              ],
            },
            'trusted': {
              'clients': [
                {'phone': '777123456', 'name': 'عميل اختبار'},
              ],
              'archivedClients': [],
            },
            'debts': [],
            'sales': [],
            'transactions': [],
          },
          onRefresh: () async {},
        ),
      ),
    ));

    final menuButton = find.byType(PopupMenuButton<String>);
    await tester.ensureVisible(menuButton);
    await tester.tap(menuButton);
    await tester.pumpAndSettle();

    expect(find.text('تعديل'), findsOneWidget);
    expect(find.text('إضافة / تعديل دين يدوي'), findsNWidgets(2));
    expect(find.text('سجل المبيعات'), findsOneWidget);
    expect(find.text('حذف'), findsOneWidget);
    expect(find.text('استعادة العميل'), findsNothing);
    final menuLabels = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map((item) => (item.child as Text).data)
        .toList();
    expect(
        menuLabels, ['تعديل', 'إضافة / تعديل دين يدوي', 'سجل المبيعات', 'حذف']);
  });

  testWidgets('empty inventory explains the next useful action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InventoryPage(
          data: {
            'packages': {
              'packages': [
                {'id': '500', 'price': 500, 'label': '500'},
              ],
            },
            'inventory': {'500': <String>[]},
          },
          onRefresh: () async {},
        ),
      ),
    ));

    expect(find.text('المخزون فارغ. أضف بطاقات نصية أو استورد ملف PDF.'),
        findsOneWidget);
  });

  testWidgets('home keeps readiness details collapsible and shows skeletons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomePage(
          data: {
            'trigger': {'triggerEnabled': false},
            'inventory': <String, List<String>>{},
            'sales': <Map<String, dynamic>>[],
            'debts': <Map<String, dynamic>>[],
          },
          onRefresh: () async {},
          onOpen: (_) {},
        ),
      ),
    ));

    expect(find.textContaining('تفاصيل الجاهزية'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('تفاصيل الجاهزية'));
    await tester.tap(find.textContaining('تفاصيل الجاهزية'));
    await tester.pumpAndSettle();
    expect(find.text('قاعدة البيانات المحلية'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: AppSkeleton(dashboard: true)),
    ));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('جار تحميل البيانات'), findsOneWidget);
  });
}
