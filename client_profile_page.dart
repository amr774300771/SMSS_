import 'package:flutter/material.dart';

import 'account_statement.dart';
import 'native_api.dart';
import 'phone_normalizer.dart';

/// ملف العميل: يعرض دفتر الحركات كما هو محفوظ، دون إنشاء أو تعديل أي قيد مالي.
class ClientProfilePage extends StatefulWidget {
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

  @override
  State<ClientProfilePage> createState() => _ClientProfilePageState();
}

class _ClientProfilePageState extends State<ClientProfilePage> {
  late Map<String, dynamic> data;
  bool refreshing = false;

  @override
  void initState() {
    super.initState();
    data = Map<String, dynamic>.from(widget.data);
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  List<dynamic> _list(dynamic value) => value is List ? value : const [];

  int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  String _phoneKey(String value) => normalizeYemeniPhone(value);

  DateTime _date(Map<String, dynamic> value) =>
      DateTime.tryParse('${value['createdAt'] ?? value['time'] ?? ''}') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  String _money(int value) => '${value.abs()} ر.ي';

  Future<void> _refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      final fresh = await NativeApi.instance.refresh();
      if (mounted) setState(() => data = Map<String, dynamic>.from(fresh));
    } catch (_) {
      // احتفظ بآخر لقطة سليمة إذا تعذر الاتصال بالطبقة الأصلية.
      final snapshot = NativeApi.instance.snapshot;
      if (mounted && snapshot.isNotEmpty) {
        setState(() => data = Map<String, dynamic>.from(snapshot));
      }
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
    await widget.onRefresh();
  }

  List<Map<String, dynamic>> get _transactions {
    final wanted = _phoneKey(widget.phone);
    if (wanted.isEmpty) return <Map<String, dynamic>>[];
    final rows = _list(data['transactions'])
        .map(_map)
        .where((entry) => _phoneKey('${entry['phone'] ?? ''}') == wanted)
        .toList();
    rows.sort((a, b) => _date(b).compareTo(_date(a)));
    return rows;
  }

  String _name(List<Map<String, dynamic>> transactions) {
    final wanted = _phoneKey(widget.phone);
    if (wanted.isEmpty) return widget.phone;
    for (final source in [_map(data['permissions']), _map(data['trusted'])]) {
      for (final item in _list(source['clients']).map(_map)) {
        if (_phoneKey('${item['phone'] ?? ''}') == wanted &&
            '${item['name'] ?? ''}'.trim().isNotEmpty) {
          return '${item['name']}'.trim();
        }
      }
    }
    for (final item in transactions) {
      if ('${item['clientName'] ?? ''}'.trim().isNotEmpty) {
        return '${item['clientName']}'.trim();
      }
    }
    return widget.phone;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _transactions;
    final name = _name(rows);
    final balance = rows.fold<int>(
      0,
      (sum, entry) => sum +
          (entry['affectsBalance'] == false ? 0 : _int(entry['delta'])),
    );
    final sales = rows.where((entry) {
      final type = '${entry['type'] ?? ''}';
      return type.startsWith('sale_') || type == 'legacy_sale';
    }).toList();
    final receipts = rows
        .where((entry) => entry['type'] == 'receipt')
        .fold<int>(0, (sum, entry) => sum + _int(entry['amount']));

    return Scaffold(
      appBar: AppBar(
        title: const Text('ملف العميل'),
        actions: [
          IconButton(
            tooltip: 'تحديث البيانات',
            onPressed: refreshing ? null : _refresh,
            icon: refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _profile(context, name, balance),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric(context, 'المبيعات', '${sales.length}', Icons.shopping_bag_outlined)),
              const SizedBox(width: 8),
              Expanded(child: _metric(context, 'الدفعات', _money(receipts), Icons.payments_outlined)),
              const SizedBox(width: 8),
              Expanded(child: _metric(context, 'الحركات', '${rows.length}', Icons.history)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.onSell,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('بيع جديد'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AccountStatementPage(
                        data: data,
                        phone: widget.phone,
                        onRefresh: _refresh,
                        onSell: widget.onSell,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('كشف تفصيلي'),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: Text('آخر الحركات', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
              ),
              Text('${rows.length}'),
            ]),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(children: [
                    Icon(Icons.receipt_long_outlined, size: 32),
                    SizedBox(height: 8),
                    Text('لا توجد حركات مسجلة لهذا العميل بعد.'),
                    SizedBox(height: 4),
                    Text('اسحب للأسفل لتحديث البيانات.', textAlign: TextAlign.center),
                  ]),
                ),
              )
            else
              ...rows.take(30).map((entry) => _transaction(context, entry)),
          ],
        ),
      ),
    );
  }

  Widget _profile(BuildContext context, String name, int balance) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            CircleAvatar(radius: 28, child: Text(name.isEmpty ? '?' : name.characters.first)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(widget.phone),
                const SizedBox(height: 8),
                Text(
                  balance > 0 ? 'المطلوب تحصيله: ${_money(balance)}' : balance < 0 ? 'رصيد دائن: ${_money(balance)}' : 'الحساب مسدد',
                  style: TextStyle(fontWeight: FontWeight.w800, color: balance > 0 ? Colors.deepOrange : Colors.green),
                ),
              ]),
            ),
          ]),
        ),
      );

  Widget _metric(BuildContext context, String title, String value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(children: [
            Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 5),
            Text(title, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 2),
            FittedBox(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w900))),
          ]),
        ),
      );

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
    final color = delta > 0 ? Colors.deepOrange : delta < 0 ? Colors.green : Colors.blueGrey;
    final date = _date(entry);
    final dateLabel = date.millisecondsSinceEpoch == 0
        ? '${entry['createdAt'] ?? entry['time'] ?? 'تاريخ غير متوفر'}'
        : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: .12),
          child: Icon(delta > 0 ? Icons.arrow_upward : Icons.arrow_downward, color: color, size: 19),
        ),
        title: Text(title),
        subtitle: Text('$dateLabel • باقة ${entry['packageId'] ?? '-'}'),
        trailing: Text(
          delta == 0 ? _money(_int(entry['amount'])) : '${delta > 0 ? '+' : '−'}${_money(delta)}',
          style: TextStyle(color: color, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
