import 'package:flutter/material.dart';
import 'native_api.dart';

class ManualSaleSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onDone;
  const ManualSaleSheet({super.key, required this.data, required this.onDone});
  @override
  State<ManualSaleSheet> createState() => _ManualSaleSheetState();
}

class _ManualSaleSheetState extends State<ManualSaleSheet> {
  final phone = TextEditingController();
  final name = TextEditingController();
  final description = TextEditingController(text: 'بيع يدوي');
  final quantity = TextEditingController(text: '1');
  final unitPrice = TextEditingController();
  final unitCost = TextEditingController(text: '0');
  String paymentMethod = 'cash';
  bool saving = false;

  int get qty => int.tryParse(quantity.text.trim()) ?? 0;
  int get price => int.tryParse(unitPrice.text.trim()) ?? 0;
  int get cost => int.tryParse(unitCost.text.trim()) ?? 0;
  int get total => qty * price;
  int get profit => qty * (price - cost);
  int get previousDebt {
    final key = _phoneKey(phone.text);
    final debts = (widget.data['debts'] as List? ?? []);
    for (final raw in debts) {
      final debt = Map<String, dynamic>.from(raw as Map);
      if (_phoneKey('${debt['phone'] ?? ''}') == key) return int.tryParse('${debt['amount']}') ?? 0;
    }
    return 0;
  }
  int get nextDebt => previousDebt + (paymentMethod == 'credit' ? total : 0);

  String _phoneKey(String value) {
    var digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('00967')) digits = digits.substring(5);
    if (digits.startsWith('967')) digits = digits.substring(3);
    return digits.replaceFirst(RegExp(r'^0+'), '').takeLast(10);
  }

  @override
  void dispose() {
    phone.dispose(); name.dispose(); description.dispose(); quantity.dispose(); unitPrice.dispose(); unitCost.dispose(); super.dispose();
  }

  Future<void> save() async {
    if (description.text.trim().isEmpty || qty < 1 || price < 0 || cost < 0 || phone.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أكمل الوصف والهاتف والكمية والسعر بشكل صحيح.')));
      return;
    }
    setState(() => saving = true);
    try {
      final result = await NativeApi.instance.manualSale(phone: phone.text.trim(), name: name.text.trim(), description: description.text.trim(), quantity: qty, unitPrice: price, unitCost: cost, paymentMethod: paymentMethod);
      await widget.onDone();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(paymentMethod == 'credit' ? 'تم حفظ البيع اليدوي. المديونية الجديدة: ${result['balanceAfter']} ر.ي' : 'تم حفظ البيع اليدوي نقداً.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ البيع اليدوي: $error')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8), child: Row(children: [const Expanded(child: Text('بيع يدوي', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),), IconButton(onPressed: saving ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))])),
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 18), children: [
          const Text('لا يستهلك هذا البيع أي كرت من المخزون.', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(controller: description, decoration: const InputDecoration(labelText: 'وصف المنتج أو الخدمة', prefixIcon: Icon(Icons.description_outlined))),
          const SizedBox(height: 10),
          Row(children: [Expanded(child: TextField(controller: quantity, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'الكمية'))), const SizedBox(width: 10), Expanded(child: TextField(controller: unitPrice, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'سعر الوحدة'))), const SizedBox(width: 10), Expanded(child: TextField(controller: unitCost, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'التكلفة')))]),
          const SizedBox(height: 10),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم العميل (اختياري)')),
          const SizedBox(height: 10),
          TextField(controller: phone, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'رقم العميل')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(initialValue: paymentMethod, decoration: const InputDecoration(labelText: 'طريقة الدفع'), items: const [DropdownMenuItem(value: 'cash', child: Text('نقداً')), DropdownMenuItem(value: 'credit', child: Text('آجل / على الحساب'))], onChanged: (value) => setState(() => paymentMethod = value ?? 'cash')),
          const SizedBox(height: 14),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [ _line('الإجمالي', '$total ر.ي', bold: true), _line('الربح المتوقع', '$profit ر.ي'), if (paymentMethod == 'credit') ...[_line('المديونية السابقة', '$previousDebt ر.ي'), _line('المديونية الجديدة', '$nextDebt ر.ي', bold: true, color: Colors.redAccent)]]))),
        ])),
        Container(decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, boxShadow: const [BoxShadow(blurRadius: 8, color: Color(0x22000000))]), padding: const EdgeInsets.fromLTRB(16, 10, 16, 12), child: Row(children: [Expanded(child: OutlinedButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('إلغاء'))), const SizedBox(width: 10), Expanded(flex: 2, child: FilledButton.icon(onPressed: saving ? null : save, icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined), label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ البيع')))])),
      ]),
    ),
  );

  Widget _line(String label, String value, {bool bold = false, Color? color}) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [Expanded(child: Text(label)), Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w600, color: color))]));
}

extension on String {
  String takeLast(int count) => length <= count ? this : substring(length - count);
}
