import 'package:flutter/material.dart';

import 'governance.dart';
import 'main.dart' show GlobalPermissionsPage, ReportsPage;

class ManagerControlPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onRefresh;
  const ManagerControlPage(
      {super.key, required this.data, required this.onRefresh});

  @override
  State<ManagerControlPage> createState() => _ManagerControlPageState();
}

class _ManagerControlPageState extends State<ManagerControlPage> {
  final g = Governance.instance;
  Map<String, dynamic> config = {};
  List<Map<String, dynamic>> rules = [];
  List<Map<String, dynamic>> requests = [];
  List<Map<String, dynamic>> logs = [];
  Map<String, dynamic> templates = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await g.ensureReady();
    final box = g.box;
    if (!mounted) return;
    setState(() {
      config =
          Map<String, dynamic>.from(box.get('managerConfig', defaultValue: {
        'smsEnabled': true,
        'whatsappEnabled': false,
        'alertsEnabled': true,
        'mode': 'review',
        'emergencyStop': false,
        'hourlyLimit': 20,
        'dailyLimit': 100,
        'workStart': '08:00',
        'workEnd': '22:00',
        'backupBeforeChange': true,
        'requirePin': true,
        'maxLargeSale': 3000,
      }) as Map);
      rules = _maps(box.get('managerRules', defaultValue: const []));
      requests = _maps(box.get('managerRequests', defaultValue: const []));
      logs = _maps(box.get('operatorLogs', defaultValue: const []));
      templates =
          Map<String, dynamic>.from(box.get('channelTemplates', defaultValue: {
        'smsSuccess': 'أهلاً {name}، تم تجهيز كرت {package} بسعر {price}.',
        'smsRejected': 'عذراً {name}، تعذر تنفيذ الطلب: {reason}.',
        'waSuccess':
            'أهلاً {name}\nالباقة: {package}\nالسعر: {price}\nالكرت: {card}',
        'waVerify': 'يرجى توثيق رقمك أولاً حتى نتمكن من خدمتك.',
        'outOfStock': 'الباقة {package} غير متوفرة حالياً.',
        'afterHours': 'نستقبل الطلبات من {start} إلى {end}.',
      }) as Map);
      loading = false;
    });
  }

  List<Map<String, dynamic>> _maps(dynamic value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  Future<void> _save(String action) async {
    await g.box.put('managerConfig', config);
    await g.record(action);
    await _load();
  }

  Future<void> _saveList(
      String key, List<Map<String, dynamic>> value, String action) async {
    await g.box.put(key, value);
    await g.record(action);
    await _load();
  }

  Future<void> _toggle(String key, bool value, String action) async {
    setState(() => config[key] = value);
    await _save(action);
  }

  Future<void> _addRule() async {
    final name = TextEditingController();
    final keywords = TextEditingController();
    final packageId = TextEditingController();
    String channel = 'sms';
    String mode = 'review';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (_, setLocal) => AlertDialog(
                title: const Text('إضافة قاعدة تشغيل'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: name,
                      decoration:
                          const InputDecoration(labelText: 'اسم القاعدة')),
                  TextField(
                      controller: keywords,
                      decoration: const InputDecoration(
                          labelText: 'الكلمات مفصولة بفاصلة')),
                  TextField(
                      controller: packageId,
                      decoration:
                          const InputDecoration(labelText: 'معرف الباقة')),
                  DropdownButtonFormField<String>(
                      initialValue: channel,
                      decoration: const InputDecoration(labelText: 'القناة'),
                      items: const [
                        DropdownMenuItem(value: 'sms', child: Text('SMS')),
                        DropdownMenuItem(
                            value: 'whatsapp', child: Text('WhatsApp'))
                      ],
                      onChanged: (v) => setLocal(() => channel = v ?? 'sms')),
                  DropdownButtonFormField<String>(
                      initialValue: mode,
                      decoration: const InputDecoration(labelText: 'الوضع'),
                      items: const [
                        DropdownMenuItem(value: 'auto', child: Text('آلي')),
                        DropdownMenuItem(
                            value: 'review', child: Text('مراجعة')),
                        DropdownMenuItem(value: 'off', child: Text('متوقف'))
                      ],
                      onChanged: (v) => setLocal(() => mode = v ?? 'review')),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, {
                            'name': name.text.trim(),
                            'keywords': keywords.text
                                .split(',')
                                .map((e) => e.trim())
                                .where((e) => e.isNotEmpty)
                                .toList(),
                            'packageId': packageId.text.trim(),
                            'channel': channel,
                            'mode': mode,
                            'enabled': true,
                            'priority': rules.length + 1
                          }),
                      child: const Text('حفظ'))
                ],
              )),
    );
    name.dispose();
    keywords.dispose();
    packageId.dispose();
    if (result == null || '${result['name']}'.isEmpty) return;
    await _saveList('managerRules', [...rules, result], 'إضافة قاعدة تشغيل');
  }

  Future<void> _simulate() async {
    final message = TextEditingController(text: 'أريد كرت 500');
    final result = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('اختبار ومحاكاة قاعدة'),
                content: TextField(
                    controller: message,
                    minLines: 2,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'رسالة تجريبية')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, message.text),
                      child: const Text('محاكاة'))
                ]));
    final input = result;
    message.dispose();
    if (input == null || !mounted) return;
    final normalized = input.toLowerCase();
    final matches = rules
        .where((rule) =>
            (rule['enabled'] != false) &&
            ((rule['keywords'] as List?) ?? [])
                .any((key) => normalized.contains('$key'.toLowerCase())))
        .toList();
    final text = matches.isEmpty
        ? 'لا توجد قاعدة مطابقة. النتيجة: حفظ الطلب للمراجعة.'
        : 'القاعدة: ${matches.first['name']}\nالقناة: ${matches.first['channel']}\nالباقة: ${matches.first['packageId']}\nالوضع: ${matches.first['mode']}\nلن يتم صرف بطاقة أو إرسال رسالة.';
    await g.record('محاكاة قاعدة تشغيل', details: input);
    if (mounted)
      showDialog(
          context: context,
          builder: (_) => AlertDialog(
                  title: const Text('نتيجة المحاكاة'),
                  content: Text(text),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('إغلاق'))
                  ]));
    await _load();
  }

  Future<void> _addRequest() async {
    final client = TextEditingController();
    final message = TextEditingController();
    final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('إضافة طلب للمراجعة'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: client,
                      decoration:
                          const InputDecoration(labelText: 'العميل أو الرقم')),
                  TextField(
                      controller: message,
                      decoration: const InputDecoration(labelText: 'الطلب'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context,
                          {'client': client.text, 'message': message.text}),
                      child: const Text('إضافة'))
                ]));
    client.dispose();
    message.dispose();
    if (result == null) return;
    await _saveList(
        'managerRequests',
        [
          ...requests,
          {
            ...result,
            'channel': 'manual',
            'status': 'pending',
            'time': DateTime.now().toIso8601String()
          }
        ],
        'إضافة طلب للمراجعة');
  }

  Future<void> _review(Map<String, dynamic> request, String status) async {
    final next = requests
        .map((e) => e == request ? {...e, 'status': status} : e)
        .toList();
    await _saveList('managerRequests', next,
        status == 'approved' ? 'الموافقة على طلب' : 'رفض طلب');
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
        appBar: AppBar(title: const Text('تحكم المدير')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          _statusHeader(),
          _section('1–4 | حالة المشغلات والطوارئ', Icons.power_settings_new,
              _engines()),
          _section('5–12 | SMS وWhatsApp', Icons.chat_outlined, _channels()),
          _section('13–16 | القواعد والاختبار', Icons.rule_outlined, _rules()),
          _section('17–19 | المراجعة والموافقات', Icons.fact_check_outlined,
              _reviewQueue()),
          _section('20–23 | العملاء والأسعار والحدود', Icons.people_outline,
              _clients()),
          _section('24–27 | القوالب والمعاينة', Icons.text_snippet_outlined,
              _templates()),
          _section('28–31 | السجلات والتقارير', Icons.history, _logs()),
          _section('32–36 | المستخدمون والصلاحيات',
              Icons.admin_panel_settings_outlined, _roles()),
          _section(
              '37–40 | التشغيل والأمان', Icons.security_outlined, _security()),
        ]));
  }

  Widget _statusHeader() => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('لوحة التحكم الموحدة',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _pill('SMS', config['smsEnabled'] == true),
                  _pill('WhatsApp', config['whatsappEnabled'] == true),
                  _pill('التنبيهات', config['alertsEnabled'] == true),
                  _pill('الوضع: ${config['mode'] ?? 'review'}', true),
                  _pill(config['emergencyStop'] == true ? 'طوارئ' : 'طبيعي',
                      config['emergencyStop'] != true),
                ],
              ),
            ],
          ),
        ),
      );
  Widget _pill(String text, bool good) => Chip(
      avatar: Icon(good ? Icons.check_circle : Icons.pause_circle,
          size: 16, color: good ? Colors.green : Colors.red),
      label: Text(text));
  Widget _section(String title, IconData icon, Widget child) => Card(
          child: ExpansionTile(
              leading: Icon(icon),
              title: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w900)),
              children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), child: child)
          ]));

  Widget _engines() => Column(children: [
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('مشغّل SMS'),
            value: config['smsEnabled'] == true,
            onChanged: (v) =>
                _toggle('smsEnabled', v, v ? 'تشغيل SMS' : 'إيقاف SMS')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('مشغّل WhatsApp'),
            subtitle: const Text('يعمل ضمن صلاحية الإشعارات وقواعد الحماية'),
            value: config['whatsappEnabled'] == true,
            onChanged: (v) => _toggle(
                'whatsappEnabled', v, v ? 'تشغيل WhatsApp' : 'إيقاف WhatsApp')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('مشغّل التنبيهات'),
            value: config['alertsEnabled'] == true,
            onChanged: (v) =>
                _toggle('alertsEnabled', v, 'تغيير مشغل التنبيهات')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('وضع الطوارئ'),
            subtitle:
                const Text('يوقف الرد والصرف والجدولة حتى يعاد تشغيله يدويًا'),
            value: config['emergencyStop'] == true,
            onChanged: (v) => _toggle('emergencyStop', v,
                v ? 'تفعيل إيقاف الطوارئ' : 'إلغاء إيقاف الطوارئ')),
        DropdownButtonFormField<String>(
            initialValue: '${config['mode'] ?? 'review'}',
            decoration: const InputDecoration(labelText: 'وضع التشغيل العام'),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('آلي')),
              DropdownMenuItem(value: 'review', child: Text('مراجعة المدير')),
              DropdownMenuItem(value: 'off', child: Text('تسجيل فقط / متوقف'))
            ],
            onChanged: (v) {
              if (v != null) {
                config['mode'] = v;
                _save('تغيير وضع التشغيل');
              }
            }),
      ]);

  Widget _channels() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'يفصل هذا القسم إعداد القناتين؛ التفعيل هنا لا يتجاوز أذونات Android أو سياسات WhatsApp.',
            style: TextStyle(height: 1.4)),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('السماح برسائل SMS الخاصة فقط'),
            value: config['smsPrivateOnly'] != false,
            onChanged: (v) =>
                _toggle('smsPrivateOnly', v, 'تغيير رسائل SMS الخاصة')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('WhatsApp: الرسائل الخاصة فقط'),
            value: config['waPrivateOnly'] != false,
            onChanged: (v) =>
                _toggle('waPrivateOnly', v, 'تغيير رسائل WhatsApp الخاصة')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('WhatsApp: العملاء الموثقون فقط'),
            value: config['waTrustedOnly'] != false,
            onChanged: (v) =>
                _toggle('waTrustedOnly', v, 'تغيير قيد موثقي WhatsApp')),
        _number('حد SMS في الساعة', 'smsHourlyLimit', 50),
        _number('حد WhatsApp في الساعة', 'waHourlyLimit', 20),
        _number('فترة الانتظار بين ردود WhatsApp بالثواني', 'waCooldown', 30),
        _number('الإيقاف بعد أخطاء متتالية', 'waErrorLimit', 3),
        OutlinedButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const _ChannelHelpPage())),
            icon: const Icon(Icons.help_outline),
            label: const Text('عرض قواعد القنوات')),
      ]);

  Widget _number(String label, String key, int fallback) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: SizedBox(
          width: 92,
          child: TextFormField(
              initialValue: '${config[key] ?? fallback}',
              keyboardType: TextInputType.number,
              onFieldSubmitted: (v) {
                config[key] = int.tryParse(v) ?? fallback;
                _save('تعديل حد $key');
              },
              decoration: const InputDecoration(isDense: true))));

  Widget _rules() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: _addRule,
              icon: const Icon(Icons.add),
              label: const Text('إضافة قاعدة')),
          FilledButton.tonalIcon(
              onPressed: _simulate,
              icon: const Icon(Icons.science_outlined),
              label: const Text('اختبار ومحاكاة'))
        ]),
        const SizedBox(height: 8),
        if (rules.isEmpty)
          const Text('لا توجد قواعد؛ أضف قاعدة SMS أو WhatsApp.'),
        ...rules.asMap().entries.map((entry) => Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: CircleAvatar(child: Text('${entry.key + 1}')),
                title: Text('${entry.value['name']}'),
                subtitle: Text(
                    '${entry.value['channel']} • ${entry.value['packageId']} • ${entry.value['mode']} • ${((entry.value['keywords'] as List?) ?? []).join('، ')}'),
                trailing: Switch(
                  value: entry.value['enabled'] != false,
                  onChanged: (v) async {
                    final next = [...rules];
                    next[entry.key] = {...next[entry.key], 'enabled': v};
                    await _saveList(
                        'managerRules', next, 'تفعيل أو إيقاف قاعدة');
                  },
                ),
              ),
            )),
      ]);

  Widget _reviewQueue() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child: Text(
                  'طلبات معلقة: ${requests.where((e) => e['status'] == 'pending').length}')),
          OutlinedButton.icon(
              onPressed: _addRequest,
              icon: const Icon(Icons.add_task),
              label: const Text('إضافة طلب'))
        ]),
        ...requests.where((e) => e['status'] == 'pending').map((r) => Card(
            child: ListTile(
                title: Text('${r['client']}'),
                subtitle: Text('${r['message']}\n${r['channel'] ?? 'manual'}'),
                isThreeLine: true,
                trailing: Wrap(children: [
                  IconButton(
                      tooltip: 'تنفيذ',
                      onPressed: () => _review(r, 'approved'),
                      icon: const Icon(Icons.check, color: Colors.green)),
                  IconButton(
                      tooltip: 'رفض',
                      onPressed: () => _review(r, 'rejected'),
                      icon: const Icon(Icons.close, color: Colors.red))
                ])))),
      ]);

  Widget _clients() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'تُدار مجموعات العملاء والأسعار التفصيلية من شاشة العملاء والباقات؛ هذه الحدود تضيف طبقة قرار للمشغّل.',
            style: TextStyle(height: 1.4)),
        _number('الحد اليومي لكل عميل', 'perClientDailyLimit', 10),
        _number('الحد الأقصى للدين', 'maxClientDebt', 50000),
        _number('حد الطلب الذي يحتاج موافقة مزدوجة', 'maxLargeSale', 3000),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('منع البيع الآجل لغير الموثقين'),
            value: config['creditTrustedOnly'] != false,
            onChanged: (v) =>
                _toggle('creditTrustedOnly', v, 'تغيير قيد البيع الآجل')),
        OutlinedButton.icon(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => GlobalPermissionsPage(
                        data: widget.data, onRefresh: widget.onRefresh))),
            icon: const Icon(Icons.tune),
            label: const Text('فتح صلاحيات العملاء والأسعار')),
      ]);

  Widget _templates() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'المتغيرات: {name}، {phone}، {package}، {price}، {card}، {debt}، {reason}، {start}، {end}',
            style: TextStyle(fontSize: 12)),
        ...templates.entries.map((entry) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextFormField(
                initialValue: '${entry.value}',
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: entry.key),
                onChanged: (v) => templates[entry.key] = v))),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: () async {
              await g.box.put('channelTemplates', templates);
              await g.record('تعديل قوالب القنوات');
              await _load();
            },
            icon: const Icon(Icons.save),
            label: const Text('حفظ ومعاينة القوالب')),
      ]);

  Widget _logs() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ReportsPage(data: widget.data))),
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('التقارير')),
          OutlinedButton.icon(
              onPressed: () async {
                await g.record('فتح سجل المشغل');
                await _load();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('تحديث'))
        ]),
        const SizedBox(height: 6),
        if (logs.isEmpty && g.auditLog.isEmpty)
          const Text('لا يوجد سجل مشغّل بعد.'),
        ...[...logs, ...g.auditLog].take(12).map((e) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.history),
            title: Text('${e['action'] ?? e['status'] ?? 'عملية'}'),
            subtitle: Text('${e['time'] ?? ''} ${e['details'] ?? ''}'))),
      ]);

  Widget _roles() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
            'الأدوار: المدير، المشرف، البائع، المحصل، المراقب. الصلاحيات الحساسة تبقى للمدير.',
            style: TextStyle(height: 1.4)),
        for (final role in const [
          'manager',
          'supervisor',
          'seller',
          'collector',
          'viewer'
        ])
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(role == 'manager'
                  ? 'المدير'
                  : role == 'supervisor'
                      ? 'المشرف'
                      : role == 'seller'
                          ? 'البائع'
                          : role == 'collector'
                              ? 'المحصل'
                              : 'المراقب'),
              value: config['role_$role'] != false,
              onChanged: (v) => _toggle('role_$role', v, 'تغيير صلاحية $role')),
      ]);

  Widget _security() => Column(children: [
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('نسخة احتياطية قبل التغييرات الحساسة'),
            value: config['backupBeforeChange'] != false,
            onChanged: (v) =>
                _toggle('backupBeforeChange', v, 'تغيير النسخ قبل التغيير')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('طلب PIN لإعدادات المدير'),
            value: config['requirePin'] != false,
            onChanged: (v) =>
                _toggle('requirePin', v, 'تغيير قفل إعدادات المدير')),
        ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('أوقات التشغيل'),
            subtitle: Text(
                '${config['workStart'] ?? '08:00'} — ${config['workEnd'] ?? '22:00'}'),
            trailing: const Icon(Icons.schedule),
            onTap: () async {
              final start = await _time(
                  'وقت البداية', '${config['workStart'] ?? '08:00'}');
              if (start == null) return;
              final end =
                  await _time('وقت النهاية', '${config['workEnd'] ?? '22:00'}');
              if (end == null) return;
              config['workStart'] = start;
              config['workEnd'] = end;
              await _save('تغيير أوقات التشغيل');
            }),
        _number('الحد اليومي العام', 'dailyLimit', 100),
        const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('إيقاف تلقائي عند الوصول للحد'),
            subtitle:
                Text('يستخدم الحد اليومي العام ويُسجل العملية في سجل المدير.')),
      ]);

  Future<String?> _time(String title, String current) async {
    final c = TextEditingController(text: current);
    final result = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(title),
                content: TextField(
                    controller: c,
                    decoration: const InputDecoration(hintText: '08:00')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, c.text.trim()),
                      child: const Text('حفظ'))
                ]));
    c.dispose();
    return result;
  }
}

class _ChannelHelpPage extends StatelessWidget {
  const _ChannelHelpPage();
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('قواعد القنوات')),
      body: const Padding(
          padding: EdgeInsets.all(18),
          child: Text(
              'SMS يعمل عبر استقبال الرسائل وصلاحيات الهاتف والشريحة. WhatsApp يعتمد على صلاحية قراءة الإشعارات، ويجب إبقاء الإرسال اليدوي أو المراجعة مفعلاً عند الحاجة. هذه الصفحة تنظّم قرارات المدير ولا تتجاوز قيود النظام أو سياسات التطبيقات.',
              style: TextStyle(height: 1.6))));
}
