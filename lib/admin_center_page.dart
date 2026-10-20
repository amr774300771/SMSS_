import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'governance.dart';
import 'contact_picker_page.dart';
import 'main.dart'
    show EnginePage, PackagesPage, GlobalPermissionsPage, ReportsPage;
import 'sms_templates_page.dart';
import 'service_diagnostics_page.dart';
import 'trusted_broadcast_page.dart';

class AdminCenterPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onRefresh;
  const AdminCenterPage(
      {super.key, required this.data, required this.onRefresh});

  @override
  State<AdminCenterPage> createState() => _AdminCenterPageState();
}

class _AdminCenterPageState extends State<AdminCenterPage> {
  final governance = Governance.instance;
  late Map<String, dynamic> safety;
  late Map<String, dynamic> groups;
  late Map<String, dynamic> backup;
  late Map<String, dynamic> roles;
  List<Map<String, dynamic>> audit = const [];
  List<Map<String, dynamic>> schedules = const [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await governance.ensureReady();
    if (!mounted) return;
    setState(() {
      safety = governance.whatsappSafety;
      groups = governance.clientGroups;
      backup = governance.autoBackup;
      roles = governance.roles;
      audit = governance.auditLog;
      schedules = governance.scheduledBroadcasts;
      loading = false;
    });
  }

  List<Map<String, dynamic>> get trusted =>
      ((widget.data['trusted'] as Map?)?['clients'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _push(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    await widget.onRefresh();
    await _load();
  }

  Future<void> _saveSafety() async {
    await governance.saveWhatsAppSafety(safety);
    await _load();
  }

  Future<void> _addGroup() async {
    final name = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('مجموعة عملاء جديدة'),
        content: TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'اسم المجموعة')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, name.text.trim()),
              child: const Text('إضافة')),
        ],
      ),
    );
    name.dispose();
    if (result == null || result.isEmpty) return;
    groups[result] = <dynamic>[];
    await governance.saveClientGroups(groups);
    await _load();
  }

  Future<void> _editGroup(String name) async {
    final current = ((groups[name] as List?) ?? []).map((e) => '$e').toSet();
    final picked = await Navigator.push<List<ContactRecipient>>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactPickerPage(
          initialSelection: trusted
              .where((e) => current.contains('${e['phone']}'))
              .map((e) => ContactRecipient(
                  id: '${e['phone']}',
                  name: '${e['name'] ?? ''}',
                  phone: '${e['phone']}'))
              .toList(),
        ),
      ),
    );
    if (picked == null) return;
    final trustedPhones = trusted.map((e) => '${e['phone']}').toSet();
    groups[name] =
        picked.map((e) => e.phone).where(trustedPhones.contains).toList();
    await governance.saveClientGroups(groups);
    await _load();
  }

  Future<void> _scheduleBroadcast() async {
    if (trusted.isEmpty) return;
    final text = TextEditingController(text: 'تنبيه من القاضي نت، {name}.');
    DateTime selected = DateTime.now().add(const Duration(hours: 1));
    final result = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setLocal) => AlertDialog(
          title: const Text('جدولة تنبيه جماعي'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: text,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'القالب')),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('موعد الإرسال'),
              subtitle: Text('${selected.toLocal()}'),
              onTap: () async {
                final date = await showDatePicker(
                    context: dialogContext,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDate: selected);
                if (date == null || !dialogContext.mounted) return;
                final time = await showTimePicker(
                    context: dialogContext,
                    initialTime: TimeOfDay.fromDateTime(selected));
                if (time != null)
                  setLocal(() => selected = DateTime(
                      date.year, date.month, date.day, time.hour, time.minute));
              },
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: const Text('حفظ الجدولة')),
          ],
        ),
      ),
    );
    final value = result;
    final message = text.text.trim();
    text.dispose();
    if (value == null || message.isEmpty) return;
    schedules = [
      ...schedules,
      {
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'at': value.toIso8601String(),
        'message': message,
        'status': 'pending',
        'recipients': trusted.map((e) => e['phone']).toList()
      }
    ];
    await governance.saveScheduledBroadcasts(schedules);
    await _load();
  }

  Future<void> _shareLocalSettings() async {
    await Share.share(governance.exportLocalSettings(),
        subject: 'إعدادات إدارة القاضي نت');
  }

  Future<void> _dailyClose() async {
    final sales =
        (widget.data['sales'] as List? ?? []).whereType<Map>().toList();
    final total = sales.fold<num>(
        0,
        (sum, item) =>
            sum +
            (num.tryParse('${item['amount'] ?? item['price'] ?? 0}') ?? 0));
    final text =
        'إغلاق يومي — القاضي نت\nالتاريخ: ${DateTime.now().toLocal()}\nعدد العمليات: ${sales.length}\nإجمالي المبيعات: ${total.round()} ر.ي\nالمخزون: ${(widget.data['inventory'] as Map?)?.length ?? 0} باقة';
    await governance.record('إنشاء إغلاق يومي', details: text);
    if (mounted) await Share.share(text, subject: 'إغلاق يومي القاضي نت');
    await _load();
  }

  Future<void> _roleDialog() async {
    final next = Map<String, dynamic>.from(roles);
    final names = {
      'manager': 'مدير',
      'supervisor': 'مشرف',
      'seller': 'بائع',
      'collector': 'محصل',
      'viewer': 'مراقب'
    };
    final permissions = {
      'manager': ['all'],
      'supervisor': ['sales', 'inventory', 'clients', 'reports'],
      'seller': ['sales', 'clients'],
      'collector': ['clients', 'debts'],
      'viewer': ['reports']
    };
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (_, setLocal) => AlertDialog(
                  title: const Text('صلاحيات الأدوار'),
                  content: SizedBox(
                      width: 460,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: names.entries
                              .map((entry) => SwitchListTile(
                                    value: next[entry.key] != false,
                                    onChanged: (v) =>
                                        setLocal(() => next[entry.key] = v),
                                    title: Text(entry.value),
                                    subtitle: Text(
                                        (permissions[entry.key] ?? [])
                                            .join('، ')),
                                  ))
                              .toList())),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('إلغاء')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('حفظ'))
                  ],
                )));
    await governance.saveRoles(next);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('مركز الإدارة والحماية')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _introCard(),
        _section('1 — حماية WhatsApp', Icons.shield_outlined, _safetyCard()),
        _section('2–6 — العملاء والمجموعات والملفات', Icons.people_alt_outlined,
            _clientsCard()),
        _section('7–9 — القوالب والمعاينة والجدولة', Icons.campaign_outlined,
            _messagingCard()),
        _section('10–12 — المخزون والتسعير', Icons.inventory_2_outlined,
            _catalogCard()),
        _section('13–14 — التقارير والإغلاق اليومي', Icons.analytics_outlined,
            _reportsCard()),
        _section('15–16 — الأدوار وسجل التدقيق',
            Icons.admin_panel_settings_outlined, _securityCard()),
      ]),
    );
  }

  Widget _introCard() => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('لوحة التحكم الشاملة',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(
                'تم تجميع الميزات 1 إلى 16 هنا مع الحفاظ على مسارات البيع والمخزون الحالية. سجل التدقيق محلي، ولا تُرسل الحملات الجماعية في الخلفية.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])));

  Widget _section(String title, IconData icon, Widget child) => Card(
          child: ExpansionTile(
              leading: Icon(icon),
              title: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: child)
          ]));

  Widget _safetyCard() => Column(children: [
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('تفعيل وضع حماية الردود'),
            subtitle: const Text('حدود لكل عميل، سقف ساعي، وإيقاف بعد الأخطاء'),
            value: safety['enabled'] != false,
            onChanged: (v) {
              setState(() => safety['enabled'] = v);
              _saveSafety();
            }),
        _number('الحد العام في الساعة', 'hourlyLimit', 20),
        _number('الحد لكل عميل في الساعة', 'perClientLimit', 5),
        _number('فترة التهدئة بالثواني', 'cooldownSeconds', 30),
        _number('الإيقاف بعد أخطاء متتالية', 'errorLimit', 3),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('إيقاف طارئ عند الوصول للحد'),
            value: safety['emergencyStop'] != false,
            onChanged: (v) {
              setState(() => safety['emergencyStop'] = v);
              _saveSafety();
            }),
      ]);

  Widget _number(String label, String key, int fallback) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: SizedBox(
          width: 90,
          child: TextFormField(
              initialValue: '${safety[key] ?? fallback}',
              keyboardType: TextInputType.number,
              onChanged: (v) {
                safety[key] = int.tryParse(v) ?? fallback;
              },
              onFieldSubmitted: (_) => _saveSafety(),
              decoration: const InputDecoration(isDense: true))));

  Widget _clientsCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('العملاء الموثقون: ${trusted.length}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _push(TrustedBroadcastPage(
                  data: widget.data, onRefresh: widget.onRefresh)),
              icon: const Icon(Icons.campaign),
              label: const Text('تنبيه جماعي')),
          OutlinedButton.icon(
              onPressed: _addGroup,
              icon: const Icon(Icons.group_add),
              label: const Text('مجموعة جديدة')),
          OutlinedButton.icon(
              onPressed: _shareLocalSettings,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('تصدير الإعدادات')),
          OutlinedButton.icon(
              onPressed: () => _push(EnginePage(
                  data: widget.data,
                  onRefresh: widget.onRefresh,
                  onlySection: 1,
                  pageTitle: 'العملاء الموثقون')),
              icon: const Icon(Icons.verified_user),
              label: const Text('إدارة الموثقين')),
        ]),
        const SizedBox(height: 8),
        if (groups.isEmpty)
          const Text('لا توجد مجموعات بعد.')
        else
          ...groups.entries.map((entry) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(entry.key),
              subtitle: Text('${(entry.value as List?)?.length ?? 0} عميل'),
              trailing: IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editGroup(entry.key)))),
      ]);

  Widget _messagingCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _push(SmsTemplatesPage(
                  data: widget.data, onRefresh: widget.onRefresh)),
              icon: const Icon(Icons.text_snippet_outlined),
              label: const Text('القوالب')),
          OutlinedButton.icon(
              onPressed: _scheduleBroadcast,
              icon: const Icon(Icons.schedule),
              label: const Text('جدولة تنبيه')),
        ]),
        const SizedBox(height: 8),
        if (schedules.isEmpty)
          const Text('لا توجد تنبيهات مجدولة.')
        else
          ...schedules.map((entry) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text('${entry['at']}'),
              subtitle: Text('${entry['message']} • ${entry['status']}'))),
      ]);

  Widget _catalogCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'تم ربط هذه المجموعة بصفحات الباقات والمخزون الموجودة؛ وتشمل التنبيه عند انخفاض المخزون والاستيراد وكشف التكرار والتسعير.',
            style: TextStyle(height: 1.4)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _push(
                  PackagesPage(data: widget.data, onRefresh: widget.onRefresh)),
              icon: const Icon(Icons.card_membership),
              label: const Text('إدارة الباقات')),
          OutlinedButton.icon(
              onPressed: () => _push(EnginePage(
                  data: widget.data,
                  onRefresh: widget.onRefresh,
                  onlySection: 0,
                  pageTitle: 'المشغّل')),
              icon: const Icon(Icons.tune),
              label: const Text('المشغّل')),
        ]),
      ]);

  Widget _reportsCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => _push(ReportsPage(data: widget.data)),
              icon: const Icon(Icons.bar_chart),
              label: const Text('التقارير')),
          FilledButton.icon(
              onPressed: _dailyClose,
              icon: const Icon(Icons.lock_clock),
              label: const Text('إنشاء إغلاق يومي')),
        ]),
        const SizedBox(height: 8),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('نسخ احتياطي تلقائي'),
            subtitle: Text('الاحتفاظ بـ ${backup['keepCount'] ?? 7} نسخ'),
            value: backup['enabled'] == true,
            onChanged: (v) async {
              await governance.saveAutoBackup(
                  v, (backup['keepCount'] as num?)?.toInt() ?? 7);
              await _load();
            }),
        OutlinedButton.icon(
            onPressed: () => _push(ServiceDiagnosticsPage(
                data: widget.data, onRefresh: widget.onRefresh)),
            icon: const Icon(Icons.health_and_safety),
            label: const Text('تشخيص الجاهزية')),
      ]);

  Widget _securityCard() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        OutlinedButton.icon(
            onPressed: _roleDialog,
            icon: const Icon(Icons.manage_accounts),
            label: const Text('إدارة الأدوار والصلاحيات')),
        OutlinedButton.icon(
            onPressed: () async {
              await governance.record('فتح سجل التدقيق');
              if (mounted)
                await showDialog(
                    context: context,
                    builder: (_) =>
                        AlertDialog(
                            title: const Text('سجل التدقيق'),
                            content: SizedBox(
                                width: 500,
                                height: 420,
                                child: audit.isEmpty
                                    ? const Center(
                                        child: Text('لا توجد عمليات مسجلة.'))
                                    : ListView(
                                        children: audit
                                            .map((e) => ListTile(
                                                dense: true,
                                                leading:
                                                    const Icon(Icons.history),
                                                title: Text('${e['action']}'),
                                                subtitle: Text(
                                                    '${e['time']}\n${e['details'] ?? ''}')))
                                            .toList())),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('إغلاق'))
                            ]));
              await _load();
            },
            icon: const Icon(Icons.history),
            label: Text('سجل التدقيق (${audit.length})')),
        OutlinedButton.icon(
            onPressed: () => _push(GlobalPermissionsPage(
                data: widget.data, onRefresh: widget.onRefresh)),
            icon: const Icon(Icons.policy_outlined),
            label: const Text('الصلاحيات العامة')),
        const SizedBox(height: 8),
        const Text(
            'الأدوار الافتراضية: مدير، مشرف، بائع، محصل، مراقب. الصلاحيات السحابية الحالية تبقى متاحة من إعدادات المزامنة.',
            style: TextStyle(height: 1.4)),
      ]);
}
