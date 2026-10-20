import 'package:flutter/material.dart';

import 'package_rules.dart';

class ManualDebtInput {
  final String phone;
  final String name;
  final int targetBalance;
  final String reason;
  final int currentBalance;

  const ManualDebtInput({
    required this.phone,
    required this.name,
    required this.targetBalance,
    required this.reason,
    required this.currentBalance,
  });
}

Future<ManualDebtInput?> showManualDebtDialog({
  required BuildContext context,
  required int Function(String phone) balanceForPhone,
  String? initialPhone,
  String? initialName,
}) async {
  final phoneController = TextEditingController(text: initialPhone ?? '');
  final nameController = TextEditingController(text: initialName ?? '');
  final amountController = TextEditingController();
  final reasonController = TextEditingController();
  String? validationError;
  final input = await showDialog<ManualDebtInput>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        final phone = phoneController.text.trim();
        final currentBalance = balanceForPhone(phone);
        final targetBalance =
            PackageRules.parseNonNegativeAmount(amountController.text);
        return AlertDialog(
          title: const Text('إضافة أو تعديل دين يدوي'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: phoneController,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'رقم هاتف العميل'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  TextField(
                    controller: nameController,
                    decoration:
                        const InputDecoration(labelText: 'اسم العميل (اختياري)'),
                  ),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'الرصيد الجديد المطلوب (ر.ي)'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  if (phone.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('الرصيد الحالي: $currentBalance ر.ي'),
                    ),
                  if (targetBalance != null)
                    Text('الرصيد بعد الحفظ: $targetBalance ر.ي'),
                  TextField(
                    controller: reasonController,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'سبب إضافة / تعديل الدين (إجباري)'),
                  ),
                  if (validationError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(validationError!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'سيُحفظ الفرق كحركة تسوية جديدة في كشف الحساب، دون تغيير الحركات السابقة.',
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
                final amount =
                    PackageRules.parseNonNegativeAmount(amountController.text);
                final reason = reasonController.text.trim();
                if (phoneController.text.trim().isEmpty ||
                    amount == null ||
                    reason.isEmpty) {
                  setDialogState(() => validationError =
                      phoneController.text.trim().isEmpty
                          ? 'رقم هاتف العميل مطلوب.'
                          : amount == null
                              ? 'أدخل مبلغًا صحيحًا يساوي صفرًا أو أكثر.'
                              : 'سبب الإضافة أو التعديل مطلوب.');
                  return;
                }
                final finalPhone = phoneController.text.trim();
                Navigator.pop(
                  dialogContext,
                  ManualDebtInput(
                    phone: finalPhone,
                    name: nameController.text.trim(),
                    targetBalance: amount,
                    reason: reason,
                    currentBalance: balanceForPhone(finalPhone),
                  ),
                );
              },
              child: const Text('حفظ الدين'),
            ),
          ],
        );
      },
    ),
  );
  phoneController.dispose();
  nameController.dispose();
  amountController.dispose();
  reasonController.dispose();
  return input;
}
