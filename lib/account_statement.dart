import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native_api.dart';
import 'package_rules.dart';
import 'whatsapp_utils.dart';

const Color _accountGreen = Color(0xFF10B981);

Map<String, dynamic> _accountMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<dynamic> _accountList(dynamic value) =>
    value is List ? value : <dynamic>[];
int _accountInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
String _accountPhoneKey(String value) {
  final localized = String.fromCharCodes(value.runes.map((rune) {
    if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
    if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
    return rune;
  }));
  var digits = localized.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00967')) {
    digits = digits.substring(5);
  } else if (digits.startsWith('967')) {
    digits = digits.substring(3);
  }
  return digits.replaceFirst(RegExp(r'^0+'), '').takeLast(10);
}

String _accountMoney(int value) =>
    '${NumberFormat('#,##0', 'en').format(value.abs())} ر.ي';
DateTime _accountDate(Map<String, dynamic> value) =>
    DateTime.tryParse('${value['createdAt'] ?? value['time'] ?? ''}') ??
    DateTime.fromMillisecondsSinceEpoch(0);

extension _TakeLastAccount on String {
  String takeLast(int count) =>
      length <= count ? this : substring(length - count);
}

class AccountStatementPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final String phone;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onSell;

  const AccountStatementPage({
    super.key,
    required this.data,
    required this.phone,
    required this.onRefresh,
    required this.onSell,
  });

  @override
  State<AccountStatementPage> createState() => _AccountStatementPageState();
}

class _AccountStatementPageState extends State<AccountStatementPage> {
  late Map<String, dynamic> data;
  DateTimeRange? range;
  String filter = 'all';

  @override
  void initState() {
    super.initState();
    data = widget.data;
  }

  String get clientName {
    final key = _accountPhoneKey(widget.phone);
    for (final source in [data['permissions'], data['trusted']]) {
      final items = source == data['permissions']
          ? _accountList(_accountMap(source)['clients'])
          : _accountList(_accountMap(source)['clients']);
      for (final item in items) {
        final client = _accountMap(item);
        if (_accountPhoneKey('${client['phone'] ?? ''}') == key &&
            '${client['name'] ?? ''}'.trim().isNotEmpty) {
          return '${client['name']}'.trim();
        }
      }
    }
    final entries = _allTransactions;
    for (final entry in entries.reversed) {
      if (_accountPhoneKey('${entry['phone'] ?? ''}') == key &&
          '${entry['clientName'] ?? ''}'.trim().isNotEmpty) {
        return '${entry['clientName']}'.trim();
      }
    }
    return widget.phone;
  }

  List<Map<String, dynamic>> get _allTransactions {
    final key = _accountPhoneKey(widget.phone);
    final entries = _accountList(data['transactions'])
        .map(_accountMap)
        .where((entry) => _accountPhoneKey('${entry['phone'] ?? ''}') == key)
        .toList();
    entries.sort((a, b) => _accountDate(a).compareTo(_accountDate(b)));
    return entries;
  }

  int get _currentBalance => _allTransactions.fold<int>(
        0,
        (sum, entry) =>
            sum +
            (entry['affectsBalance'] == false
                ? 0
                : _accountInt(entry['delta'])),
      );

  List<Map<String, dynamic>> get _visibleTransactions {
    final entries = _allTransactions;
    return entries.where((entry) {
      final date = _accountDate(entry);
      if (range != null &&
          (date.isBefore(DateTime(
                  range!.start.year, range!.start.month, range!.start.day)) ||
              date.isAfter(DateTime(range!.end.year, range!.end.month,
                  range!.end.day, 23, 59, 59)))) {
        return false;
      }
      switch (filter) {
        case 'sales':
          return '${entry['type']}'.startsWith('sale_') ||
              entry['type'] == 'legacy_sale';
        case 'receipts':
          return entry['type'] == 'receipt';
        case 'adjustments':
          return '${entry['type']}'.startsWith('adjustment_');
        default:
          return true;
      }
    }).toList();
  }

  int _openingBalanceForRange() {
    if (range == null) return 0;
    final start =
        DateTime(range!.start.year, range!.start.month, range!.start.day);
    return _allTransactions
        .where((entry) => _accountDate(entry).isBefore(start))
        .fold<int>(
            0,
            (sum, entry) =>
                sum +
                (entry['affectsBalance'] == false
                    ? 0
                    : _accountInt(entry['delta'])));
  }

  List<Map<String, dynamic>> _visibleWithBalance() {
    var runningBalance = _openingBalanceForRange();
    return _visibleTransactions.map((entry) {
      if (entry['affectsBalance'] != false)
        runningBalance += _accountInt(entry['delta']);
      return {...entry, '_balanceAfter': runningBalance};
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final balance = _currentBalance;
    final rows = _visibleWithBalance();
    rows.sort((a, b) => _accountDate(b).compareTo(_accountDate(a)));
    final totalReceipts = _allTransactions
        .where((e) => e['type'] == 'receipt')
        .fold<int>(0, (sum, e) => sum + _accountInt(e['amount']));
    final creditSales = _allTransactions
        .where((e) => e['type'] == 'sale_credit')
        .fold<int>(0, (sum, e) => sum + _accountInt(e['amount']));

    return Scaffold(
      appBar: AppBar(
        title: const Text('ملف العميل'),
        actions: [
          IconButton(
            tooltip: 'فلترة بالتاريخ',
            onPressed: _chooseRange,
            icon:
                Icon(range == null ? Icons.date_range : Icons.event_available),
          ),
          IconButton(
            tooltip: 'مشاركة كشف الحساب',
            onPressed: _shareMenu,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _clientProfileCard(balance),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _metricCard(
                        icon: Icons.credit_score_outlined,
                        label: 'مبيعات آجل',
                        value: _accountMoney(creditSales),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricCard(
                        icon: Icons.payments_outlined,
                        label: 'دفعات مستلمة',
                        value: _accountMoney(totalReceipts),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricCard(
                        icon: Icons.receipt_long_outlined,
                        label: 'الحركات',
                        value: '${_allTransactions.length}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _recordReceipt,
                        icon: const Icon(Icons.payments_outlined),
                        label: const Text('استلام دفعة'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _sell,
                        icon: const Icon(Icons.confirmation_number_outlined),
                        label: const Text('صرف كرت'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _action('تعديل / إضافة الدين', Icons.edit_note,
                          _setManualDebtBalance),
                      _action('قيد تسوية', Icons.tune, _recordAdjustment),
                      _action('مشاركة الكشف', Icons.ios_share, _shareMenu),
                      _action(
                          'تذكير تحصيل',
                          Icons.notifications_active_outlined,
                          _collectionReminder),
                      _action('طباعة ملف العميل', Icons.print_outlined,
                          () => _pdfAction('print')),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text('كشف الحساب',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w900,
                                  )),
                    ),
                    Text('${rows.length} حركة',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                if (range != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: _accountGreen.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'الفترة ${DateFormat('yyyy/MM/dd').format(range!.start)} – ${DateFormat('yyyy/MM/dd').format(range!.end)} • رصيد بدايتها ${_accountMoney(_openingBalanceForRange())}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('all', 'الكل'),
                      _filterChip('sales', 'المبيعات'),
                      _filterChip('receipts', 'الدفعات'),
                      _filterChip('adjustments', 'التسويات'),
                      if (range != null)
                        TextButton.icon(
                          onPressed: () => setState(() => range = null),
                          icon: const Icon(Icons.clear),
                          label: const Text('إلغاء الفترة'),
                        ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          if (rows.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.account_balance_wallet_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 10),
                      Text(
                        _allTransactions.isEmpty
                            ? 'لا توجد حركات مسجلة لهذا العميل بعد.'
                            : 'لا توجد حركات تطابق الفترة أو نوع الحركة المحدد.',
                        textAlign: TextAlign.center,
                      ),
                      if (_allTransactions.isNotEmpty &&
                          (range != null || filter != 'all')) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => setState(() {
                            range = null;
                            filter = 'all';
                          }),
                          icon: const Icon(Icons.filter_alt_off_outlined),
                          label: const Text('مسح المرشحات'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _transactionTile(rows[index]),
                  childCount: rows.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _clientProfileCard(int balance) {
    final balanceLabel = balance > 0
        ? 'المطلوب تحصيله'
        : balance < 0
            ? 'رصيد دائن للعميل'
            : 'الحساب مسدد';
    final statusLabel = balance > 0
        ? 'عليه رصيد'
        : balance < 0
            ? 'له رصيد'
            : 'مسدد';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [Color(0xFF0C6B58), Color(0xFF10B981)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: _accountGreen.withValues(alpha: .20),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: Colors.white.withValues(alpha: .16),
                child: const Icon(Icons.person_outline,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clientName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(widget.phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: .88))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: .18)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(balanceLabel,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(statusLabel,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      _accountMoney(balance),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 27,
                          fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
  }) =>
      Container(
        constraints: const BoxConstraints(minHeight: 104),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _accountGreen, size: 19),
            const SizedBox(height: 7),
            _SummaryValue(label: label, value: value),
          ],
        ),
      );

  Widget _action(String label, IconData icon, Future<void> Function() action) =>
      OutlinedButton.icon(
          onPressed: action, icon: Icon(icon, size: 18), label: Text(label));

  Widget _filterChip(String value, String label) => Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: filter == value,
          onSelected: (_) => setState(() => filter = value),
        ),
      );

  Widget _transactionTile(Map<String, dynamic> entry) {
    final type = '${entry['type'] ?? ''}';
    final delta = _accountInt(entry['delta']);
    final legacy = entry['affectsBalance'] == false;
    final label = _typeLabel(type);
    final color = legacy || delta == 0
        ? Colors.blueGrey
        : delta > 0
            ? Colors.deepOrange
            : _accountGreen;
    final icon = legacy || delta == 0
        ? Icons.receipt_long
        : delta > 0
            ? Icons.north_east
            : Icons.south_west;
    final date = _accountDate(entry);
    final amount = _accountInt(entry['amount']);
    final payment = _paymentLabel('${entry['paymentMethod'] ?? ''}');
    final notes = '${entry['note'] ?? ''}'.trim();
    return Card(
      child: ListTile(
        leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: .12),
            child: Icon(icon, color: color)),
        title: Text(label),
        subtitle: Text([
          DateFormat('yyyy/MM/dd  HH:mm').format(date),
          if (payment.isNotEmpty) payment,
          if ('${entry['reference'] ?? ''}'.trim().isNotEmpty)
            'مرجع: ${entry['reference']}',
          if (notes.isNotEmpty) notes,
          if (entry['packageId'] != null && '${entry['packageId']}'.isNotEmpty)
            'باقة ${entry['packageId']}',
          if (legacy) 'سجل تاريخي؛ لا يغيّر رصيد ما قبل ترحيل الدفتر',
        ].join(' • ')),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              legacy
                  ? _accountMoney(amount)
                  : delta == 0
                      ? _accountMoney(amount)
                      : '${delta > 0 ? '+' : '−'}${_accountMoney(amount)}',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            Text('الرصيد ${_accountMoney(_accountInt(entry['_balanceAfter']))}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'opening_balance' => 'رصيد افتتاحي',
        'legacy_sale' => 'بيع سابق (من السجل القديم)',
        'sale_credit' => 'بيع كرت — آجل',
        'sale_cash' => 'بيع كرت — نقداً',
        'receipt' => 'استلام دفعة من العميل',
        'adjustment_debit' => 'تسوية — إضافة مديونية',
        'adjustment_credit' => 'تسوية — تخفيض المديونية',
        'refund' => 'رد مبلغ للعميل',
        _ => type.isEmpty ? 'حركة حساب' : type,
      };

  String _paymentLabel(String method) => switch (method) {
        'cash' => 'نقداً',
        'credit' => 'آجل',
        'bank' => 'تحويل بنكي',
        'wallet' => 'محفظة إلكترونية',
        _ => method,
      };

  Future<void> _chooseRange() async {
    final today = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 10),
      lastDate: DateTime(today.year, today.month, today.day),
      initialDateRange: range,
      helpText: 'اختر فترة كشف الحساب',
      saveText: 'تطبيق',
    );
    if (selected != null && mounted) setState(() => range = selected);
  }

  Future<void> _recordReceipt() async {
    final amountController = TextEditingController();
    final referenceController = TextEditingController();
    final noteController = TextEditingController();
    String method = 'cash';
    final input = await showDialog<_ReceiptInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('استلام دفعة من العميل'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('الرصيد الحالي: ${_accountMoney(_currentBalance)}'),
                  TextField(
                    controller: amountController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'المبلغ المستلم (ر.ي)'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: method,
                    decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                    items: const [
                      DropdownMenuItem(value: 'cash', child: Text('نقداً')),
                      DropdownMenuItem(
                          value: 'bank', child: Text('تحويل بنكي')),
                      DropdownMenuItem(
                          value: 'wallet', child: Text('محفظة إلكترونية')),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => method = value ?? 'cash'),
                  ),
                  TextField(
                      controller: referenceController,
                      decoration: const InputDecoration(
                          labelText: 'رقم المرجع / السند (اختياري)')),
                  TextField(
                      controller: noteController,
                      decoration: const InputDecoration(
                          labelText: 'ملاحظات (اختياري)')),
                  const SizedBox(height: 8),
                  Text(
                      'الرصيد بعد الدفعة: ${_accountMoney(_currentBalance - (_accountInt(amountController.text)))}'),
                  if (_currentBalance - _accountInt(amountController.text) < 0)
                    const Text('سيظهر الفرق كرصيد دائن للعميل.',
                        style: TextStyle(color: Colors.deepOrange)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final amount = int.tryParse(amountController.text) ?? 0;
                if (amount <= 0) return;
                Navigator.pop(
                    context,
                    _ReceiptInput(
                        amount,
                        method,
                        referenceController.text.trim(),
                        noteController.text.trim()));
              },
              child: const Text('تأكيد وحفظ'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    referenceController.dispose();
    noteController.dispose();
    if (input == null) return;
    if (input.amount > _currentBalance) {
      final confirm = await _confirm(
        'المبلغ أكبر من المديونية الحالية. سيظهر الفرق كرصد دائن للعميل. هل تريد المتابعة؟',
      );
      if (!confirm) return;
    }
    await _runOperation(() => NativeApi.instance.recordReceipt(
          phone: widget.phone,
          amount: input.amount,
          paymentMethod: input.method,
          reference: input.reference,
          note: input.note,
          clientName: clientName,
        ));
  }

  Future<void> _recordAdjustment() async {
    final amountController = TextEditingController();
    final reasonController = TextEditingController();
    String direction = 'increase';
    final input = await showDialog<_AdjustmentInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('قيد تسوية الحساب'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('الرصيد الحالي: ${_accountMoney(_currentBalance)}'),
                  DropdownButtonFormField<String>(
                    initialValue: direction,
                    decoration: const InputDecoration(labelText: 'نوع التسوية'),
                    items: const [
                      DropdownMenuItem(
                          value: 'increase',
                          child: Text('إضافة مديونية على العميل')),
                      DropdownMenuItem(
                          value: 'decrease',
                          child: Text('تخفيض المديونية / إضافة رصيد للعميل')),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => direction = value ?? 'increase'),
                  ),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'مبلغ التسوية (ر.ي)'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  TextField(
                    controller: reasonController,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'سبب التسوية (إجباري)'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                      'الرصيد بعد التسوية: ${_accountMoney(_currentBalance + (direction == 'increase' ? 1 : -1) * _accountInt(amountController.text))}'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final amount = int.tryParse(amountController.text) ?? 0;
                if (amount <= 0 || reasonController.text.trim().isEmpty) return;
                Navigator.pop(
                    context,
                    _AdjustmentInput(
                        amount, direction, reasonController.text.trim()));
              },
              child: const Text('تأكيد التسوية'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    reasonController.dispose();
    if (input == null) return;
    final willCreateCredit =
        input.direction == 'decrease' && input.amount > _currentBalance;
    if (willCreateCredit &&
        !await _confirm(
            'ستتجاوز التسوية المديونية الحالية وينشأ رصيد دائن للعميل. هل تريد المتابعة؟'))
      return;
    await _runOperation(() => NativeApi.instance.recordAdjustment(
          phone: widget.phone,
          amount: input.amount,
          direction: input.direction,
          reason: input.reason,
          clientName: clientName,
        ));
  }

  Future<void> _setManualDebtBalance() async {
    final amountController = TextEditingController(
        text: (_currentBalance > 0 ? _currentBalance : 0).toString());
    final reasonController = TextEditingController();
    String? validationError;
    final input = await showDialog<_ManualDebtInput>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final target =
              PackageRules.parseNonNegativeAmount(amountController.text);
          return AlertDialog(
            title: const Text('تعديل رصيد الدين يدويًا'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('الرصيد الحالي: ${_accountMoney(_currentBalance)}'),
                    TextField(
                      controller: amountController,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'الرصيد الجديد المطلوب (ر.ي)'),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    TextField(
                      controller: reasonController,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'سبب التعديل (إجباري)'),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    if (target != null) ...[
                      const SizedBox(height: 8),
                      Text('الرصيد بعد التعديل: ${_accountMoney(target)}'),
                    ],
                    if (validationError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(validationError!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'سيُسجّل الفرق كحركة تسوية جديدة مع السبب؛ لن تُعدّل الحركات السابقة.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء')),
              FilledButton(
                onPressed: () {
                  final parsed = PackageRules.parseNonNegativeAmount(
                      amountController.text);
                  final reason = reasonController.text.trim();
                  if (parsed == null || reason.isEmpty) {
                    setDialogState(() => validationError = parsed == null
                        ? 'أدخل مبلغًا صحيحًا يساوي صفرًا أو أكثر.'
                        : 'سبب التعديل مطلوب.');
                    return;
                  }
                  Navigator.pop(
                      dialogContext, _ManualDebtInput(parsed, reason));
                },
                child: const Text('حفظ الرصيد'),
              ),
            ],
          );
        },
      ),
    );
    amountController.dispose();
    reasonController.dispose();
    if (input == null) return;
    if (input.targetBalance == _currentBalance) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('الرصيد المدخل يساوي الرصيد الحالي.')));
      }
      return;
    }
    await _runOperation(() => NativeApi.instance.setManualDebtBalance(
          phone: widget.phone,
          targetBalance: input.targetBalance,
          reason: input.reason,
          clientName: clientName,
        ));
  }

  Future<void> _sell() async {
    await widget.onSell();
    if (mounted) setState(() => data = NativeApi.instance.snapshot);
  }

  Future<bool> _confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('متابعة')),
          ],
        ),
      ) ??
      false;

  Future<void> _runOperation(
      Future<Map<String, dynamic>> Function() operation) async {
    try {
      final fresh = await operation();
      if (!mounted) return;
      setState(() => data = fresh);
      await widget.onRefresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل الحركة وتحديث الحساب.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر حفظ الحركة: $e')));
    }
  }

  Future<void> _shareMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            const ListTile(title: Text('مشاركة كشف الحساب')),
            ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('تجهيز تذكير تحصيل بالمبلغ المستحق'),
                onTap: () {
                  Navigator.pop(context);
                  _collectionReminder();
                }),
            ListTile(
                leading: const Icon(Icons.chat),
                title: const Text('فتح واتساب برسالة جاهزة'),
                onTap: () {
                  Navigator.pop(context);
                  _openWhatsApp();
                }),
            ListTile(
                leading: const Icon(Icons.sms_outlined),
                title: const Text('فتح رسالة SMS للمراجعة'),
                onTap: () {
                  Navigator.pop(context);
                  _openSmsComposer();
                }),
            ListTile(
                leading: const Icon(Icons.picture_as_pdf),
                title: const Text('مشاركة PDF'),
                onTap: () {
                  Navigator.pop(context);
                  _pdfAction('share');
                }),
            ListTile(
                leading: const Icon(Icons.print),
                title: const Text('طباعة PDF'),
                onTap: () {
                  Navigator.pop(context);
                  _pdfAction('print');
                }),
            ListTile(
                leading: const Icon(Icons.save_alt),
                title: const Text('حفظ PDF في الملفات'),
                onTap: () {
                  Navigator.pop(context);
                  _pdfAction('save');
                }),
            ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('نسخ النص'),
                onTap: () {
                  Navigator.pop(context);
                  _copyStatement();
                }),
            ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('مشاركة كنص'),
                onTap: () {
                  Navigator.pop(context);
                  Share.share(_statementText(),
                      subject: 'كشف حساب $clientName');
                }),
          ],
        ),
      ),
    );
  }

  String _statementText() {
    final balance = _currentBalance;
    final lines = <String>[
      'كشف حساب العميل — القاضي نت',
      'العميل: $clientName',
      'الهاتف: ${widget.phone}',
      if (range != null)
        'الفترة: ${DateFormat('yyyy/MM/dd').format(range!.start)} إلى ${DateFormat('yyyy/MM/dd').format(range!.end)}',
      'المطلوب تحصيله: ${_accountMoney(balance > 0 ? balance : 0)}',
      'الرصيد الدائن للعميل: ${_accountMoney(balance < 0 ? -balance : 0)}',
      'الحركات:',
    ];
    for (final entry in _visibleWithBalance()) {
      final amount = _accountInt(entry['amount']);
      final delta = _accountInt(entry['delta']);
      final date = DateFormat('yyyy/MM/dd HH:mm').format(_accountDate(entry));
      lines.add(
          '$date | ${_typeLabel('${entry['type']}')} | ${delta == 0 ? '' : delta > 0 ? '+' : '−'}${_accountMoney(amount)} | الرصيد بعد الحركة ${_accountMoney(_accountInt(entry['_balanceAfter']))}${'${entry['note'] ?? ''}'.trim().isEmpty ? '' : ' | ${entry['note']}'}');
    }
    return lines.join('\n');
  }

  Future<void> _openWhatsApp() async {
    final uri = whatsappChatUri(widget.phone, message: _statementText());
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('رقم العميل غير صالح لفتح WhatsApp.'),
        ));
      }
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب.')));
    }
  }

  Future<void> _openSmsComposer() async {
    try {
      await NativeApi.instance.openSmsComposer(widget.phone, _statementText());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر فتح تطبيق الرسائل: $error')),
        );
      }
    }
  }

  Future<void> _collectionReminder() async {
    if (_currentBalance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('لا يوجد مبلغ مستحق للتحصيل من هذا العميل.'),
      ));
      return;
    }
    final channel = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(children: [
          const ListTile(
              title: Text('سيُفتح النص للمراجعة ولن يُرسل تلقائياً')),
          ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('واتساب'),
              onTap: () => Navigator.pop(context, 'wa')),
          ListTile(
              leading: const Icon(Icons.sms_outlined),
              title: const Text('SMS'),
              onTap: () => Navigator.pop(context, 'sms')),
        ]),
      ),
    );
    if (channel == null) return;
    final templates = _accountMap(_accountMap(data['trigger'])['templates']);
    final raw = '${templates['collectionReminder'] ?? ''}'.trim();
    final message = (raw.isEmpty
            ? 'مرحباً {name}، نذكركم بأن المبلغ المستحق هو {amount} ر.ي. نرجو التواصل مع القاضي نت.'
            : raw)
        .replaceAll('{name}', clientName)
        .replaceAll('{phone}', widget.phone)
        .replaceAll('{amount}', _currentBalance.toString());
    try {
      if (channel == 'sms') {
        await NativeApi.instance.openSmsComposer(widget.phone, message);
      } else {
        final uri = whatsappChatUri(widget.phone, message: message);
        if (uri == null) throw StateError('رقم العميل غير صالح لفتح WhatsApp');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('تعذر فتح واتساب');
        }
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تعذر فتح تطبيق المراسلة: $error')));
    }
  }

  Future<void> _copyStatement() async {
    await Clipboard.setData(ClipboardData(text: _statementText()));
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تم نسخ كشف الحساب.')));
  }

  Future<Uint8List> _buildPdf() async {
    final regular = pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf'));
    final bold = pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoNaskhArabic-Bold.ttf'));
    final rows = _visibleTransactions;
    var running = _openingBalanceForRange();
    final balanceAfter = <String, int>{};
    for (final entry in rows) {
      if (entry['affectsBalance'] != false)
        running += _accountInt(entry['delta']);
      balanceAfter['${entry['id']}'] = running;
    }
    final pdf =
        pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        build: (_) => [
          pw.Text('القاضي نت — ملف العميل وكشف الحساب',
              style:
                  pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Text('الاسم: $clientName'),
          pw.Text('الهاتف: ${widget.phone}'),
          if (range != null)
            pw.Text(
                'الفترة: ${DateFormat('yyyy/MM/dd').format(range!.start)} إلى ${DateFormat('yyyy/MM/dd').format(range!.end)}'),
          pw.SizedBox(height: 8),
          pw.Text(
              'المطلوب تحصيله: ${_accountMoney(_currentBalance > 0 ? _currentBalance : 0)}'),
          pw.Text(
              'الرصيد الدائن للعميل: ${_accountMoney(_currentBalance < 0 ? -_currentBalance : 0)}'),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: [
              'التاريخ',
              'النوع',
              'المبلغ',
              'الرصيد بعد الحركة',
              'ملاحظات'
            ],
            data: rows.reversed.map((entry) {
              final delta = _accountInt(entry['delta']);
              return [
                DateFormat('yyyy/MM/dd HH:mm').format(_accountDate(entry)),
                _typeLabel('${entry['type']}'),
                '${delta > 0 ? '+' : delta < 0 ? '−' : ''}${_accountMoney(_accountInt(entry['amount']))}',
                _accountMoney(
                    balanceAfter['${entry['id']}'] ?? _currentBalance),
                '${entry['note'] ?? ''}',
              ];
            }).toList(),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignment: pw.Alignment.centerRight,
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerPadding: const pw.EdgeInsets.all(5),
            cellPadding: const pw.EdgeInsets.all(5),
          ),
          pw.SizedBox(height: 12),
          pw.Text(
              'تم إنشاء الكشف في ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
    );
    return Uint8List.fromList(await pdf.save());
  }

  Future<void> _pdfAction(String action) async {
    try {
      final bytes = await _buildPdf();
      final name = 'كشف_حساب_${widget.phone.replaceAll(RegExp(r'\D'), '')}.pdf';
      if (action == 'share') {
        await Printing.sharePdf(bytes: bytes, filename: name);
      } else if (action == 'print') {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
      } else {
        await FilePicker.platform.saveFile(
            fileName: name,
            bytes: bytes,
            type: FileType.custom,
            allowedExtensions: const ['pdf']);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر إنشاء PDF: $e')));
    }
  }
}

class _SummaryValue extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryValue({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
}

class _ReceiptInput {
  final int amount;
  final String method;
  final String reference;
  final String note;
  _ReceiptInput(this.amount, this.method, this.reference, this.note);
}

class _AdjustmentInput {
  final int amount;
  final String direction;
  final String reason;
  _AdjustmentInput(this.amount, this.direction, this.reason);
}

class _ManualDebtInput {
  final int targetBalance;
  final String reason;
  _ManualDebtInput(this.targetBalance, this.reason);
}
