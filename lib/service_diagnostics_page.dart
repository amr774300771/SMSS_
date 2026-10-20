import 'package:flutter/material.dart';
import 'native_api.dart';
import 'skeleton_widgets.dart';

class ServiceDiagnosticsPage extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() onRefresh;
  const ServiceDiagnosticsPage(
      {super.key, required this.data, required this.onRefresh});

  @override
  State<ServiceDiagnosticsPage> createState() => _ServiceDiagnosticsPageState();
}

class _ServiceDiagnosticsPageState extends State<ServiceDiagnosticsPage> {
  Map<String, dynamic> status = const {};
  bool loading = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() => loading = true);
    try {
      status = await NativeApi.instance.serviceDiagnostics();
      await widget.onRefresh();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر فحص الخدمة: $error')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trigger = widget.data['trigger'] is Map
        ? Map<String, dynamic>.from(widget.data['trigger'] as Map)
        : <String, dynamic>{};
    final events = trigger['events'] is List
        ? (trigger['events'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
            .reversed
            .toList()
        : <Map<String, dynamic>>[];
    final counts = <String, int>{};
    for (final event in events) {
      final reason = '${event['reason'] ?? 'غير معروف'}';
      counts[reason] = (counts[reason] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('تشخيص خدمة الرسائل'), actions: [
        IconButton(
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh))
      ]),
      body: loading && status.isEmpty
          ? const AppSkeleton(rows: 6)
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'الرد الآلي عبر WhatsApp',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'يحتاج إذن الوصول إلى الإشعارات وتفعيل الرد الآلي. يعمل على إشعارات المحادثات الفردية التي توفر زر رد مباشر؛ لا يرسل رسالة جديدة إلى محادثة عشوائية. إذا تعذر تنفيذ الرد، يعاد المحاولة بالإيصال نفسه دون صرف كرت آخر.',
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            await NativeApi.instance
                                .openWhatsAppNotificationSettings();
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'تعذر فتح إعدادات الإشعارات: $error')),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('فتح صلاحية إشعارات WhatsApp'),
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                  child: Column(children: [
                _row('عملية الخدمة تعمل', status['serviceRunning'] == true),
                _row('محرك SMS مفعّل', status['triggerEnabled'] == true),
                _row('إذن استقبال الرسائل',
                    status['receiveSmsPermission'] == true),
                _row('إذن إرسال الرسائل', status['sendSmsPermission'] == true),
                _row('إذن الإشعارات', status['notificationPermission'] == true),
                _row('صلاحية قراءة إشعارات WhatsApp',
                    status['whatsappNotificationAccess'] == true),
                _row('الرد الآلي عبر WhatsApp',
                    status['whatsappAutoReplyEnabled'] == true),
                _row('الشريحة جاهزة', status['simReady'] == true),
                _row('استثناء تحسين البطارية',
                    status['batteryOptimizationIgnored'] == true),
              ])),
              ListTile(
                  title: const Text('آخر نشاط'),
                  subtitle: Text(
                      '${trigger['lastRun'] ?? trigger['lastEventAt'] ?? 'لا يوجد نشاط مسجل'}')),
              ListTile(
                  title: const Text('آخر خطأ إرسال'),
                  subtitle: Text(
                      '${trigger['lastSmsError'] ?? 'لا توجد أخطاء مسجلة'}')),
              ListTile(
                  title: const Text('إجمالي أخطاء SMS'),
                  trailing: Text('${trigger['errorCount'] ?? 0}')),
              FilledButton.icon(
                  onPressed: () async {
                    try {
                      await NativeApi.instance.requestPermissions();
                      await NativeApi.instance.startService();
                      await refresh();
                    } catch (error) {
                      if (mounted)
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$error')));
                    }
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('طلب الأذونات وبدء الخدمة')),
              OutlinedButton.icon(
                  onPressed: NativeApi.instance.openBatterySettings,
                  icon: const Icon(Icons.battery_saver),
                  label: const Text('إعدادات استثناء البطارية')),
              const SizedBox(height: 12),
              const Text('إحصاءات أسباب عدم البيع',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              if (counts.isEmpty)
                const ListTile(title: Text('لا توجد أحداث مسجلة بعد.')),
              ...counts.entries.map((entry) => ListTile(
                  title: Text(_label(entry.key)),
                  trailing: Text('${entry.value}'))),
              const Divider(),
              const Text('أحدث الأحداث',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              ...events.take(20).map((event) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.event_note),
                    title: Text(_label('${event['reason'] ?? ''}')),
                    subtitle: Text(
                        '${event['time'] ?? ''}${'${event['detail'] ?? ''}'.isEmpty ? '' : ' • ${event['detail']}'}'),
                  )),
            ]),
    );
  }

  Widget _row(String label, bool ok) => ListTile(
        dense: true,
        leading: Icon(ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? Colors.green : Colors.deepOrange),
        title: Text(label),
        trailing: Text(ok ? 'جاهز' : 'يحتاج مراجعة'),
      );

  String _label(String code) => switch (code) {
        'sale_success' => 'بيع ناجح',
        'sale_sms_failed' => 'بيع ناجح مع فشل إرسال SMS',
        'sale_whatsapp_failed' => 'بيع ناجح مع فشل رد WhatsApp',
        'whatsapp_reply_failed' => 'تعذر الرد من إشعار WhatsApp',
        'whatsapp_rate_limited' => 'تجاوز حد الردود المؤقت؛ ستُعاد المحاولة',
        'whatsapp_reply_recovered' =>
          'مرّر Android رد البيع المسجل إلى WhatsApp',
        'ambiguous_keyword' => 'تطابق الطلب مع أكثر من باقة؛ لم يُصرف كرت',
        'sms_send_failed' => 'فشل إرسال الرسالة',
        'out_of_stock' => 'نفاد المخزون',
        'rejected' => 'رفض بسبب صلاحية أو حد',
        'excluded' => 'طلب مستثنى',
        'unmatched_keyword' => 'كلمة طلب غير مطابقة',
        _ => code,
      };
}
