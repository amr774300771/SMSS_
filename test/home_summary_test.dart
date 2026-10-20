import 'package:cardbot_qaidi/home_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 10, 19, 15);
  final yesterday = DateTime(2026, 10, 18, 10);

  final sales = <Map<String, dynamic>>[
    {'time': '2026-10-19T09:00:00', 'price': 500, 'paymentMethod': 'cash', 'profit': 50},
    {'time': '2026-10-19T11:00:00', 'price': 300, 'paymentMethod': 'credit', 'profit': 30},
    {
      'time': '2026-10-19T12:00:00',
      'price': 200,
      'paymentMethod': 'cash',
      'saleSource': 'manual',
      'profit': 20,
    },
    {'time': '2026-10-18T09:00:00', 'price': 400, 'paymentMethod': 'cash', 'profit': 40},
    {'time': 'غير صالح', 'price': 999, 'paymentMethod': 'cash'},
  ];

  test('daily summary groups a single day by payment method', () {
    final summary = DailySummary.forDay(sales, today);
    expect(summary.count, 3);
    expect(summary.total, 1000);
    expect(summary.cash, 700);
    expect(summary.credit, 300);
    expect(summary.profit, 100);
    expect(summary.manual, 1);
    expect(DailySummary.forDay(sales, yesterday).total, 400);
  });

  test('percent change is null without a baseline', () {
    expect(percentChange(1000, 400), 150);
    expect(percentChange(200, 400), -50);
    expect(percentChange(100, 0), isNull);
  });

  test('alerts are sorted by severity and tolerate empty data', () {
    expect(buildHomeAlerts({}).first.level, HomeAlertLevel.critical);

    final alerts = buildHomeAlerts({
      'trigger': {
        'triggerEnabled': true,
        'scheduledSales': [
          {'status': 'pending'},
          {'status': 'failed'},
        ],
      },
      'inventory': {'500': <String>[]},
      'lowStockWarnings': [
        {'packageId': '500', 'count': 1, 'threshold': 3},
      ],
      'debts': [
        {'phone': '777000001', 'amount': 1500},
        {'phone': '777000002', 'amount': 0},
      ],
    });
    final levels = alerts.map((a) => a.level.index).toList();
    expect(levels, [...levels]..sort());
    expect(alerts.first.level, HomeAlertLevel.critical);
    expect(alerts.any((a) => a.title.contains('المخزون فارغ')), isTrue);
    expect(alerts.any((a) => a.title.contains('1 عميل')), isTrue);
  });

  test('top debtors ignore zero balances and sort descending', () {
    final result = topDebtors([
      {'phone': 'a', 'amount': 100},
      {'phone': 'b', 'amount': 900},
      {'phone': 'c', 'amount': 0},
      {'phone': 'd', 'amount': -50},
      {'phone': 'e', 'amount': 400},
    ]);
    expect(result.map((d) => d['phone']).toList(), ['b', 'e', 'a']);
    expect(totalOutstandingDebt([
      {'amount': 100},
      {'amount': -50},
      {'amount': '25'},
    ]), 125);
  });

  test('daily close text has no card numbers or phones', () {
    final text = buildDailyCloseText(
      day: today,
      summary: DailySummary.forDay(sales, today),
      stockCount: 42,
      totalDebt: 1500,
      lowStock: const ['500'],
    );
    expect(text, contains('2026/10/19'));
    expect(text, contains('عدد العمليات: 3'));
    expect(text, contains('المخزون المتاح: 42 بطاقة'));
    expect(text, contains('باقات منخفضة المخزون: 500'));
    expect(text, isNot(contains('777')));
  });
}
