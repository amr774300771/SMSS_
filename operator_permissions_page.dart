import 'package:flutter/material.dart';

import 'operator_permissions.dart';

/// Manager-facing editor for per-operator permissions.
///
/// The parent must enforce manager-only access and supply stable, authenticated
/// operator IDs. [onSave] should persist the returned map in the app's settings
/// store and the operation layer must independently enforce each permission.
class OperatorPermissionsPage extends StatefulWidget {
  final List<Map<String, String>> operators;
  final Map<String, dynamic> initialOverrides;
  final Future<void> Function(Map<String, dynamic> overrides) onSave;

  const OperatorPermissionsPage({
    super.key,
    required this.operators,
    required this.initialOverrides,
    required this.onSave,
  });

  @override
  State<OperatorPermissionsPage> createState() =>
      _OperatorPermissionsPageState();
}

class _OperatorPermissionsPageState extends State<OperatorPermissionsPage> {
  static const _labels = <String, String>{
    'sales.create_cash': 'إنشاء بيع نقدي',
    'sales.create_credit': 'إنشاء بيع آجل',
    'sales.refund': 'إرجاع عملية بيع',
    'payments.collect': 'استلام دفعة من عميل',
    'ledger.adjust': 'تعديل رصيد / تسوية يدوية',
    'inventory.manage': 'إدارة المخزون والبطاقات',
    'clients.manage': 'إدارة العملاء',
    'reports.view': 'عرض التقارير',
    'messages.send': 'إرسال الرسائل والتنبيهات',
    'settings.manage': 'تعديل الإعدادات',
    'users.manage': 'إدارة المستخدمين والمشغّلين',
    'backup.create': 'إنشاء نسخة احتياطية',
    'backup.restore': 'استعادة نسخة احتياطية',
  };

  late Map<String, dynamic> overrides;
  String? selectedOperatorId;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    overrides = Map<String, dynamic>.from(widget.initialOverrides);
    if (widget.operators.isNotEmpty) {
      selectedOperatorId = widget.operators.first['id'];
    }
  }

  Map<String, String>? get _selectedOperator {
    for (final operator in widget.operators) {
      if (operator['id'] == selectedOperatorId) return operator;
    }
    return null;
  }

  bool _isAllowed(String capability) {
    final id = selectedOperatorId;
    if (id == null) return false;
    return OperatorPermissionPolicy.allows(
      operatorId: id,
      capability: capability,
      overrides: overrides,
    );
  }

  void _setAllowed(String capability, bool value) {
    final id = selectedOperatorId;
    if (id == null) return;
    setState(() {
      overrides = OperatorPermissionPolicy.setPermission(
        overrides: overrides,
        operatorId: id,
        capability: capability,
        allowed: value,
      );
    });
  }

  Future<void> _save() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.onSave(overrides);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ صلاحيات المشغّلين')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ الصلاحيات: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedOperator;
    return Scaffold(
      appBar: AppBar(
        title: const Text('صلاحيات كل مشغّل'),
        actions: [
          IconButton(
            tooltip: 'حفظ التغييرات',
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: widget.operators.isEmpty
          ? const Center(child: Text('لا توجد حسابات مشغّلين لعرض صلاحياتها.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'اختر المشغّل',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: selectedOperatorId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          items: widget.operators
                              .where((operator) =>
                                  (operator['id'] ?? '').trim().isNotEmpty)
                              .map((operator) => DropdownMenuItem(
                                    value: operator['id'],
                                    child: Text(
                                      '${operator['name'] ?? operator['id']}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: (value) =>
                              setState(() => selectedOperatorId = value),
                        ),
                        if (selected != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'معرّف الحساب: ${selected['id']}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'الصلاحيات غير المحددة مرفوضة افتراضيًا. امنح فقط ما يحتاجه هذا الحساب.',
                  style: TextStyle(color: Colors.blueGrey),
                ),
                const SizedBox(height: 8),
                ..._labels.entries.map((entry) => Card(
                      child: SwitchListTile.adaptive(
                        value: _isAllowed(entry.key),
                        onChanged: selected == null
                            ? null
                            : (value) => _setAllowed(entry.key, value),
                        title: Text(entry.value),
                        subtitle: Text(entry.key),
                      ),
                    )),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(saving ? 'جارٍ الحفظ…' : 'حفظ الصلاحيات'),
                ),
              ],
            ),
    );
  }
}
