import 'package:flutter_test/flutter_test.dart';
import 'package:cardbot_qaidi/report_metrics.dart';

void main() {
  final now = DateTime(2026, 10, 17, 12);

  test('filters reports by calendar period', () {
    expect(isInReportPeriod('2026-10-17T08:00:00', 1, now: now), isTrue);
    expect(isInReportPeriod('2026-10-16T23:59:00', 1, now: now), isFalse);
    expect(isInReportPeriod('2026-10-11T12:00:00', 7, now: now), isTrue);
    expect(isInReportPeriod('2026-10-10T12:00:00', 7, now: now), isFalse);
    expect(isInReportPeriod('not-a-date', 30, now: now), isFalse);
  });

  test('groups sales and calculates amounts', () {
    final sales = [
      {'packageId': '500', 'price': 500},
      {'packageId': '500', 'price': 500},
      {'packageId': '1000'},
    ];
    expect(salesByPackage(sales), {'500': 2, '1000': 1});
    expect(reportAmount(sales[0]), 500);
    expect(reportAmount(sales[2]), 1000);
  });

  test('builds escaped CSV with Arabic headers', () {
    final csv = buildSalesCsv([
      {
        'time': '2026-10-17',
        'packageId': '500',
        'clientName': 'عميل، تجريبي',
        'phone': '777000000',
        'price': 500,
        'cash': true,
      },
    ]);
    expect(csv, contains('"التاريخ"'));
    expect(csv, contains('"عميل، تجريبي"'));
    expect(csv, contains('"500"'));
  });

  test('separates manual sales and accumulates credit debt effect', () {
    final sales = [
      {'saleSource': 'manual', 'description': 'خدمة', 'price': 2 * 700, 'profit': 500, 'paymentMethod': 'credit'},
      {'saleSource': 'inventory', 'price': 500, 'paymentMethod': 'cash'},
    ];
    final totals = salesTotals(sales);
    expect(totals['manual'], 1400);
    expect(totals['inventory'], 500);
    expect(totals['profit'], 500);
    expect(totals['debtIncrease'], 1400);
    expect(isManualSale(sales.first), isTrue);
  });
}
