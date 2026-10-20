import 'dart:convert';

import 'package:cardbot_qaidi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeChannel = MethodChannel('com.qadinet.cardbot/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  Map<String, dynamic> data() => {
        'packages': {
          'packages': [
            {'id': '500', 'price': 500, 'label': '500'},
            {'id': '600', 'price': 600, 'label': '600'},
          ],
        },
        'inventory': {
          '500': ['CARD-1234', 'CARD-5678'],
          '600': <String>[],
        },
      };

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      calls.add(call);
      if (call.method == 'updateInventory' ||
          call.method == 'undoInventoryChange') {
        return data();
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });

  testWidgets('selects search results, bulk deletes, and exposes undo',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InventoryPage(data: data(), onRefresh: () async {}),
      ),
    ));
    await tester.tap(find.text('تحديد نتائج البحث حتى 5000 بطاقة (2)'));
    await tester.pumpAndSettle();

    expect(find.text('تم تحديد 2 بطاقة'), findsOneWidget);
    await tester.tap(find.text('حذف المحدد').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف المحدد').last);
    await tester.pumpAndSettle();

    final update =
        calls.singleWhere((call) => call.method == 'updateInventory');
    final changes = jsonDecode(update.arguments['changes'] as String) as List;
    expect(changes, hasLength(2));
    expect(changes.map((change) => change['action']).toSet(), {'delete'});
    expect(find.text('تراجع'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 5),
    );

    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'undoInventoryChange'), isTrue);
  });

  testWidgets('masks inventory card numbers until explicitly revealed',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InventoryPage(data: data(), onRefresh: () async {}),
      ),
    ));
    await tester.tap(find.text('باقة 500 — 2 بطاقة'));
    await tester.pumpAndSettle();

    expect(find.text('****1234'), findsOneWidget);
    expect(find.text('CARD-1234'), findsNothing);
    await tester.tap(find.byTooltip('إظهار البطاقة').first);
    await tester.pumpAndSettle();
    expect(find.text('CARD-1234'), findsOneWidget);
    await tester.tap(find.byTooltip('إخفاء البطاقة').first);
    await tester.pumpAndSettle();
    expect(find.text('****1234'), findsOneWidget);
    expect(find.text('CARD-1234'), findsNothing);
  });
}
