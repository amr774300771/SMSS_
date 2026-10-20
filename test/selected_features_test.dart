import 'package:flutter_test/flutter_test.dart';
import 'package:cardbot_qaidi/selected_features.dart';

void main() {
  group('effective pricing', () {
    test('customer package price takes precedence over group price', () {
      final permissions = {
        'global': {
          'priceGroups': [
            {
              'id': 'wholesale',
              'discountPercent': 10,
              'packagePrices': {'500': 420}
            },
          ],
        },
        'clients': [
          {
            'phone': '777123456',
            'priceGroup': 'wholesale',
            'packagePrices': {'500': 400},
          },
        ],
      };
      expect(
        SelectedFeatures.effectivePrice(
          permissions: permissions,
          phone: '0777123456',
          packageId: '500',
          basePrice: 500,
        ),
        400,
      );
    });

    test('group discount applies if no exact package price exists', () {
      final permissions = {
        'global': {
          'priceGroups': [
            {'id': 'wholesale', 'discountPercent': 10},
          ],
        },
        'clients': [
          {'phone': '777123456', 'priceGroup': 'wholesale'},
        ],
      };
      expect(
        SelectedFeatures.effectivePrice(
          permissions: permissions,
          phone: '777123456',
          packageId: '500',
          basePrice: 500,
        ),
        450,
      );
    });

    test('customer discount takes precedence over group discount', () {
      final permissions = {
        'global': {
          'priceGroups': [
            {'id': 'wholesale', 'discountPercent': 10},
          ],
        },
        'clients': [
          {
            'phone': '777123456',
            'priceGroup': 'wholesale',
            'discountPercent': 20,
          },
        ],
      };
      expect(
        SelectedFeatures.effectivePrice(
          permissions: permissions,
          phone: '777123456',
          packageId: '500',
          basePrice: 500,
        ),
        400,
      );
    });
  });

  test('keyword conflicts identify duplicate and overlapping trigger phrases',
      () {
    final conflicts = SelectedFeatures.keywordConflicts([
      {
        'id': '300',
        'keywords': ['باقة']
      },
      {
        'id': '500',
        'keywords': ['باقة 500', 'باقة 500']
      },
    ]);
    expect(conflicts, isNotEmpty);
    expect(conflicts.any((value) => value.contains('تتداخل')), isTrue);
    expect(conflicts.any((value) => value.contains('مكررة')), isTrue);
  });

  test('excluded phone and keyword match normalized Arabic phone and text', () {
    final package = {
      'excludedPhones': ['0777123456'],
      'excludedKeywords': ['تجربة'],
    };
    expect(
      SelectedFeatures.isPackageExcluded(
        package: package,
        phone: '+967777123456',
        message: 'أريد 500',
      ),
      isTrue,
    );
    expect(
      SelectedFeatures.isPackageExcluded(
        package: package,
        phone: '777000000',
        message: 'أريد 500 تجربة',
      ),
      isTrue,
    );
    expect(
      SelectedFeatures.isPackageExcluded(
        package: package,
        phone: '777000000',
        message: 'أريد 500 تجريبية',
      ),
      isFalse,
    );
  });

  test('phone keys normalize Yemen country code and Arabic-Indic digits', () {
    expect(SelectedFeatures.phoneKey('+967777123456'), '777123456');
    expect(SelectedFeatures.phoneKey('0777123456'), '777123456');
    expect(SelectedFeatures.phoneKey('٠٧٧٧١٢٣٤٥٦'), '777123456');
  });
}
