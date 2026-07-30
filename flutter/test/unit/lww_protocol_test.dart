import 'package:app_client/src/services/lww_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonical payload vectors match the backend storage contract', () {
    final vectors = <String, Map<String, dynamic>>{
      'clients': {
        'name': 'Café 😀 \u2028',
        'address': '',
        'site_address': null,
        'email': '',
        'phone': '',
        'latitude': 11.123456789,
        'longitude': -0.0,
        'discounted_price': 44.44,
      },
      'items': {
        'name': 'Boundary item',
        'price': 99999999.99,
        'enabled': true,
      },
      'rectangles': {
        'length': 11.123456789,
        'width': 0.0000001,
      },
      'default_prices': {
        'price': 0.1,
        'enabled': false,
      },
    };
    const backendHashes = <String, String>{
      'clients':
          'df08a015b04e3521edaadb46197aa5ce26fd4e0fae03544d3df0db58de950f3d',
      'items':
          'd8ce3a82b06f7ffc13b99e76425887a03fdcd0386ffb2f8ff37d054eeef6c6df',
      'rectangles':
          'd734c8f3c1f3d7d2446e5d4542767f2f1a51294569e46930007a2b2f922a4d73',
      'default_prices':
          '58014b4238e9973e2d73add9c382cc33d07c6d7ce20fbb9e016f9d666b78badc',
    };

    for (final entry in vectors.entries) {
      expect(
        canonicalLwwMutablePayloadHash(entry.key, entry.value),
        backendHashes[entry.key],
        reason: '${entry.key} drifted from the backend canonical vector',
      );
    }
  });

  test('only storage-equivalent forms share a canonical client hash', () {
    final raw = <String, dynamic>{
      'name': 'Café 😀 \u2028',
      'address': '',
      'site_address': null,
      'email': '',
      'phone': '',
      'latitude': 11.123456789,
      'longitude': -0.0,
      'discounted_price': 44.44,
    };
    final canonical = canonicalLwwMutablePayload('clients', raw);
    expect(canonical['email'], isNull);
    expect(canonical['address'], '');
    expect(canonical['phone'], '');
    expect(canonical['site_address'], isNull);
    expect(canonical['longitude'], 0);
    expect(canonical['latitude'], 11.123456954956055);

    String hash(Map<String, dynamic> payload) =>
        canonicalLwwMutablePayloadHash('clients', payload);

    expect(hash({...raw, 'email': null}), hash(raw));
    expect(hash({...raw, 'longitude': 0}), hash(raw));
    expect(hash({...raw, 'address': null}), isNot(hash(raw)));
    expect(hash({...raw, 'site_address': ''}), isNot(hash(raw)));
    expect(
      hash({...raw, 'email': 'intent@example.com'}),
      isNot(hash(raw)),
    );
    expect(
      canonicalLwwMutablePayloadHash(
        'items',
        {'name': 'Item', 'price': 10, 'enabled': true},
      ),
      canonicalLwwMutablePayloadHash(
        'items',
        {'name': 'Item', 'price': 10.0, 'enabled': true},
      ),
    );
    expect(
      canonicalLwwMutablePayloadHash(
        'items',
        {'name': 'Item', 'price': 10.01, 'enabled': true},
      ),
      isNot(
        canonicalLwwMutablePayloadHash(
          'items',
          {'name': 'Item', 'price': 10, 'enabled': true},
        ),
      ),
    );
  });
}
