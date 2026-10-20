import 'package:intl/intl.dart' as intl;

Map<String, dynamic> asReportMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> reportList(dynamic value) => value is List
    ? value.map(asReportMap).toList()
    : <Map<String, dynamic>>[];

DateTime? reportDate(dynamic value) {
  final raw = '$value'.trim();
  if (raw.isEmpty || raw == 'null') return null;
  return DateTime.tryParse(raw);
}

bool isInReportPeriod(dynamic value, int days, {DateTime? now}) {
  if (days == 0) return true;
  final date = reportDate(value);
  if (date == null) return false;
  final end = now ?? DateTime.now();
  final start = DateTime(end.year, end.month, end.day)
      .subtract(Duration(days: days - 1));
  return !date.isBefore(start);
}

int reportAmount(Map<String, dynamic> sale) {
  final value = sale['price'];
  return value is num ? value.toInt() : int.tryParse('${sale['packageId']}') ?? 0;
}

bool isManualSale(Map<String, dynamic> sale) => '${sale['saleSource'] ?? ''}' == 'manual' || '${sale['packageId'] ?? ''}' == 'بيع يدوي';

int reportProfit(Map<String, dynamic> sale) {
  final value = sale['profit'];
  return value is num ? value.toInt() : int.tryParse('${sale['profit'] ?? 0}') ?? 0;
}

int reportDebtIncrease(Map<String, dynamic> sale) => '${sale['paymentMethod'] ?? ''}' == 'credit' ? reportAmount(sale) : 0;

Map<String, int> salesTotals(List<Map<String, dynamic>> sales) => {
      'all': sales.fold(0, (sum, sale) => sum + reportAmount(sale)),
      'manual': sales.where(isManualSale).fold(0, (sum, sale) => sum + reportAmount(sale)),
      'inventory': sales.where((sale) => !isManualSale(sale)).fold(0, (sum, sale) => sum + reportAmount(sale)),
      'cash': sales.where((sale) => '${sale['paymentMethod'] ?? ''}' == 'cash').fold(0, (sum, sale) => sum + reportAmount(sale)),
      'credit': sales.where((sale) => '${sale['paymentMethod'] ?? ''}' == 'credit').fold(0, (sum, sale) => sum + reportAmount(sale)),
      'profit': sales.fold(0, (sum, sale) => sum + reportProfit(sale)),
      'debtIncrease': sales.fold(0, (sum, sale) => sum + reportDebtIncrease(sale)),
    };

Map<String, int> salesByPackage(List<Map<String, dynamic>> sales) {
  final result = <String, int>{};
  for (final sale in sales) {
    final key = '${sale['packageId'] ?? 'غير محدد'}';
    result[key] = (result[key] ?? 0) + 1;
  }
  return result;
}

String buildSalesCsv(List<Map<String, dynamic>> sales) {
  final rows = <List<String>>[
    ['التاريخ', 'المصدر', 'الوصف/الباقة', 'العميل', 'الهاتف', 'المبلغ', 'الربح', 'نوع الدفع', 'الرصيد بعد'],
    ...sales.map((sale) => [
          '${sale['time'] ?? ''}',
          isManualSale(sale) ? 'يدوي' : 'من المخزون',
          '${sale['description'] ?? sale['packageId'] ?? ''}',
          '${sale['clientName'] ?? ''}',
          '${sale['phone'] ?? ''}',
          '${reportAmount(sale)}',
          '${reportProfit(sale)}',
          '${sale['paymentMethod'] ?? (sale['cash'] == true ? 'نقدي' : 'آجل')}',
          '${sale['debt'] ?? ''}',
        ]),
  ];
  String escape(String value) => '"${value.replaceAll('"', '""')}"';
  return rows.map((row) => row.map(escape).join(',')).join('\n');
}

String reportPeriodLabel(int days) => switch (days) {
      1 => 'اليوم',
      7 => 'آخر 7 أيام',
      30 => 'آخر 30 يوماً',
      _ => 'كل الفترة',
    };

String formatReportDate(dynamic value) {
  final date = reportDate(value);
  return date == null ? 'غير مؤرخ' : intl.DateFormat('yyyy/MM/dd').format(date);
}
