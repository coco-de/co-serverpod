import 'dart:typed_data';

import 'package:serverpod_offline_sync/src/database/merge_utils/database_helpers.dart';
import 'package:serverpod_offline_sync/src/database/merge_utils/unique_resolver.dart';
import 'package:serverpod_serialization/serverpod_serialization.dart';
import 'package:test/test.dart';

/// The UUID probe and the value equality projection compares with
/// (co-serverpod#41).
///
/// Both used to throw and catch once per value that cannot be a UUID, and a
/// binary column compared byte by byte, so one 2 KB payload was 2,048 throws.
/// The fast paths must answer exactly what the throwing versions answered;
/// [_referenceTryUuidValue] and [_referenceEqual] are those versions, kept
/// here as the oracle.
///
/// | Case | Pinned |
/// |---|---|
/// | Every kind of domain value | probe answers what the throwing probe did |
/// | Every pair of those values | equality answers what the recursive one did |
/// | Two 1 MiB payloads differing in the last byte | compared without a throw per byte |
void main() {
  final uuid = UuidValue.fromString('0192a3b4-0000-7000-8000-000000000041');
  final values = <Object?>[
    null,
    uuid,
    UuidValue.fromString(uuid.uuid),
    uuid.uuid,
    uuid.uuid.toUpperCase(),
    'not a uuid',
    '',
    Uint8List.fromList(List.generate(16, (i) => i)),
    Uint8List.fromList(List.generate(16, (i) => i)),
    Uint8List.fromList(List.generate(16, (i) => 15 - i)),
    Uint8List.fromList([1, 2, 3]),
    Uint8List(0),
    ByteData(4),
    0,
    1,
    1.0,
    double.nan,
    true,
    false,
    DateTime.utc(2026, 9, 28),
    DateTime.utc(2026, 9, 28),
    const Duration(seconds: 1),
    BigInt.one,
    Uri.parse('https://example.com'),
    <Object?>[1, 2, 3],
    <Object?>[1, uuid.uuid],
    <Object?>[1, uuid],
    <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    <String, Object?>{'a': 1},
    <String, Object?>{'a': uuid},
    <String, Object?>{'a': uuid.uuid},
    <Object?>{1},
  ];

  group('Given every kind of domain value,', () {
    test('should_answer_what_the_throwing_probe_answered_when_probed_for_a_uuid', () {
      for (final value in values) {
        expect(
          tryUuidValue(value)?.uuid,
          _referenceTryUuidValue(value)?.uuid,
          reason: '${value.runtimeType} $value',
        );
      }
    });

    test('should_answer_what_the_recursive_equality_answered_for_every_pair', () {
      for (final left in values) {
        for (final right in values) {
          expect(
            projectionValuesEqual(left, right),
            _referenceEqual(left, right),
            reason: '${left.runtimeType} $left == ${right.runtimeType} $right',
          );
        }
      }
    });
  });

  group('Given two 1 MiB payloads that differ in the last byte,', () {
    test('should_compare_them_without_a_throw_per_byte', () {
      final left = Uint8List(1 << 20);
      final right = Uint8List(1 << 20)..[(1 << 20) - 1] = 1;
      final same = Uint8List.fromList(left);
      // Warm up so the measured calls are not the compile.
      projectionValuesEqual(left, same);

      final watch = Stopwatch()..start();
      final equal = projectionValuesEqual(left, same);
      final unequal = projectionValuesEqual(left, right);
      watch.stop();

      expect(equal, isTrue);
      expect(unequal, isFalse);
      // A throw per byte took seconds for this; the byte loop takes about a
      // millisecond.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 250)));
    });
  });
}

/// The probe before co-serverpod#41.
UuidValue? _referenceTryUuidValue(Object? value) {
  try {
    return value.toUuidValue();
  } on Object {
    return null;
  }
}

/// The equality before co-serverpod#41.
bool _referenceEqual(Object? left, Object? right) {
  if (left == null || right == null) return left == right;
  if (left is String && right is String) return left == right;
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.entries.every(
          (entry) =>
              right.containsKey(entry.key) &&
              _referenceEqual(entry.value, right[entry.key]),
        );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_referenceEqual(left[index], right[index])) return false;
    }
    return true;
  }
  final leftUuid = _referenceTryUuidValue(left);
  final rightUuid = _referenceTryUuidValue(right);
  if (leftUuid != null && rightUuid != null) {
    return leftUuid.sameUuidValue(rightUuid);
  }
  return left == right;
}
