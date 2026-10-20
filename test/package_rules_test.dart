import 'package:flutter_test/flutter_test.dart';
import 'package:cardbot_qaidi/package_rules.dart';

void main() {
  group('PackageRules.parsePrice', () {
    test('accepts English, Arabic-Indic and Persian digits', () {
      expect(PackageRules.parsePrice('500'), 500);
      expect(PackageRules.parsePrice('٥٠٠'), 500);
      expect(PackageRules.parsePrice('۵۰۰'), 500);
    });

    test('accepts grouped digits and rejects invalid or zero prices', () {
      expect(PackageRules.parsePrice('1,000'), 1000);
      expect(PackageRules.parsePrice('١٬٠٠٠'), 1000);
      expect(PackageRules.parsePrice('1,5'), isNull);
      expect(PackageRules.parsePrice('0'), isNull);
      expect(PackageRules.parsePrice('خمسمائة'), isNull);
      expect(PackageRules.parsePrice('-500'), isNull);
    });
  });

  group('PackageRules.parseNonNegativeAmount', () {
    test('accepts zero and localized digits with valid grouping', () {
      expect(PackageRules.parseNonNegativeAmount('0'), 0);
      expect(PackageRules.parseNonNegativeAmount('١٬٢٥٠'), 1250);
      expect(PackageRules.parseNonNegativeAmount('1,250'), 1250);
    });

    test('rejects negative, malformed and empty values', () {
      expect(PackageRules.parseNonNegativeAmount('-1'), isNull);
      expect(PackageRules.parseNonNegativeAmount('12,50'), isNull);
      expect(PackageRules.parseNonNegativeAmount(''), isNull);
    });
  });

  group('PackageRules.validatePackages', () {
    test('accepts 300 and 500 packages with several aliases', () {
      expect(
        PackageRules.validatePackages([
          {
            'id': '500',
            'price': 500,
            'keywords': [
              '500',
              'خمس',
              'كرت 500',
              'باقة 500',
              'net500',
              'أرسل لي كرت ابو 500'
            ],
          },
          {
            'id': '300',
            'price': 300,
            'keywords': ['300', 'ثلاثمائة']
          },
        ]),
        isNull,
      );
    });

    test(
        'rejects duplicate IDs, price/ID mismatch and cross-package keyword collision',
        () {
      expect(
        PackageRules.validatePackages([
          {
            'id': '500',
            'price': 500,
            'keywords': ['500']
          },
          {
            'id': '500',
            'price': 500,
            'keywords': ['500']
          },
        ]),
        contains('معرّف'),
      );
      expect(
        PackageRules.validatePackages([
          {
            'id': '500',
            'price': 300,
            'keywords': ['500']
          },
        ]),
        contains('يساوي'),
      );
      expect(
        PackageRules.validatePackages([
          {
            'id': '500',
            'price': 500,
            'keywords': ['كرت ابو 500']
          },
          {
            'id': '300',
            'price': 300,
            'keywords': ['كرت ابو 500']
          },
        ]),
        contains('مستخدمة'),
      );
      expect(
        PackageRules.validatePackages([
          {
            'id': '500',
            'price': 500,
            'keywords': ['500']
          },
          {
            'id': '300',
            'price': 300,
            'keywords': ['باقة 500']
          },
        ]),
        contains('تتداخل'),
      );
    });

    test(
        'allows an unchanged legacy package while requiring new packages to match price',
        () {
      final legacy = <Map<String, dynamic>>[
        {
          'id': 'legacy500',
          'price': 500,
          'label': '500',
          'keywords': ['500', 'خمس']
        },
      ];
      final withNewPackage = [
        ...legacy,
        {
          'id': '300',
          'price': 300,
          'label': '300',
          'keywords': ['300', 'ثلاثمائة']
        },
      ];
      expect(
        PackageRules.validatePackages(withNewPackage,
            allowUnchangedLegacy: legacy),
        isNull,
      );
      final changedLegacy = [
        {
          'id': 'legacy500',
          'price': 500,
          'label': '500',
          'keywords': ['old alias changed']
        },
        withNewPackage.last,
      ];
      expect(
        PackageRules.validatePackages(changedLegacy,
            allowUnchangedLegacy: legacy),
        contains('يساوي'),
      );
    });
  });

  test(
      'all request phrases resolve to the same package and 300 stays independent',
      () {
    final packages = <Map<String, dynamic>>[
      {
        'id': '500',
        'price': 500,
        'keywords': [
          '500',
          'خمس',
          'كرت 500',
          'باقة 500',
          'net500',
          'أرسل لي كرت ابو 500'
        ],
      },
      {
        'id': '300',
        'price': 300,
        'keywords': ['300', 'ثلاثمائة']
      },
    ];
    for (final message in [
      '500',
      'خمس',
      'أريد كرت 500',
      'أريد باقة 500',
      'net500',
      'أرسل لي كرت ابو 500',
    ]) {
      expect(PackageRules.matchPackageId(message, packages), '500',
          reason: message);
    }
    expect(PackageRules.matchPackageId('ثلاثمائة لو سمحت', packages), '300');
    expect(PackageRules.matchPackageId('net5000', packages), isNull);
  });
}
