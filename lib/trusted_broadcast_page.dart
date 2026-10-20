import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'contact_picker_page.dart';
import 'native_api.dart';
import 'whatsapp_utils.dart';

class TrustedBroadcastPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onRefresh;
  const TrustedBroadcastPage(
      {super.key, required this.data, required this.onRefresh});

  @override
  State<TrustedBroadcastPage> createState() => _TrustedBroadcastPageState();
}

class _TrustedBroadcastPageState extends State<TrustedBroadcastPage> {
  late final TextEditingController template;
  final selected = <String, Map<String, dynamic>>{};
  String channel = 'whatsapp';
  bool saving = false;
  bool sending = false;

  List<Map<String, dynamic>> get trusted =>
      ((widget.data['trusted'] as Map?)?['clients'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => '${e['phone'] ?? ''}'.trim().isNotEmpty)
          .toList();

  @override
  void initState() {
    super.initState();
    final trigger =
        Map<String, dynamic>.from((widget.data['trigger'] as Map?) ?? {});
    final templates =
        Map<String, dynamic>.from((trigger['templates'] as Map?) ?? {});
    template = TextEditingController(
      text:
          '${templates['bulkNotification'] ?? 'تنبيه من القاضي نت، {name}.\n{message}\nللاستفسار تواصل معنا.'}',
    );
    for (final client in trusted) {
      final phone = '${client['phone']}';
      selected[normalizeWhatsAppNumber(phone) ?? phone] = client;
    }
  }

  @override
  void dispose() {
    template.dispose();
    super.dispose();
  }

  String _key(String value) => normalizeWhatsAppNumber(value) ?? value.trim();

  Future<void> _pickContacts() async {
    final picked = await Navigator.push<List<ContactRecipient>>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactPickerPage(
          initialSelection: selected.values
              .map((c) => ContactRecipient(
                    id: _key('${c['phone']}'),
                    name: '${c['name'] ?? ''}',
                    phone: '${c['phone']}',
                  ))
              .toList(),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final trustedByPhone = <String, Map<String, dynamic>>{
      for (final c in trusted) _key('${c['phone']}'): c,
    };
    final next = <String, Map<String, dynamic>>{};
    var ignored = 0;
    for (final contact in picked) {
      final match = trustedByPhone[_key(contact.phone)];
      if (match == null) {
        ignored++;
      } else {
        next[_key('${match['phone']}')] = match;
      }
    }
    setState(() {
      selected
        ..clear()
        ..addAll(next);
    });
    if (ignored > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('تم تجاهل $ignored جهة غير موجودة في قائمة العملاء الموثقين.'),
      ));
    }
  }

  String _render(Map<String, dynamic> client) {
    final name = '${client['name'] ?? ''}'.trim();
    return template.text
        .replaceAll('{name}', name.isEmpty ? 'عميلنا' : name)
        .replaceAll('{phone}', '${client['phone'] ?? ''}')
        .replaceAll('{count}', '${selected.length}')
        .replaceAll('{message}', 'يوجد تنبيه جديد من شبكة القاضي نت.');
  }

  Future<void> _saveTemplate() async {
    setState(() => saving = true);
    try {
      final latest = await NativeApi.instance.refresh();
      final trigger =
          Map<String, dynamic>.from((latest['trigger'] as Map?) ?? {});
      final templates =
          Map<String, dynamic>.from((trigger['templates'] as Map?) ?? {});
      templates['bulkNotification'] = template.text.trim();
      trigger['templates'] = templates;
      await NativeApi.instance.saveConfig('trigger_config.json', trigger);
      await widget.onRefresh();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ قالب التنبيه الجماعي.')),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ القالب: $error')),
        );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _openFor(Map<String, dynamic> client) async {
    final phone = '${client['phone'] ?? ''}';
    final message = _render(client);
    if (channel == 'sms') {
      await NativeApi.instance.openSmsComposer(phone, message);
      return;
    }
    final uri = whatsappChatUri(phone, message: message);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('تعذر فتح محادثة WhatsApp لهذا الرقم.');
    }
  }

  Future<void> _startQueue() async {
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('اختر موثقين أولاً.')));
      return;
    }
    if (template.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اكتب قالب التنبيه أولاً.')));
      return;
    }
    setState(() => sending = true);
    final clients = selected.values.toList();
    try {
      for (var index = 0; index < clients.length; index++) {
        if (!mounted) return;
        final client = clients[index];
        await _openFor(client);
        if (!mounted) return;
        final next = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text('تم تجهيز ${index + 1} من ${clients.length}'),
            content: Text(
                'راجع الرسالة في التطبيق واضغط إرسال بنفسك، ثم تابع للعميل التالي.\n\n${client['name'] ?? client['phone']}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('إيقاف')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child:
                      Text(index + 1 == clients.length ? 'إنهاء' : 'التالي')),
            ],
          ),
        );
        if (next != true) break;
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تعذر تجهيز التنبيه: $error')));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تنبيه جماعي للموثقين')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('إرسال آمن بمراجعة يدوية',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 8),
                          const Text(
                              'لا يرسل التطبيق الرسائل في الخلفية. يفتح محادثة كل عميل على حدة، وتضغط إرسال بنفسك قبل الانتقال للعميل التالي لتقليل الإرسال غير المقصود.'),
                          const SizedBox(height: 12),
                          Text('المحددون: ${selected.length}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                              onPressed: sending ? null : _pickContacts,
                              icon: const Icon(Icons.contacts_outlined),
                              label: const Text(
                                  'اختيار الموثقين من جهات الاتصال')),
                        ]))),
            const SizedBox(height: 12),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      DropdownButtonFormField<String>(
                        initialValue: channel,
                        decoration:
                            const InputDecoration(labelText: 'قناة التنبيه'),
                        items: const [
                          DropdownMenuItem(
                              value: 'whatsapp',
                              child: Text('WhatsApp — مراجعة وإرسال يدوي')),
                          DropdownMenuItem(
                              value: 'sms',
                              child: Text('SMS — مراجعة وإرسال يدوي')),
                        ],
                        onChanged: sending
                            ? null
                            : (value) =>
                                setState(() => channel = value ?? 'whatsapp'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: template,
                        minLines: 5,
                        maxLines: 10,
                        decoration: const InputDecoration(
                          labelText: 'قالب التنبيه',
                          helperText:
                              'المتغيرات: {name} الاسم، {phone} الرقم، {count} عدد المحددين، {message} نص افتراضي.',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: OutlinedButton.icon(
                                onPressed: saving ? null : _saveTemplate,
                                icon: const Icon(Icons.save_outlined),
                                label: const Text('حفظ القالب'))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: FilledButton.icon(
                                onPressed: sending ? null : _startQueue,
                                icon: const Icon(Icons.send_outlined),
                                label: Text(sending
                                    ? 'جارٍ التجهيز…'
                                    : 'بدء التنبيه'))),
                      ]),
                    ]))),
            const SizedBox(height: 12),
            if (selected.isNotEmpty)
              Card(
                  child: Column(
                      children: selected.values
                          .map((c) => ListTile(
                                leading: const Icon(
                                    Icons.verified_user_outlined,
                                    color: Colors.green),
                                title: Text('${c['name'] ?? 'عميل'}'),
                                subtitle: Text('${c['phone']}'),
                                trailing: IconButton(
                                    icon:
                                        const Icon(Icons.remove_circle_outline),
                                    onPressed: sending
                                        ? null
                                        : () => setState(() => selected
                                            .remove(_key('${c['phone']}')))),
                              ))
                          .toList())),
          ],
        ),
      );
}
