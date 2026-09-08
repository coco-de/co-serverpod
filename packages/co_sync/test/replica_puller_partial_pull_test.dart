import 'dart:async';

import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// S7-3 (#12754) — 도메인 부분 pull 과 도메인별 lastErrors.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  ReplicaPage page(String id) => ReplicaPage(
    rows: [
      ReplicaRowChange(rowId: id, dataJson: '{}', serverUpdatedAtMillis: 1),
    ],
    nextCursor: 'c-$id',
    hasMore: false,
  );

  test('pull(domains) 는 지정 도메인만 조회한다', () async {
    final calls = <String>[];
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'likes': (_) async {
          calls.add('likes');
          return page('1');
        },
        'meta': (_) async {
          calls.add('meta');
          return page('2');
        },
        'orders': (_) async {
          calls.add('orders');
          return page('3');
        },
      },
    );

    await puller.pull({'likes', 'meta'});

    expect(calls.toSet(), {'likes', 'meta'});
    expect(await store.getDomain('orders'), isEmpty);
  });

  test('등록되지 않은 도메인은 ArgumentError — 조용한 no-op 이 아니다', () async {
    final puller = ReplicaPuller(store: store, domains: const {});
    await expectLater(puller.pull({'ghost'}), throwsArgumentError);
  });

  test('lastErrors 는 도메인별로 갱신된다 — 부분 pull 이 다른 기록을 지우지 않는다', () async {
    var likesFails = true;
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'likes': (_) async {
          if (likesFails) throw Exception('offline');
          return page('1');
        },
        'orders': (_) async => throw Exception('server 500'),
      },
    );

    await puller.pullAll();
    expect(puller.lastErrors.keys, containsAll(['likes', 'orders']));

    likesFails = false;
    await puller.pull({'likes'});
    expect(
      puller.lastErrors.containsKey('likes'),
      isFalse,
      reason: '성공은 자기 기록만 지운다',
    );
    expect(
      puller.lastErrors.containsKey('orders'),
      isTrue,
      reason: '부분 pull 이 다른 도메인의 실패 기록을 지우면 시드 게이트가 오판한다',
    );
  });

  test('같은 도메인의 동시 pull 은 실행 중인 작업에 합류한다 (도메인 단위 중첩 방지)', () async {
    final gate = Completer<void>();
    var fetches = 0;
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'likes': (_) async {
          fetches += 1;
          await gate.future;
          return page('1');
        },
      },
    );

    final first = puller.pull({'likes'});
    final second = puller.pullAll();
    gate.complete();
    await Future.wait([first, second]);

    expect(fetches, 1);
  });
}
