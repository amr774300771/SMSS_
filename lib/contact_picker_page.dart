import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'skeleton_widgets.dart';

const _selectionBlue = Color(0xFF2563EB);
const _selectionBlueLight = Color(0xFFDBEAFE);
const _selectionBlueDark = Color(0xFF1E3A5F);

class ContactRecipient {
  final String id;
  final String name;
  final String phone;
  final Uint8List? photo;
  final List<String> phones;

  const ContactRecipient({
    required this.id,
    required this.name,
    required this.phone,
    this.photo,
    this.phones = const [],
  });
}

class ContactsPermissionDenied implements Exception {
  final bool permanent;
  const ContactsPermissionDenied({this.permanent = false});
}

typedef ContactsLoader = Future<List<ContactRecipient>> Function();

/// يقرأ جهات الاتصال من الجهاز بعد طلب إذن READ_CONTACTS.
/// يستخدم الصورة المصغرة فقط حتى تبقى الذاكرة منخفضة مع آلاف الجهات.
Future<List<ContactRecipient>> loadDeviceContacts() async {
  final status = await Permission.contacts.request();
  if (!status.isGranted) {
    throw ContactsPermissionDenied(permanent: status.isPermanentlyDenied);
  }
  final values = await FlutterContacts.getContacts(
      withProperties: true, withThumbnail: true, withPhoto: false);
  final result = <ContactRecipient>[];
  for (final contact in values) {
    final phones = contact.phones
        .map((p) => p.number.trim())
        .where((n) => n.isNotEmpty)
        .toList();
    if (phones.isEmpty) continue;
    result.add(ContactRecipient(
      id: contact.id,
      name: contact.displayName.trim(),
      phone: phones.first,
      photo: contact.thumbnail,
      phones: phones,
    ));
  }
  return result;
}

const _arabicOrder = 'ابتثجحخدذرزسشصضطظعغفقكلمنهوي';

bool _isArabicRune(int rune) => rune >= 0x0621 && rune <= 0x064A;
bool _isLatinRune(int rune) =>
    (rune >= 0x61 && rune <= 0x7A) || (rune >= 0x41 && rune <= 0x5A);

/// يوحّد صيغ الحروف العربية (أ إ آ ← ا، ى ← ي، ة ← ه، ؤ ← و، ئ ← ي)
/// ويحذف التشكيل والتطويل حتى يعمل البحث والفرز بشكل صحيح.
String normalizeArabicName(String input) {
  final buffer = StringBuffer();
  for (final rune in input.trim().toLowerCase().runes) {
    if ((rune >= 0x064B && rune <= 0x065F) ||
        rune == 0x0670 ||
        rune == 0x0640) {
      continue;
    }
    if (rune == 0x0623 || rune == 0x0625 || rune == 0x0622 || rune == 0x0671) {
      buffer.writeCharCode(0x0627);
    } else if (rune == 0x0649 || rune == 0x0626) {
      buffer.writeCharCode(0x064A);
    } else if (rune == 0x0629) {
      buffer.writeCharCode(0x0647);
    } else if (rune == 0x0624) {
      buffer.writeCharCode(0x0648);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// حرف الفاصل: الحرف العربي الأول، أو الحرف اللاتيني الكبير، أو #.
String contactGroupLetter(String name) {
  final normalized = normalizeArabicName(name);
  if (normalized.isEmpty) return '#';
  final first = normalized.runes.first;
  if (_isArabicRune(first)) return String.fromCharCode(first);
  if (_isLatinRune(first)) return String.fromCharCode(first).toUpperCase();
  return '#';
}

int _scriptRank(String normalized) {
  if (normalized.isEmpty) return 3;
  final first = normalized.runes.first;
  if (_isArabicRune(first)) return 0;
  if (_isLatinRune(first)) return 1;
  return 2;
}

int _runeKey(int rune) {
  final index = _arabicOrder.indexOf(String.fromCharCode(rune));
  return index >= 0 ? index : 100 + rune;
}

/// مقارنة أسماء بترتيب أبجدي عربي ثم لاتيني ثم بقية الرموز.
int compareContactNames(String a, String b) {
  final na = normalizeArabicName(a);
  final nb = normalizeArabicName(b);
  final rank = _scriptRank(na).compareTo(_scriptRank(nb));
  if (rank != 0) return rank;
  final ra = na.runes.toList();
  final rb = nb.runes.toList();
  final shared = ra.length < rb.length ? ra.length : rb.length;
  for (var i = 0; i < shared; i++) {
    final result = _runeKey(ra[i]).compareTo(_runeKey(rb[i]));
    if (result != 0) return result;
  }
  return ra.length.compareTo(rb.length);
}

String contactCountLabel(int count) {
  if (count == 1) return 'تم اختيار جهة اتصال واحدة';
  if (count == 2) return 'تم اختيار جهتي اتصال';
  if (count >= 3 && count <= 10) return 'تم اختيار $count جهات اتصال';
  return 'تم اختيار $count جهة اتصال';
}

String defaultContactPhoneKey(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
}

class _Row {
  final String? header;
  final bool favoriteHeader;
  final ContactRecipient? contact;
  const _Row.header(this.header, {this.favoriteHeader = false})
      : contact = null;
  const _Row.contact(ContactRecipient this.contact)
      : header = null,
        favoriteHeader = false;
}

class ContactPickerPage extends StatefulWidget {
  final List<ContactRecipient> initialSelection;
  final ContactsLoader? loader;
  final Set<String> favoritePhoneKeys;
  final String Function(String)? phoneKey;

  const ContactPickerPage({
    super.key,
    this.initialSelection = const [],
    this.loader,
    this.favoritePhoneKeys = const {},
    this.phoneKey,
  });

  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  final search = TextEditingController();
  List<ContactRecipient> contacts = const [];
  final Map<String, String> searchBlobs = {};
  final selected = <String, ContactRecipient>{};
  List<_Row> rows = const [];
  List<ContactRecipient> visibleContacts = const [];
  bool loading = true;
  String? error;
  bool permissionProblem = false;

  String Function(String) get keyOf =>
      widget.phoneKey ?? defaultContactPhoneKey;

  @override
  void initState() {
    super.initState();
    for (final item in widget.initialSelection) {
      selected[item.id] = item;
    }
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
      permissionProblem = false;
    });
    try {
      final values =
          List<ContactRecipient>.of(await (widget.loader ?? loadDeviceContacts)());
      values.sort((a, b) => compareContactNames(a.name, b.name));
      searchBlobs
        ..clear()
        ..addEntries(values.map((item) {
          final numbers = item.phones.isEmpty ? [item.phone] : item.phones;
          final digits = numbers.join(' ').replaceAll(RegExp(r'[\s\-()]'), '');
          return MapEntry(item.id, '${normalizeArabicName(item.name)} $digits');
        }));
      if (!mounted) return;
      contacts = values;
      loading = false;
      _rebuildRows();
      setState(() {});
    } on ContactsPermissionDenied catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        permissionProblem = true;
        error = e.permanent
            ? 'تم رفض إذن جهات الاتصال. فعّله من إعدادات التطبيق ثم ارجع إلى هذه الشاشة.'
            : 'يلزم السماح بالوصول إلى جهات الاتصال لاختيار المستلمين.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'تعذر قراءة جهات الاتصال. تحقق من الإذن ثم أعد المحاولة.';
      });
    }
  }

  bool _isFavorite(ContactRecipient item) {
    if (widget.favoritePhoneKeys.isEmpty) return false;
    final numbers = item.phones.isEmpty ? [item.phone] : item.phones;
    return numbers.any((n) => widget.favoritePhoneKeys.contains(keyOf(n)));
  }

  void _rebuildRows() {
    final query = normalizeArabicName(search.text);
    final queryDigits = search.text.replaceAll(RegExp(r'[\s\-()]'), '');
    final filtered = query.isEmpty
        ? contacts
        : contacts.where((item) {
            final blob = searchBlobs[item.id] ?? '';
            return blob.contains(query) ||
                (queryDigits.isNotEmpty && blob.contains(queryDigits));
          }).toList();
    visibleContacts = filtered;
    final built = <_Row>[];
    final favorites = query.isEmpty
        ? filtered.where(_isFavorite).toList()
        : <ContactRecipient>[];
    if (favorites.isNotEmpty) {
      built.add(const _Row.header('المفضلة', favoriteHeader: true));
      built.addAll(favorites.map(_Row.contact));
    }
    final favoriteIds = favorites.map((item) => item.id).toSet();
    String? lastLetter;
    for (final item in filtered) {
      if (favoriteIds.contains(item.id)) continue;
      final letter = contactGroupLetter(item.name);
      if (letter != lastLetter) {
        built.add(_Row.header(letter));
        lastLetter = letter;
      }
      built.add(_Row.contact(item));
    }
    rows = built;
  }

  void toggle(ContactRecipient item) {
    setState(() {
      if (selected.remove(item.id) == null) selected[item.id] = item;
    });
  }

  void selectAll() {
    setState(() {
      for (final item in visibleContacts) {
        selected[item.id] = item;
      }
    });
  }

  void clearSelection() => setState(selected.clear);

  Color avatarColor(String name) {
    final value = name.runes.fold<int>(0, (sum, rune) => sum + rune);
    const colors = [
      Color(0xFF0EA5E9),
      Color(0xFF8B5CF6),
      Color(0xFF10B981),
      Color(0xFFF97316),
      Color(0xFFE11D48),
      Color(0xFF0891B2),
      Color(0xFFD97706),
      Color(0xFF7C3AED),
    ];
    return colors[value % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(selected.isEmpty
              ? 'اختيار جهات الاتصال'
              : contactCountLabel(selected.length)),
          leading: IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'إغلاق',
              onPressed: () => Navigator.pop(context)),
          actions: [
            IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: 'حذف المحدد',
                onPressed: selected.isEmpty ? null : clearSelection),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: TextField(
                controller: search,
                onChanged: (_) {
                  _rebuildRows();
                  setState(() {});
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'ابحث بالاسم أو الرقم',
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح البحث',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            search.clear();
                            _rebuildRows();
                            setState(() {});
                          }),
                ),
              ),
            ),
            if (!loading && error == null && contacts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(children: [
                  Expanded(
                    child: Text(
                        '${visibleContacts.length} جهة اتصال • المحدد ${selected.length}',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12.5)),
                  ),
                  TextButton(
                      onPressed: visibleContacts.isEmpty ? null : selectAll,
                      child: const Text('تحديد الكل')),
                  TextButton(
                      onPressed: selected.isEmpty ? null : clearSelection,
                      child: const Text('إلغاء التحديد')),
                ]),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Icon(Icons.contacts_outlined,
                      size: 48, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text(error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                      onPressed: load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('إعادة الطلب')),
                  if (permissionProblem)
                    const TextButton(
                        onPressed: openAppSettings,
                        child: const Text('فتح إعدادات التطبيق')),
                ]),
              )
            else if (loading)
              const Expanded(child: AppSkeleton(rows: 7))
            else if (contacts.isEmpty)
              const Expanded(
                  child: Center(
                      child: Text('لا توجد جهات اتصال تحتوي على أرقام.')))
            else if (rows.isEmpty)
              Expanded(
                  child: Center(
                      child: Text('لا نتائج لـ "${search.text.trim()}"')))
            else
              Expanded(
                child: ListView.builder(
                  key: const PageStorageKey('contact-list'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: rows.length,
                  itemExtentBuilder: (index, _) =>
                      rows[index].header != null ? 40 : 76,
                  itemBuilder: (_, index) {
                    final row = rows[index];
                    final header = row.header;
                    if (header != null) {
                      return Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (row.favoriteHeader)
                            const Padding(
                              padding: EdgeInsetsDirectional.only(end: 6),
                              child: Icon(Icons.star_rounded,
                                  size: 18, color: Color(0xFFF59E0B)),
                            ),
                          Text(header,
                              style: TextStyle(
                                  color: row.favoriteHeader
                                      ? const Color(0xFFD97706)
                                      : scheme.primary,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14)),
                        ]),
                      );
                    }
                    final item = row.contact!;
                    final isSelected = selected.containsKey(item.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: isSelected
                            ? (dark ? _selectionBlueDark : _selectionBlueLight)
                            : scheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => toggle(item),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected
                                    ? _selectionBlue.withValues(alpha: .55)
                                    : scheme.outlineVariant
                                        .withValues(alpha: .45),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(children: [
                              _ContactAvatar(
                                  item: item,
                                  color: avatarColor(item.name),
                                  selected: isSelected),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        item.name.isEmpty
                                            ? 'بدون اسم'
                                            : item.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    const SizedBox(height: 2),
                                    Text(item.phone,
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                            color: scheme.onSurfaceVariant,
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: FilledButton.icon(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, selected.values.toList()),
            icon: const Icon(Icons.send_rounded),
            label: Text('إرسال إلى (${selected.length})'),
          ),
        ),
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  final ContactRecipient item;
  final Color color;
  final bool selected;

  const _ContactAvatar(
      {required this.item, required this.color, required this.selected});

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return const CircleAvatar(
        radius: 23,
        backgroundColor: _selectionBlue,
        child: Icon(Icons.check_rounded, color: Colors.white, size: 26),
      );
    }
    final photo = item.photo;
    final hasPhoto = photo != null && photo.isNotEmpty;
    return CircleAvatar(
      radius: 23,
      backgroundColor: color,
      backgroundImage: hasPhoto ? MemoryImage(photo) : null,
      child: hasPhoto
          ? null
          : Text(
              item.name.trim().isEmpty
                  ? '?'
                  : String.fromCharCode(item.name.trim().runes.first),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18)),
    );
  }
}
