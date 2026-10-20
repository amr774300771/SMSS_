import 'package:cardbot_qaidi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _nativeChannel = MethodChannel('com.qadinet.cardbot/native');

Map<String, dynamic> _saleData() => {
      'packages': {
        'schemaVersion': 1,
        'packages': [
          {
            'id': '500',
            'price': 500,
            'label': '500',
            'keywords': ['500', 'خمس'],
          },
        ],
      },
      'inventory': {
        '500': <String>['CARD-AVAILABLE']
      },
      'transactions': <dynamic>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
  });

  testWidgets('manual WhatsApp sale opens the direct chat for the sold card',
      (tester) async {
    Map<String, dynamic>? sellArguments;
    Uri? openedUri;
    var refreshCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      expect(call.method, 'sell');
      sellArguments = Map<String, dynamic>.from(call.arguments as Map);
      return <String, dynamic>{
        'ok': true,
        'message': 'تم البيع',
        'card': 'CARD-500-ABC',
        'debt': 0,
        'packageId': '500',
        'price': 500,
        'smsSent': null,
      };
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SaleSheet(
                  data: _saleData(),
                  initialPhone: '777123456',
                  initialName: 'عميل الاختبار',
                  onDone: () async => refreshCalled = true,
                  launchExternalUri: (uri) async {
                    openedUri = uri;
                    return true;
                  },
                ),
              ),
              child: const Text('ابدأ'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ابدأ'));
    await tester.pumpAndSettle();

    final dropdowns = find.byType(DropdownButtonFormField<String>);
    expect(dropdowns, findsNWidgets(3));
    await tester.tap(dropdowns.at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('فتح محادثة WhatsApp للرقم').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('إتمام البيع'));
    await tester.pumpAndSettle();

    expect(sellArguments, isNotNull);
    expect(sellArguments!['packageId'], '500');
    expect(sellArguments!['phone'], '777123456');
    expect(sellArguments!['sendSms'], isFalse);
    expect(refreshCalled, isTrue);
    expect(openedUri?.scheme, 'https');
    expect(openedUri?.host, 'wa.me');
    expect(openedUri?.pathSegments, ['967777123456']);
    expect(openedUri?.queryParameters['text'], contains('CARD-500-ABC'));
    expect(openedUri?.queryParameters['text'], contains('500'));
    expect(openedUri?.queryParameters['text'], contains('عميل الاختبار'));
    expect(openedUri?.queryParameters['text'], isNot(contains('المتبقي عليك')));
    expect(
      find.textContaining('فُتحت محادثة WhatsApp للرقم'),
      findsOneWidget,
    );
  });

  testWidgets('manual SMS sale opens composer with recipient and prepared text',
      (tester) async {
    final calls = <MethodCall>[];
    var refreshCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      calls.add(call);
      if (call.method == 'sell') {
        return <String, dynamic>{
          'ok': true,
          'message': 'تم البيع',
          'card': 'CARD-SMS-500',
          'debt': 0,
          'packageId': '500',
          'price': 500,
          'smsSent': null,
        };
      }
      if (call.method == 'openSmsComposer') return true;
      return null;
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SaleSheet(
                  data: _saleData(),
                  initialPhone: '777123456',
                  initialName: 'عميل SMS',
                  onDone: () async => refreshCalled = true,
                ),
              ),
              child: const Text('ابدأ SMS'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ابدأ SMS'));
    await tester.pumpAndSettle();
    final dropdowns = find.byType(DropdownButtonFormField<String>);
    await tester.tap(dropdowns.at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('فتح SMS برسالة جاهزة (تأكيد يدوي)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('إتمام البيع'));
    await tester.pumpAndSettle();

    final saleCall = calls.firstWhere((call) => call.method == 'sell');
    final smsCall =
        calls.firstWhere((call) => call.method == 'openSmsComposer');
    final saleArgs = Map<String, dynamic>.from(saleCall.arguments as Map);
    final smsArgs = Map<String, dynamic>.from(smsCall.arguments as Map);
    expect(saleArgs['sendSms'], isFalse);
    expect(smsArgs['phone'], '777123456');
    expect(smsArgs['message'], contains('CARD-SMS-500'));
    expect(smsArgs['message'], contains('عميل SMS'));
    expect(refreshCalled, isTrue);
    expect(find.textContaining('فُتحت رسالة SMS جاهزة'), findsOneWidget);
  });
}
