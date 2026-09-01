import 'dart:math';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

/// 결정적 시드로 무작위 RowState 를 만든다.
RowState randomState(Random random, {String rowId = 'r1'}) {
  const names = ['a', 'b', 'c', 'd', 'e', kDeletedField];
  final fields = <String, FieldValue>{};
  final count = 1 + random.nextInt(names.length);
  final picked = [...names]..shuffle(random);
  for (final name in picked.take(count)) {
    final Object? value;
    if (name == kDeletedField) {
      value = random.nextBool();
    } else {
      value = switch (random.nextInt(4)) {
        0 => random.nextInt(1000),
        1 => 'v${random.nextInt(1000)}',
        2 => null,
        _ => [random.nextInt(10), 'x'],
      };
    }
    fields[name] = FieldValue(
      value,
      Hlc(random.nextInt(100), random.nextInt(4), 'n${1 + random.nextInt(3)}'),
    );
  }
  return RowState(rowId: rowId, fields: fields);
}

void main() {
  group('mergeRowStates 격자 성질 (시드 고정 무작위)', () {
    test('교환법칙: merge(a,b) == merge(b,a) — 500회', () {
      final random = Random(11);
      for (var i = 0; i < 500; i++) {
        final a = randomState(random);
        final b = randomState(random);
        expect(
          rowStatesEqual(mergeRowStates(a, b), mergeRowStates(b, a)),
          isTrue,
          reason: 'iter=$i\na=$a\nb=$b',
        );
      }
    });

    test('결합법칙: merge(merge(a,b),c) == merge(a,merge(b,c)) — 500회', () {
      final random = Random(13);
      for (var i = 0; i < 500; i++) {
        final a = randomState(random);
        final b = randomState(random);
        final c = randomState(random);
        expect(
          rowStatesEqual(
            mergeRowStates(mergeRowStates(a, b), c),
            mergeRowStates(a, mergeRowStates(b, c)),
          ),
          isTrue,
          reason: 'iter=$i',
        );
      }
    });

    test('멱등: merge(a,a) == a — 200회', () {
      final random = Random(17);
      for (var i = 0; i < 200; i++) {
        final a = randomState(random);
        expect(rowStatesEqual(mergeRowStates(a, a), a), isTrue);
      }
    });

    test('수렴: 같은 상태 집합은 적용 순서와 무관하게 같은 결과 — 200회', () {
      final random = Random(19);
      for (var i = 0; i < 200; i++) {
        final states = List.generate(5, (_) => randomState(random));
        RowState fold(List<RowState> ordered) => ordered.reduce(mergeRowStates);
        final baseline = fold(states);
        for (var p = 0; p < 5; p++) {
          final shuffled = [...states]..shuffle(random);
          expect(
            rowStatesEqual(fold(shuffled), baseline),
            isTrue,
            reason: 'iter=$i perm=$p',
          );
        }
      }
    });

    test('완전히 같은 HLC 에 다른 값이면 결정적·교환적으로 해소된다', () {
      const hlc = Hlc(50, 0, 'n1');
      final a = RowState(
        rowId: 'r1',
        fields: const {'x': FieldValue('apple', hlc)},
      );
      final b = RowState(
        rowId: 'r1',
        fields: const {'x': FieldValue('banana', hlc)},
      );
      final ab = mergeRowStates(a, b);
      final ba = mergeRowStates(b, a);
      expect(rowStatesEqual(ab, ba), isTrue);
      expect(ab.fields['x']!.value, 'banana'); // JSON 사전순 큰 값
    });
  });

  group('TombstonePolicy 뷰', () {
    RowState deletedAt(Hlc del, {Map<String, FieldValue> extra = const {}}) =>
        RowState(
          rowId: 'r1',
          fields: {kDeletedField: FieldValue(true, del), ...extra},
        );

    test('D-1: 삭제 후 어떤 편집도 없으면 두 정책 모두 삭제로 본다', () {
      final state = deletedAt(
        const Hlc(100, 0, 'A'),
        extra: const {'title': FieldValue('메모', Hlc(50, 0, 'A'))},
      );
      expect(state.isDeleted(TombstonePolicy.deleteWins), isTrue);
      expect(state.isDeleted(TombstonePolicy.editWins), isTrue);
    });

    test('삭제보다 나중의 편집: deleteWins 는 삭제, editWins 는 생존', () {
      final state = deletedAt(
        const Hlc(100, 0, 'A'),
        extra: const {'title': FieldValue('수정', Hlc(200, 0, 'B'))},
      );
      expect(state.isDeleted(TombstonePolicy.deleteWins), isTrue);
      expect(state.isDeleted(TombstonePolicy.editWins), isFalse);
    });

    test(r'명시적 restore($deleted=false 가 최신)는 두 정책 모두 생존', () {
      final state = RowState(
        rowId: 'r1',
        fields: const {
          kDeletedField: FieldValue(false, Hlc(300, 0, 'A')),
          'title': FieldValue('메모', Hlc(50, 0, 'A')),
        },
      );
      expect(state.isDeleted(TombstonePolicy.deleteWins), isFalse);
      expect(state.isDeleted(TombstonePolicy.editWins), isFalse);
    });

    test('한 번도 삭제된 적 없는 행은 생존', () {
      final state = RowState(
        rowId: 'r1',
        fields: const {'title': FieldValue('메모', Hlc(50, 0, 'A'))},
      );
      expect(state.isDeleted(TombstonePolicy.deleteWins), isFalse);
      expect(state.isDeleted(TombstonePolicy.editWins), isFalse);
    });
  });

  group('RowState 코덱', () {
    test('toJson/fromJson 왕복이 항등이다', () {
      final random = Random(23);
      for (var i = 0; i < 100; i++) {
        final state = randomState(random);
        expect(
          rowStatesEqual(RowState.fromJson(state.toJson()), state),
          isTrue,
        );
      }
    });
  });

  group('computeSchemaSignature', () {
    test('테이블·컬럼 순서와 무관하게 같은 서명', () {
      final a = computeSchemaSignature({
        'bookmark': ['id', 'title', 'page'],
        'note': ['id', 'body'],
      });
      final b = computeSchemaSignature({
        'note': ['body', 'id'],
        'bookmark': ['page', 'id', 'title'],
      });
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('컬럼이 추가되면 서명이 달라진다', () {
      final a = computeSchemaSignature({
        'bookmark': ['id', 'title'],
      });
      final b = computeSchemaSignature({
        'bookmark': ['id', 'title', 'color'],
      });
      expect(a, isNot(b));
    });
  });
}
