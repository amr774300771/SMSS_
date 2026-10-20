import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native_api.dart';
import 'whatsapp_utils.dart';

class SmsTemplatesPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onRefresh;
  const SmsTemplatesPage(
      {super.key, required this.data, required this.onRefresh});

  @override
  State<SmsTemplatesPage> createState() => _SmsTemplatesPageState();
}

class _SmsTemplatesPageState extends State<SmsTemplatesPage> {
  late Map<String, dynamic> trigger;
  final fields = <String, TextEditingController>{};
  bool saving = false;

  static const defaults = <String, String>{
    'success':
        'أهلاً {name}،\nكرتك: {card} | الباقة: {package} | السعر: {price} ر.ي\nالمتبقي عليك: {debt} ر.ي — القاضي نت',
    'rejected': '{reason}',
    'outOfStock': '{reason}',
    'whatsappReceipt':
        'أهلاً {name}،\nكرتك: {card}\nالباقة: {package} — السعر: {price} ر.ي\nشبكة القاضي نت',
    'collectionReminder':
        'مرحباً {name}، نذكركم بأن المبلغ المستحق هو {amount} ر.ي. نرجو التواصل مع القاضي نت.',
    'welcome':
        'أهلاً وسهلاً {name}، نشكرك لاختيارك شبكة القاضي نت. لأي استفسار تواصل معنا على هذا الرقم.',
  };

  @override
  void initState() {
    super.initState();
    trigger = jsonDecode(jsonEncode(widget.data['trigger'] ?? {}))
        as Map<String, dynamic>;
    final existing = trigger['templates'] is Map
        ? Map<String, dynamic>.from(trigger['templates'] as Map)
        : <String, dynamic>{};
    for (final entry in defaults.entries) {
      fields[entry.key] = TextEditingController(
        text: '${existing[entry.key] ?? entry.value}',
      );
    }
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('قوالب الرسائل')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
                'المتغيرات المتاحة: {name} اسم العميل، {card} رقم الكرت، {package} الباقة، {price} السعر، {debt} الرصيد، {phone} الهاتف، {reason} السبب، {amount} مبلغ التحصيل.'),
            const SizedBox(height: 12),
            _field('success', 'رد البيع الناجح عبر SMS'),
            _field('rejected', 'رد رفض الطلب أو تجاوز الحدود'),
            _field('outOfStock', 'رد نفاد المخزون'),
            _field('whatsappReceipt', 'إيصال WhatsApp المختصر للعميل'),
            _field('collectionReminder', 'تذكير التحصيل'),
            _field('welcome', 'رسالة الترحيب اليدوية'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _prepareWelcome,
              icon: const Icon(Icons.chat_outlined),
              label: const Text('تجهيز رسالة ترحيب للمراجعة'),
            ),
            FilledButton.icon(
              onPressed: saving ? null : _save,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: const Text('حفظ القوالب'),
            ),
          ],
        ),
      );

  Widget _field(String key, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: fields[key],
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: label,
            helperText: key == 'welcome'
                ? 'لا تُرسل تلقائياً؛ تفتح رسالة جاهزة لتراجعها أولاً.'
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      trigger['templates'] =
          fields.map((key, value) => MapEntry(key, value.text.trim()));
      await NativeApi.instance.saveConfig('trigger_config.json', trigger);
      await widget.onRefresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم حفظ قوالب الرسائل.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر حفظ القوالب: $error')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _prepareWelcome() async {
    final phone = TextEditingController();
    final name = TextEditingController();
    final details = await showDialog<(String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تجهيز ترحيب لعميل'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'اسم العميل')),
          TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'رقم الهاتف')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () {
                if (phone.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('أدخل رقم العميل.')));
                  return;
                }
                Navigator.pop(context, (phone.text.trim(), name.text.trim()));
              },
              child: const Text('التالي')),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    phone.dispose();
    name.dispose();
    if (details == null || !mounted) return;
    final message = (fields['welcome']?.text ?? defaults['welcome']!)
        .replaceAll('{name}', details.$2.isEmpty ? 'عميلنا' : details.$2)
        .replaceAll('{phone}', details.$1);
    final channel = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(children: [
          const ListTile(title: Text('راجع الرسالة ثم اضغط إرسال')),
          ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('فتح WhatsApp'),
              onTap: () => Navigator.pop(context, 'wa')),
          ListTile(
              leading: const Icon(Icons.sms),
              title: const Text('فتح SMS'),
              onTap: () => Navigator.pop(context, 'sms')),
        ]),
      ),
    );
    if (channel == null) return;
    try {
      if (channel == 'sms') {
        await NativeApi.instance.openSmsComposer(details.$1, message);
      } else {
        final uri = whatsappChatUri(details.$1, message: message);
        if (uri == null) throw StateError('رقم العميل غير صالح لفتح WhatsApp');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('تعذر فتح واتساب');
        }
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر فتح التطبيق: $error')));
    }
  }
}
