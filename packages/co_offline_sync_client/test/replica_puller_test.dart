import 'dart:async';

import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  ReplicaRowChange row(String id, {int at = 1000}) =>
      ReplicaRowChange(rowId: id, dataJson: '{}', serverUpdatedAtMillis: at);

  test('커서 기반 페이지네이션 — hasMore 를 따라가며 커서를 전진시킨다', () async {
    final seenCursors = <String?>[];
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'orders': (cursor) async {
          seenCursors.add(cursor);
          return switch (cursor) {
            null => ReplicaPage(
              rows: [row('1'), row('2')],
              nextCursor: 'c1',
              hasMore: true,
            ),
            'c1' => ReplicaPage(
              rows: [row('3', at: 2000)],
              nextCursor: 'c2',
              hasMore: false,
            ),
            _ => const ReplicaPage(rows: [], nextCursor: 'cX', hasMore: false),
          };
        },
      },
    );

    await puller.pullAll();

    expect(seenCursors, [null, 'c1']);
    expect(await store.getDomain('orders'), hasLength(3));
    expect(await store.loadCursor('orders'), 'c2');
    expect(puller.lastErrors, isEmpty);

    // 재pull 은 저장된 커서에서 시작한다 (증분).
    await puller.pullAll();
    expect(seenCursors.last, 'c2');
  });

  test('도메인 하나의 실패가 다른 도메인 pull 을 막지 않고, 커서도 전진하지 않는다', () async {
    final notified = <String>[];
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'broken': (_) async => throw StateError('서버 5xx'),
        'orders': (_) async =>
            ReplicaPage(rows: [row('1')], nextCursor: 'c1', hasMore: false),
      },
      onError: (domain, _, _) => notified.add(domain),
    );

    await puller.pullAll();

    expect(await store.getDomain('orders'), hasLength(1));
    expect(
      await store.loadCursor('broken'),
      isNull,
      reason: '실패 도메인은 커서 미전진 — 다음 트리거에서 같은 지점부터',
    );
    expect(puller.lastErrors.keys, ['broken']);
    expect(notified, ['broken']);
  });

  test('페이지 상한 — hasMore 고착 서버에서도 무한 루프하지 않는다', () async {
    var calls = 0;
    final puller = ReplicaPuller(
      store: store,
      maxPagesPerDomain: 3,
      domains: {
        'stuck': (_) async {
          calls++;
          return ReplicaPage(
            rows: [row('r$calls')],
            nextCursor: 'c$calls',
            hasMore: true, // 서버 결함 — 영원히 true
          );
        },
      },
    );

    await puller.pullAll();

    expect(calls, 3);
    expect(
      await store.loadCursor('stuck'),
      'c3',
      reason: '받은 만큼은 반영 — 다음 트리거가 이어받는다',
    );
  });

  test('오프라인→온라인 전이마다 1회 pull (중첩 방지 포함)', () async {
    var fetches = 0;
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'orders': (_) async {
          fetches++;
          return ReplicaPage(
            rows: [row('1')],
            nextCursor: 'c$fetches',
            hasMore: false,
          );
        },
      },
    );
    addTearDown(puller.dispose);

    final online = StreamController<bool>();
    puller.bindOnlineStream(online.stream);

    online.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(fetches, 0);

    online.add(true); // 첫 온라인 — 1회
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fetches, 1);

    online.add(true); // 전이 아님
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fetches, 1);

    online
      ..add(false)
      ..add(true); // 재전이 — 1회 추가
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fetches, 2);
    await online.close();
  });

  test('pullAll 동시 호출은 실행 중인 작업에 합류한다', () async {
    final gate = Completer<void>();
    var fetches = 0;
    final puller = ReplicaPuller(
      store: store,
      domains: {
        'orders': (_) async {
          fetches++;
          await gate.future;
          return const ReplicaPage(rows: [], nextCursor: 'c', hasMore: false);
        },
      },
    );

    final first = puller.pullAll();
    final second = puller.pullAll();
    gate.complete();
    await Future.wait([first, second]);

    expect(fetches, 1, reason: '중첩 실행 없음 — 두 호출이 한 실행에 합류');
  });
}
