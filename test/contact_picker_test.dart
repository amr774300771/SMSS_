import 'package:cardbot_qaidi/contact_picker_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _contacts = <ContactRecipient>[
  ContactRecipient(id: '1', name: 'يوسف علي', phone: '777000003'),
  ContactRecipient(id: '2', name: 'أحمد محمد', phone: '777000001'),
  ContactRecipient(id: '3', name: 'احمد سالم', phone: '777000002'),
  ContactRecipient(id: '4', name: 'Bilal', phone: '777000004'),
  ContactRecipient(id: '5', name: 'سارة', phone: '777000005'),
];

Future<void> _openPicker(
  WidgetTester tester, {
  ContactsLoader? loader,
  List<ContactRecipient> initial = const [],
  Set<String> favorites = const {},
  void Function(List<ContactRecipient>?)? onResult,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final result = await Navigator.push<List<ContactRecipient>>(
                context,
                MaterialPageRoute(
                  builder: (_) => ContactPickerPage(
                    initialSelection: initial,
                    favoritePhoneKeys: favorites,
                    loader: loader ?? () async => _contacts,
                  ),
                ),
              );
              onResult?.call(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('Arabic sorting helpers', () {
    test('normalizes alef, ya, ta marbuta and diacritics', () {
      expect(normalizeArabicName('أحمد'), normalizeArabicName('احمد'));
      expect(normalizeArabicName('فاطمة'), normalizeArabicName('فاطمه'));
      expect(normalizeArabicName('مُحَمَّد'), 'محمد');
    });

    test('sorts Arabic alphabetically, then Latin, then other', () {
      final names = ['Bilal', 'يوسف', 'أحمد', '123', 'سارة', 'باسم']
        ..sort(compareContactNames);
      expect(names, ['أحمد', 'باسم', 'سارة', 'يوسف', 'Bilal', '123']);
    });

    test('group letters', () {
      expect(contactGroupLetter('أحمد'), 'ا');
      expect(contactGroupLetter('Bilal'), 'B');
      expect(contactGroupLetter('123'), '#');
      expect(contactGroupLetter(''), '#');
    });

    test('count label follows Arabic number agreement', () {
      expect(contactCountLabel(1), 'تم اختيار جهة اتصال واحدة');
      expect(contactCountLabel(2), 'تم اختيار جهتي اتصال');
      expect(contactCountLabel(5), 'تم اختيار 5 جهات اتصال');
      expect(contactCountLabel(12), 'تم اختيار 12 جهة اتصال');
    });
  });

  testWidgets('toggles rows, updates header and confirm button',
      (tester) async {
    await _openPicker(tester);
    expect(find.text('اختيار جهات الاتصال'), findsOneWidget);
    expect(find.text('إرسال إلى (0)'), findsOneWidget);

    await tester.tap(find.text('سارة'));
    await tester.pump();
    expect(find.text('تم اختيار جهة اتصال واحدة'), findsOneWidget);
    expect(find.text('إرسال إلى (1)'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('سارة'));
    await tester.pump();
    expect(find.text('إرسال إلى (0)'), findsOneWidget);
  });

  testWidgets('select all, delete selection and search with alef variants',
      (tester) async {
    await _openPicker(tester);
    await tester.tap(find.text('تحديد الكل'));
    await tester.pump();
    expect(find.text('إرسال إلى (5)'), findsOneWidget);

    await tester.tap(find.byTooltip('حذف المحدد'));
    await tester.pump();
    expect(find.text('إرسال إلى (0)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'احمد');
    await tester.pump();
    expect(find.text('أحمد محمد'), findsOneWidget);
    expect(find.text('احمد سالم'), findsOneWidget);
    expect(find.text('سارة'), findsNothing);

    await tester.enterText(find.byType(TextField), '777000004');
    await tester.pump();
    expect(find.text('Bilal'), findsOneWidget);
    expect(find.text('أحمد محمد'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.textContaining('لا نتائج'), findsOneWidget);
  });

  testWidgets('shows a favorites section first', (tester) async {
    await _openPicker(tester, favorites: {'777000005'});
    expect(find.text('المفضلة'), findsOneWidget);
    final favoriteY = tester.getTopLeft(find.text('المفضلة')).dy;
    final saraY = tester.getTopLeft(find.text('سارة')).dy;
    final ahmedY = tester.getTopLeft(find.text('أحمد محمد')).dy;
    expect(favoriteY, lessThan(saraY));
    expect(saraY, lessThan(ahmedY));
  });

  testWidgets('restores the previous selection and returns the result',
      (tester) async {
    List<ContactRecipient>? result;
    await _openPicker(
      tester,
      initial: const [
        ContactRecipient(id: '5', name: 'سارة', phone: '777000005'),
      ],
      onResult: (value) => result = value,
    );
    expect(find.text('إرسال إلى (1)'), findsOneWidget);

    await tester.tap(find.text('يوسف علي'));
    await tester.pump();
    await tester.tap(find.text('إرسال إلى (2)'));
    await tester.pumpAndSettle();
    expect(result!.map((item) => item.id).toList(), ['5', '1']);
  });

  testWidgets('permission denied shows a clear message and retry',
      (tester) async {
    var attempts = 0;
    await _openPicker(
      tester,
      loader: () async {
        attempts++;
        if (attempts == 1) throw const ContactsPermissionDenied();
        return _contacts;
      },
    );
    expect(find.textContaining('يلزم السماح'), findsOneWidget);
    expect(find.text('فتح إعدادات التطبيق'), findsOneWidget);

    await tester.tap(find.text('إعادة الطلب'));
    await tester.pumpAndSettle();
    expect(find.text('سارة'), findsOneWidget);
  });

  testWidgets('stays responsive with thousands of contacts', (tester) async {
    final many = List.generate(
      3000,
      (i) => ContactRecipient(
          id: 'c$i', name: 'جهة $i', phone: '7770${i.toString().padLeft(5, '0')}'),
    );
    await _openPicker(tester, loader: () async => many);
    expect(find.text('3000 جهة اتصال • المحدد 0'), findsOneWidget);
    await tester.fling(find.byType(ListView), const Offset(0, -3000), 5000);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
