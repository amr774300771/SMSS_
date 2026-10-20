import 'package:flutter/material.dart';

import 'account_statement.dart';

class ClientProfilePage extends StatelessWidget {
  final Map<String, dynamic> data;
  final String phone;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onSell;

  const ClientProfilePage({
    super.key,
    required this.data,
    required this.phone,
    required this.onRefresh,
    required this.onSell,
  });

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  List<dynamic> _list(dynamic value) => value is List ? value : const [];
  int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  String _key(String value) {
    var digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('00967')) digits = digits.substring(5);
    if (digits.startsWith('967')) digits = digits.substring(3);
    return digits.replaceFirst(RegExp(r'^0+'), '').takeLast(10);
  }

  String _money(int value) => '${value.abs()} ر.ي';

  List<Map<String, dynamic>> _transactions() {
    final wanted = _key(phone);
    final rows = _list(data['transactions'])
        .map(_map)
        .where((e) => _key('${e['phone'] ?? ''}') == wanted)
        .toList();
    rows.sort((a, b) => '${b['createdAt'] ?? b['time'] ?? ''}'
        .compareTo('${a['createdAt'] ?? a['time'] ?? ''}'));
    return rows;
  }

  String _name(List<Map<String, dynamic>> transactions) {
    for (final source in [_map(data['permissions']), _map(data['trusted'])]) {
      for (final item in _list(source['clients']).map(_map)) {
        if (_key('${item['phone'] ?? ''}') == _key(phone) &&
            '${item['name'] ?? ''}'.trim().isNotEmpty) {
          return '${item['name']}'.trim();
        }
      }
    }
    for (final item in transactions) {
      if ('${item['clientName'] ?? ''}'.trim().isNotEmpty)
        return '${item['clientName']}'.trim();
    }
    return phone;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _transactions();
    final name = _name(rows);
    final balance = rows.fold<int>(
        0,
        (sum, e) =>
            sum + (e['affectsBalance'] == false ? 0 : _int(e['delta'])));
    final sales = rows
        .where((e) =>
            '${e['type']}'.startsWith('sale_') || e['type'] == 'legacy_sale')
        .toList();
    final receipts = rows
        .where((e) => e['type'] == 'receipt')
        .fold<int>(0, (sum, e) => sum + _int(e['amount']));

    return Scaffold(
      appBar: AppBar(title: const Text('ملف العميل')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _profile(context, name, balance),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: _metric(context, 'المبيعات', '${sales.length}',
                    Icons.shopping_bag_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: _metric(context, 'الدفعات', _money(receipts),
                    Icons.payments_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: _metric(
                    context, 'الحركات', '${rows.length}', Icons.history)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: onSell,
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('بيع جديد'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => AccountStatementPage(
                                data: data,
                                phone: phone,
                                onRefresh: onRefresh,
                                onSell: onSell))),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('كشف تفصيلي'))),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
                child: Text('آخر الحركات',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900))),
            Text('${rows.length}')
          ]),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('لا توجد حركات مسجلة لهذا العميل بعد.'))))
          else
            ...rows.take(30).map((entry) => _transaction(context, entry)),
        ],
      ),
    );
  }

  Widget _profile(BuildContext context, String name, int balance) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            CircleAvatar(
                radius: 28,
                child: Text(name.isEmpty ? '?' : name.characters.first)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(phone),
                  const SizedBox(height: 8),
                  Text(
                      balance > 0
                          ? 'المطلوب تحصيله: ${_money(balance)}'
                          : balance < 0
                              ? 'رصيد دائن: ${_money(balance)}'
                              : 'الحساب مسدد',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color:
                              balance > 0 ? Colors.deepOrange : Colors.green)),
                ])),
          ]),
        ),
      );

  Widget _metric(
          BuildContext context, String title, String value, IconData icon) =>
      Card(
          child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(children: [
                Icon(icon,
                    size: 19, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 5),
                Text(title, style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                FittedBox(
                    child: Text(value,
                        style: const TextStyle(fontWeight: FontWeight.w900)))
              ])));

  Widget _transaction(BuildContext context, Map<String, dynamic> entry) {
    final type = '${entry['type'] ?? ''}';
    final delta = _int(entry['delta']);
    final title = type == 'receipt'
        ? 'استلام دفعة'
        : type == 'sale_credit'
            ? 'بيع كرت — آجل'
            : type == 'sale_cash'
                ? 'بيع كرت — نقداً'
                : type == 'legacy_sale'
                    ? 'بيع سابق'
                    : type.isEmpty
                        ? 'حركة حساب'
                        : type;
    final color = delta > 0
        ? Colors.deepOrange
        : delta < 0
            ? Colors.green
            : Colors.blueGrey;
    return Card(
        child: ListTile(
            leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: .12),
                child: Icon(
                    delta > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    color: color,
                    size: 19)),
            title: Text(title),
            subtitle: Text(
                '${entry['createdAt'] ?? entry['time'] ?? ''} • باقة ${entry['packageId'] ?? '-'}'),
            trailing: Text(
                delta == 0
                    ? _money(_int(entry['amount']))
                    : '${delta > 0 ? '+' : '−'}${_money(delta)}',
                style: TextStyle(color: color, fontWeight: FontWeight.w800))));
  }
}

extension on String {
  String takeLast(int count) =>
      length <= count ? this : substring(length - count);
}
