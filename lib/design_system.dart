import 'package:flutter/material.dart';

import 'home_widgets.dart' show formatMoney;

const qaidiRadius = 18.0;
const qaidiPagePadding = EdgeInsets.all(18);

class QaidiSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;
  const QaidiSectionHeader({super.key, required this.title, this.subtitle, this.action});
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      if (subtitle != null) Text(subtitle!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
    ])),
    if (action != null) action!,
  ]);
}

class QaidiStatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const QaidiStatusPill({super.key, required this.label, required this.color, required this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(30)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 15, color: color), const SizedBox(width: 5), Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12))]),
  );
}

class QaidiMetricTile extends StatelessWidget {
  final String title;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;
  const QaidiMetricTile({super.key, required this.title, required this.value, required this.caption, required this.icon, required this.color});
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: IntrinsicHeight(child: Row(children: [
      Container(width: 5, color: color),
      Expanded(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w700)), const SizedBox(height: 2), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)), Text(caption, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant))])),
      ]))),
    ])),
  );
}

/// عنوان موحد لصفحات التبويبات الرئيسية.
class QaidiPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const QaidiPageHeader({super.key, required this.title, this.subtitle, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
        if (subtitle != null) Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(subtitle!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ),
      ])),
      if (trailing != null) trailing!,
    ]),
  );
}

/// أيقونة داخل مربع مستدير بلون ناعم.
class QaidiIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const QaidiIconBadge({super.key, required this.icon, required this.color, this.size = 40});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(size * .32)),
    child: Icon(icon, color: color, size: size * .52),
  );
}

/// بطاقة ملخص متدرجة اللون مع مؤشرات صغيرة أسفلها.
class QaidiGradientSummary extends StatelessWidget {
  final String title;
  final String value;
  final String caption;
  final List<MapEntry<String, String>> stats;
  const QaidiGradientSummary({super.key, required this.title, required this.value, required this.caption, this.stats = const []});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
        colors: [Color(0xFF047857), Color(0xFF0369A1)],
      ),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 6),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 32)),
      ),
      const SizedBox(height: 2),
      Text(caption, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      if (stats.isNotEmpty) ...[
        const SizedBox(height: 14),
        Row(children: [
          for (final stat in stats)
            Expanded(child: Container(
              margin: const EdgeInsetsDirectional.only(end: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: .16), borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(stat.key, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                const SizedBox(height: 2),
                Text(stat.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            )),
        ]),
      ],
    ]),
  );
}

/// شريط يقسم المبيعات بين النقدي والآجل.
class QaidiSplitBar extends StatelessWidget {
  final int cash;
  final int credit;
  const QaidiSplitBar({super.key, required this.cash, required this.credit});
  @override
  Widget build(BuildContext context) {
    if (cash + credit <= 0) return const SizedBox.shrink();
    const cashColor = Color(0xFF10B981);
    const creditColor = Color(0xFFF59E0B);
    Widget legend(String label, int amount, Color color) => Expanded(child: Row(children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Expanded(child: Text('$label ${formatMoney(amount)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
    ]));
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('نقدي مقابل آجل', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(height: 12, child: Row(children: [
            if (cash > 0) Expanded(flex: cash, child: Container(color: cashColor)),
            if (credit > 0) Expanded(flex: credit, child: Container(color: creditColor)),
          ])),
        ),
        const SizedBox(height: 12),
        Row(children: [legend('نقدي', cash, cashColor), legend('آجل', credit, creditColor)]),
      ]),
    ));
  }
}
