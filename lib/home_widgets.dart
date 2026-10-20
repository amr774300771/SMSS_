import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import 'report_metrics.dart';

const _heroGreen = Color(0xFF047857);
const _heroBlue = Color(0xFF0369A1);

String formatMoney(num value) =>
    '${intl.NumberFormat.decimalPattern('en').format(value.round())} ر.ي';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// ملخص مبيعات يوم واحد، يُحسب من سجل المبيعات المحلي فقط.
class DailySummary {
  final int count;
  final int total;
  final int cash;
  final int credit;
  final int profit;
  final int manual;

  const DailySummary({
    this.count = 0,
    this.total = 0,
    this.cash = 0,
    this.credit = 0,
    this.profit = 0,
    this.manual = 0,
  });

  factory DailySummary.forDay(
    List<Map<String, dynamic>> sales,
    DateTime day,
  ) {
    var count = 0, total = 0, cash = 0, credit = 0, profit = 0, manual = 0;
    for (final sale in sales) {
      final date = reportDate(sale['time']);
      if (date == null || !_sameDay(date, day)) continue;
      final amount = reportAmount(sale);
      final method = '${sale['paymentMethod'] ?? 'cash'}';
      count++;
      total += amount;
      if (method == 'credit') {
        credit += amount;
      } else if (method == 'cash') {
        cash += amount;
      }
      profit += reportProfit(sale);
      if (isManualSale(sale)) manual++;
    }
    return DailySummary(
      count: count,
      total: total,
      cash: cash,
      credit: credit,
      profit: profit,
      manual: manual,
    );
  }
}

/// نسبة التغير مقارنة بالأمس؛ null إذا لم تكن هناك مبيعات أمس للمقارنة.
int? percentChange(int today, int yesterday) {
  if (yesterday <= 0) return null;
  return (((today - yesterday) / yesterday) * 100).round();
}

enum HomeAlertLevel { critical, warning, info }

class HomeAlert {
  final HomeAlertLevel level;
  final String title;
  final String detail;
  final int? targetTab;

  const HomeAlert({
    required this.level,
    required this.title,
    required this.detail,
    this.targetTab,
  });
}

int _asInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

/// يجمع التنبيهات المهمة من بيانات التطبيق في قائمة واحدة مرتبة بالأهمية.
List<HomeAlert> buildHomeAlerts(Map<String, dynamic> data) {
  final alerts = <HomeAlert>[];
  final trigger = asReportMap(data['trigger']);

  if (trigger['triggerEnabled'] != true) {
    alerts.add(const HomeAlert(
      level: HomeAlertLevel.critical,
      title: 'محرك استقبال الرسائل متوقف',
      detail: 'لن يتم الرد على طلبات العملاء حتى تفعّله من الإعدادات.',
      targetTab: 5,
    ));
  }

  final scheduled = reportList(trigger['scheduledSales']);
  final failed =
      scheduled.where((s) => '${s['status'] ?? ''}' == 'failed').length;
  final pending =
      scheduled.where((s) => '${s['status'] ?? ''}' == 'pending').length;
  if (failed > 0) {
    alerts.add(HomeAlert(
      level: HomeAlertLevel.critical,
      title: '$failed عملية بيع مجدولة فشلت',
      detail: 'افتح شاشة المبيعات لمراجعة سبب الفشل.',
      targetTab: 1,
    ));
  }
  if (pending > 0) {
    alerts.add(HomeAlert(
      level: HomeAlertLevel.info,
      title: '$pending موعد بيع مجدول بانتظار التنفيذ',
      detail: 'تأكد من استثناء التطبيق من تحسين البطارية.',
      targetTab: 1,
    ));
  }

  final inventory = asReportMap(data['inventory']);
  final totalCards = inventory.values
      .fold<int>(0, (sum, value) => sum + (value is List ? value.length : 0));
  if (inventory.isNotEmpty && totalCards == 0) {
    alerts.add(const HomeAlert(
      level: HomeAlertLevel.warning,
      title: 'المخزون فارغ',
      detail: 'استورد بطاقات جديدة حتى يستمر البيع التلقائي.',
      targetTab: 2,
    ));
  }
  for (final item in reportList(data['lowStockWarnings'])) {
    alerts.add(HomeAlert(
      level: HomeAlertLevel.warning,
      title: 'مخزون باقة ${item['packageId']} منخفض',
      detail: '${item['count']} متبقي (الحد ${item['threshold']})',
      targetTab: 2,
    ));
  }

  final debts = reportList(data['debts'])
      .where((debt) => _asInt(debt['amount']) > 0)
      .toList();
  if (debts.isNotEmpty) {
    final sum = debts.fold<int>(0, (a, debt) => a + _asInt(debt['amount']));
    alerts.add(HomeAlert(
      level: HomeAlertLevel.info,
      title: '${debts.length} عميل عليهم مديونية',
      detail: 'الإجمالي ${formatMoney(sum)}',
      targetTab: 3,
    ));
  }

  alerts.sort((a, b) => a.level.index.compareTo(b.level.index));
  return alerts;
}

/// أعلى المدينين مرتبين تنازلياً (المبالغ الموجبة فقط).
List<Map<String, dynamic>> topDebtors(
  List<Map<String, dynamic>> debts, {
  int limit = 3,
}) {
  final positive = debts.where((debt) => _asInt(debt['amount']) > 0).toList()
    ..sort((a, b) => _asInt(b['amount']).compareTo(_asInt(a['amount'])));
  return positive.take(limit).toList();
}

/// نص ملخص إغلاق اليوم للمشاركة. لا يتضمن أرقام بطاقات ولا أرقام عملاء.
String buildDailyCloseText({
  required DateTime day,
  required DailySummary summary,
  required int stockCount,
  required int totalDebt,
  List<String> lowStock = const [],
}) {
  final date = intl.DateFormat('yyyy/MM/dd').format(day);
  final lines = <String>[
    'إغلاق يوم $date — القاضي نت',
    '',
    'عدد العمليات: ${summary.count}',
    'إجمالي المبيعات: ${formatMoney(summary.total)}',
    '• نقدي: ${formatMoney(summary.cash)}',
    '• آجل: ${formatMoney(summary.credit)}',
    'المبيعات اليدوية: ${summary.manual}',
    'الربح: ${formatMoney(summary.profit)}',
    '',
    'المخزون المتاح: $stockCount بطاقة',
    'إجمالي مديونية العملاء: ${formatMoney(totalDebt)}',
  ];
  if (lowStock.isNotEmpty) {
    lines
      ..add('')
      ..add('باقات منخفضة المخزون: ${lowStock.join('، ')}');
  }
  return lines.join('\n');
}

class QaidiHeroCard extends StatelessWidget {
  final DailySummary today;
  final DailySummary yesterday;
  final bool engineOn;
  final int stockCount;

  const QaidiHeroCard({
    super.key,
    required this.today,
    required this.yesterday,
    required this.engineOn,
    required this.stockCount,
  });

  @override
  Widget build(BuildContext context) {
    final change = percentChange(today.total, yesterday.total);
    final up = (change ?? 0) >= 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [_heroGreen, _heroBlue],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: _heroGreen.withValues(alpha: .28),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('مبيعات اليوم',
                style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.circle,
                    size: 9,
                    color: engineOn ? const Color(0xFF86EFAC) : Colors.orange),
                const SizedBox(width: 6),
                Text(engineOn ? 'المحرك نشط' : 'المحرك متوقف',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(formatMoney(today.total),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 34)),
          ),
          const SizedBox(height: 4),
          if (change != null)
            Row(children: [
              Icon(up ? Icons.trending_up : Icons.trending_down,
                  size: 18,
                  color: up ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5)),
              const SizedBox(width: 5),
              Text('${up ? '+' : ''}$change% مقارنة بأمس',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5)),
            ])
          else
            const Text('لا توجد مبيعات أمس للمقارنة',
                style: TextStyle(color: Colors.white70, fontSize: 12.5)),
          const SizedBox(height: 16),
          Row(children: [
            _heroStat('العمليات', '${today.count}'),
            _heroStat('الربح', formatMoney(today.profit)),
            _heroStat('المخزون', '$stockCount'),
          ]),
        ],
      ),
    );
  }

  Widget _heroStat(String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsetsDirectional.only(end: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13)),
            ],
          ),
        ),
      );
}

class QaidiQuickAction {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const QaidiQuickAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class QaidiQuickActions extends StatelessWidget {
  final List<QaidiQuickAction> actions;

  const QaidiQuickActions({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Material(
              color: actions[i].color.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: actions[i].onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(actions[i].icon, color: actions[i].color, size: 26),
                      const SizedBox(height: 7),
                      Text(
                        actions[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class QaidiAlertsCard extends StatelessWidget {
  final List<HomeAlert> alerts;
  final ValueChanged<int> onOpen;

  const QaidiAlertsCard({super.key, required this.alerts, required this.onOpen});

  Color _color(HomeAlertLevel level) => switch (level) {
        HomeAlertLevel.critical => const Color(0xFFDC2626),
        HomeAlertLevel.warning => const Color(0xFFF59E0B),
        HomeAlertLevel.info => const Color(0xFF0284C7),
      };

  IconData _icon(HomeAlertLevel level) => switch (level) {
        HomeAlertLevel.critical => Icons.error_outline,
        HomeAlertLevel.warning => Icons.warning_amber_rounded,
        HomeAlertLevel.info => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.notifications_active_outlined, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('مركز التنبيهات',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              ),
              if (alerts.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: _color(alerts.first.level).withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${alerts.length}',
                      style: TextStyle(
                          color: _color(alerts.first.level),
                          fontWeight: FontWeight.w900,
                          fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 6),
            if (alerts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  const Icon(Icons.check_circle,
                      color: Color(0xFF10B981), size: 20),
                  const SizedBox(width: 8),
                  Text('كل شيء يعمل بشكل جيد',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              )
            else
              for (final alert in alerts.take(5))
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: alert.targetTab == null
                      ? null
                      : () => onOpen(alert.targetTab!),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _color(alert.level).withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(_icon(alert.level),
                            color: _color(alert.level), size: 19),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(alert.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 13)),
                            Text(alert.detail,
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 11.5)),
                          ],
                        ),
                      ),
                      if (alert.targetTab != null)
                        Icon(Icons.chevron_left,
                            color: scheme.onSurfaceVariant, size: 20),
                    ]),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class QaidiTopDebtorsCard extends StatelessWidget {
  final List<Map<String, dynamic>> debtors;
  final String Function(String phone) nameOf;
  final VoidCallback onOpenClients;

  const QaidiTopDebtorsCard({
    super.key,
    required this.debtors,
    required this.nameOf,
    required this.onOpenClients,
  });

  @override
  Widget build(BuildContext context) {
    if (debtors.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final maxAmount = debtors
        .map((debt) => _asInt(debt['amount']))
        .fold<int>(1, (a, b) => b > a ? b : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(
                child: Text('أعلى المديونيات',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              ),
              TextButton(onPressed: onOpenClients, child: const Text('العملاء')),
            ]),
            for (final debt in debtors) ...[
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(nameOf('${debt['phone'] ?? ''}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Text(formatMoney(_asInt(debt['amount'])),
                    style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFD97706))),
              ]),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _asInt(debt['amount']) / maxAmount,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: const Color(0xFFF59E0B),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// إجمالي المديونيات الموجبة لكل العملاء.
int totalOutstandingDebt(List<Map<String, dynamic>> debts) =>
    debts.fold<int>(0, (sum, debt) {
      final amount = _asInt(debt['amount']);
      return amount > 0 ? sum + amount : sum;
    });
