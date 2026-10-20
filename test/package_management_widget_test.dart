import 'dart:convert';

import 'package:cardbot_qaidi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeChannel = MethodChannel('com.qadinet.cardbot/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const savedPackages = <Map<String, dynamic>>[
    {
      'id': '200',
      'price': 200,
      'label': '200',
      'keywords': ['200', 'مئتان']
    },
    {
      'id': '300',
      'price': 300,
      'label': '300',
      'keywords': ['300', 'ثلاثمائة']
    },
    {
      'id': '500',
      'price': 500,
      'label': '500',
      'keywords': ['500', 'خمس']
    },
    {
      'id': '3000',
      'price': 3000,
      'label': '3000',
      'keywords': ['3000', 'ثلاثة آلاف']
    },
  ];

  Map<String, dynamic> pageData() => {
        'packages': {
          'schemaVersion': 1,
          'packages': savedPackages
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
        },
        'inventory': {
          '200': <String>[],
          '300': <String>[],
          '500': <String>[],
          '3000': <String>[]
        },
        'transactions': <dynamic>[],
      };

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });

  testWidgets('adds a package from the UI and saves ID equal to its price',
      (tester) async {
    Map<String, dynamic>? savedConfig;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      expect(call.method, 'saveConfig');
      expect(call.arguments['filename'], 'packages.json');
      savedConfig = jsonDecode(call.arguments['content'] as String)
          as Map<String, dynamic>;
      return {
        'packages': savedConfig,
        'inventory': {
          '200': <String>[],
          '300': <String>[],
          '500': <String>[],
          '1000': <String>[],
          '3000': <String>[],
        },
        'transactions': <dynamic>[],
      };
    });

    await tester.pumpWidget(MaterialApp(
      home: PackagesPage(data: pageData(), onRefresh: () async {}),
    ));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1000');
    await tester.enterText(fields.at(1), '1000 ريال');
    await tester.enterText(fields.at(2), '1000, ألف');
    expect(
        find.textContaining('سيُحفظ الرقم نفسه كمعرّف تلقائي'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();

    expect(savedConfig, isNotNull);
    final packages =
        (savedConfig!['packages'] as List).cast<Map<String, dynamic>>();
    final added = packages.singleWhere((item) => item['id'] == '1000');
    expect(added['price'], 1000);
    expect(added['keywords'], contains('ألف'));
    expect(
        find.text('أُضيفت الباقة وظهرت في المخزون والمشغّل.'), findsOneWidget);
  });

  testWidgets('shows a visible error when the requested price already exists',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PackagesPage(data: pageData(), onRefresh: () async {}),
    ));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '500');
    await tester.enterText(fields.at(2), '500, خمس');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('توجد باقة بالفعل بالسعر والمعرّف 500'),
        findsOneWidget);
  });
}
