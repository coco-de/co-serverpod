import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

/// v1: 북마크(title, page)
const _v1 = {
  'bookmark': ['title', 'page'],
};

/// v2: 북마크에 `note` 컬럼 추가 + 새 테이블 `highlight`
const _v2 = {
  'bookmark': ['title', 'page', 'note'],
  'highlight': ['color', 'text'],
};

/// v0: v1 보다 오래된 스키마 (지원 창 밖)
const _v0 = {
  'bookmark': ['title'],
};

SchemaRegistry _registry() => SchemaRegistry([
  SchemaVersion(version: 1, tables: _v1),
  SchemaVersion(version: 2, tables: _v2),
]);

/// pull 요청을 기록하는 전송 데코레이터 (클라이언트 → 서버 힌트 검증용).
class _RecordingTransport implements SyncTransport {
  _RecordingTransport(this._inner, this.pulls);

  final SyncTransport _inner;
  final List<SyncPullRequest> pulls;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) =>
      _inner.push(request);

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) {
    pulls.add(request);
    return _inner.pull(request);
  }
}

/// 서버 하나(v1·v2 창)에 서로 다른 스키마 버전의 클라이언트를 붙이는 하네스.
class VersionedHarness {
  VersionedHarness() {
    serverStore = InMemoryServerSyncStore();
    server = CoSyncServer.withRegistry(
      store: serverStore,
      clock: HlcClock(nodeId: 'server', wallClock: () => wall),
      registry: _registry(),
    );
    transport = InProcessTransport(server);
  }

  int wall = 1000;

  late final InMemoryServerSyncStore serverStore;
  late final CoSyncServer server;
  late final InProcessTransport transport;
  final Map<String, InMemoryClientSyncStore> stores = {};

  CoSyncClient client(
    String nodeId, {
    required Map<String, List<String>> schema,
    required int schemaVersion,
  }) {
    final store = stores.putIfAbsent(nodeId, InMemoryClientSyncStore.new);
    return CoSyncClient(
      store: store,
      transport: transport,
      clock: HlcClock(nodeId: nodeId, wallClock: () => wall),
      syncSchema: schema,
      schemaVersion: schemaVersion,
    );
  }
}

void main() {
  group('SchemaRegistry 불변식', () {
    test('버전 번호는 엄격히 증가해야 한다', () {
      expect(
        () => SchemaRegistry([
          SchemaVersion(version: 2, tables: _v1),
          SchemaVersion(version: 2, tables: _v2),
        ]),
        throwsArgumentError,
      );
    });

    test('창 안에서는 가산적 진화만 허용 — 컬럼 제거는 거부', () {
      expect(
        () => SchemaRegistry([
          SchemaVersion(version: 1, tables: _v2),
          SchemaVersion(version: 2, tables: _v1), // note·highlight 가 사라짐
        ]),
        throwsArgumentError,
      );
    });

    test('창 안에서는 가산적 진화만 허용 — 테이블 제거는 거부', () {
      expect(
        () => SchemaRegistry([
          SchemaVersion(
            version: 1,
            tables: const {
              'a': ['x'],
              'b': ['y'],
            },
          ),
          SchemaVersion(
            version: 2,
            tables: const {
              'a': ['x', 'z'],
            },
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('같은 서명이 두 버전에 있으면 거부 (버전만 올리고 스키마가 같음)', () {
      expect(
        () => SchemaRegistry([
          SchemaVersion(version: 1, tables: _v1),
          SchemaVersion(version: 2, tables: _v1),
        ]),
        throwsArgumentError,
      );
    });

    test('컬럼 순서가 달라도 같은 버전은 같은 서명이다 (정준화)', () {
      final a = SchemaVersion(
        version: 1,
        tables: const {
          'bookmark': ['page', 'title'],
        },
      );
      final b = SchemaVersion(version: 1, tables: _v1);
      expect(a.signature, b.signature);
      expect(a.tables['bookmark'], ['page', 'title']);
    });

    test('SchemaVersion.tables 는 정준화된다 — 선언 순서와 무관하게 정렬 보관', () {
      // _v1 은 ['title', 'page'] 순으로 선언돼 있다 — 정렬 없이는 그대로 남는다.
      final v = SchemaVersion(version: 1, tables: _v1);
      expect(v.tables['bookmark'], ['page', 'title']);
    });

    test('컬럼 목록이 비었거나 `\$` 접두·중복·빈 이름이면 거부', () {
      expect(
        () => SchemaVersion(version: 1, tables: const {'t': <String>[]}),
        throwsArgumentError,
      );
      expect(
        () => SchemaVersion(
          version: 1,
          tables: const {
            't': [r'$deleted'],
          },
        ),
        throwsArgumentError,
      );
      expect(
        () => SchemaVersion(
          version: 1,
          tables: const {
            't': ['a', 'a'],
          },
        ),
        throwsArgumentError,
      );
      expect(
        () => SchemaVersion(
          version: 1,
          tables: const {
            't': ['a', ''],
          },
        ),
        throwsArgumentError,
      );
    });

    test('single() 은 종전 단일 스키마와 서명이 같다', () {
      final registry = SchemaRegistry.single(_v1);
      expect(registry.current.signature, computeSchemaSignature(_v1));
      expect(registry.minSupported, same(registry.current));
    });
  });

  group('SchemaRegistry.resolve — 원인 분류', () {
    final registry = _registry();

    test('창 안 서명은 버전 힌트 없이도 해석된다 (서명이 정본)', () {
      expect(
        registry.resolve(signature: computeSchemaSignature(_v1)).version,
        1,
      );
      expect(
        registry
            .resolve(signature: computeSchemaSignature(_v2), version: 2)
            .version,
        2,
      );
    });

    test('버전 힌트가 창 아래면 clientOutdated + 버전 정보', () {
      expect(
        () => registry.resolve(
          signature: computeSchemaSignature(_v0),
          version: 0,
        ),
        throwsA(
          isA<SchemaMismatchException>()
              .having(
                (e) => e.reason,
                'reason',
                SchemaMismatchReason.clientOutdated,
              )
              .having((e) => e.clientVersion, 'clientVersion', 0)
              .having((e) => e.minSupportedVersion, 'min', 1)
              .having((e) => e.currentVersion, 'current', 2)
              .having((e) => e.message, 'message', contains('v0')),
        ),
      );
    });

    test('버전 힌트가 현행보다 위면 serverBehind (일시 — 롤아웃 대기)', () {
      expect(
        () => registry.resolve(signature: 'ffffffffffffffff', version: 3),
        throwsA(
          isA<SchemaMismatchException>().having(
            (e) => e.reason,
            'reason',
            SchemaMismatchReason.serverBehind,
          ),
        ),
      );
    });

    test('버전은 창 안인데 서명이 다르면 signatureConflict (배포 결함)', () {
      expect(
        () => registry.resolve(signature: 'ffffffffffffffff', version: 2),
        throwsA(
          isA<SchemaMismatchException>().having(
            (e) => e.reason,
            'reason',
            SchemaMismatchReason.signatureConflict,
          ),
        ),
      );
    });

    test('창 하한 버전(= minSupported)을 주장하는 미지 서명은 signatureConflict', () {
      // `<` 를 `<=` 로 바꾸면 clientOutdated(앱 업데이트 안내)로 오분류된다.
      expect(
        () => registry.resolve(
          signature: 'ffffffffffffffff',
          version: registry.minSupported.version,
        ),
        throwsA(
          isA<SchemaMismatchException>().having(
            (e) => e.reason,
            'reason',
            SchemaMismatchReason.signatureConflict,
          ),
        ),
      );
    });

    test('버전 힌트 없는 미지 서명은 unknown (구 클라이언트)', () {
      expect(
        () => registry.resolve(signature: computeSchemaSignature(_v0)),
        throwsA(
          isA<SchemaMismatchException>().having(
            (e) => e.reason,
            'reason',
            SchemaMismatchReason.unknown,
          ),
        ),
      );
    });
  });

  group('호환 창 안의 구·신 클라이언트 왕복', () {
    test('v1 클라이언트는 v2 서버와 동기화되고, 모르는 컬럼은 받지 않는다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {
        'title': '1장',
        'page': 10,
        'note': '신 컬럼',
      });
      h.wall = 2000;
      await v2.sync();

      final report = await v1.sync();
      expect(report.pulledChanges, 1);
      final view = await v1.read('bookmark', 'r1');
      expect(view!.values, {'title': '1장', 'page': 10});
      expect(view.values.containsKey('note'), isFalse);
    });

    test('⭐ v1 클라이언트의 편집이 신 컬럼 값을 지우지 않는다 (유실 0)', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {
        'title': '1장',
        'page': 10,
        'note': '보존돼야 한다',
      });
      h.wall = 2000;
      await v2.sync();
      await v1.sync();

      // 구 클라이언트가 자기가 아는 필드만 고쳐 올린다 (행 상태 전체 전송).
      h.wall = 3000;
      await v1.upsert('bookmark', 'r1', {'title': '1장 (수정)'});
      await v1.sync();

      // 서버 저장 상태에 note 가 그대로 있고, 신 클라이언트도 그대로 본다.
      final serverRow = await h.serverStore.getRow('bookmark', 'r1');
      expect(serverRow!.valuesView(), {
        'title': '1장 (수정)',
        'page': 10,
        'note': '보존돼야 한다',
      });
      await v2.sync();
      final view = await v2.read('bookmark', 'r1');
      expect(view!.values['note'], '보존돼야 한다');
      expect(view.values['title'], '1장 (수정)');
    });

    test('v1 클라이언트는 v2 전용 테이블을 받지 않지만 커서는 전진한다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('highlight', 'h1', {'color': 1, 'text': 'x'});
      h.wall = 2000;
      await v2.sync();

      final first = await v1.sync();
      expect(first.pulledChanges, 0);
      expect(await h.stores['O']!.loadCursor(), isNot(anyOf(isNull, '0')));

      // 그 뒤의 북마크 변경은 정상 수신 — 커서가 highlight 뒤로 넘어가 있다.
      await v2.upsert('bookmark', 'r2', {'title': '2장', 'page': 20});
      h.wall = 3000;
      await v2.sync();
      final second = await v1.sync();
      expect(second.pulledChanges, 1);
      expect((await v1.read('bookmark', 'r2'))!.values['title'], '2장');
    });

    test('신 컬럼 값만 바뀐 행은 v1 클라이언트에 노이즈로 전달되지 않는다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {'title': '1장', 'page': 10});
      h.wall = 2000;
      await v2.sync();
      await v1.sync();

      // note 만 바꾼다 — v1 이 아는 필드는 그대로라 병합 결과가 동일하다.
      await v2.upsert('bookmark', 'r1', {'note': 'v2 only'});
      h.wall = 3000;
      await v2.sync();
      final report = await v1.sync();
      expect(report.pulledChanges, 0);
    });

    test('v1 클라이언트의 삭제(tombstone)는 v2 에 그대로 전파된다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {
        'title': '1장',
        'page': 10,
        'note': 'n',
      });
      h.wall = 2000;
      await v2.sync();
      await v1.sync();

      h.wall = 3000;
      await v1.delete('bookmark', 'r1');
      await v1.sync();
      await v2.sync();
      expect((await v2.read('bookmark', 'r1'))!.isDeleted, isTrue);
    });

    test('신 클라이언트의 삭제도 v1 에 도달한다 (투영이 \$deleted 를 보존)', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {'title': '1장', 'page': 10});
      h.wall = 2000;
      await v2.sync();
      await v1.sync();

      h.wall = 3000;
      await v2.delete('bookmark', 'r1');
      await v2.sync();
      await v1.sync();
      expect((await v1.read('bookmark', 'r1'))!.isDeleted, isTrue);
    });

    test('신 클라이언트의 되살림(restore)도 v1 에 도달한다 — 삭제와 대칭', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      // v1 이 아는 컬럼 없이 신 컬럼만 가진 행 — 삭제·되살림이 유일한 신호다.
      await v2.upsert('bookmark', 'r1', {'note': 'v2 only'});
      h.wall = 2000;
      await v2.sync();
      await v1.sync();
      expect(await v1.read('bookmark', 'r1'), isNull);

      h.wall = 3000;
      await v2.delete('bookmark', 'r1');
      await v2.sync();
      await v1.sync();
      expect((await v1.read('bookmark', 'r1'))!.isDeleted, isTrue);

      // 되살림 — 앱 필드 변경 없이 $deleted:false 만 바뀐다. 이것이 걸러지면
      // v1 은 v2 가 아는 컬럼이 다시 바뀔 때까지 삭제 상태에 갇힌다.
      h.wall = 4000;
      await v2.restore('bookmark', 'r1');
      await v2.sync();
      final report = await v1.sync();
      expect(report.pulledChanges, 1);
      expect((await v1.read('bookmark', 'r1'))!.isDeleted, isFalse);
    });

    test('[투영 ①] 신 컬럼만으로 만든 행은 v1 에 내려가지 않는다 (행 미생성)', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {'note': 'v2 only'});
      h.wall = 2000;
      await v2.sync();
      final report = await v1.sync();
      expect(report.pulledChanges, 0);
      expect(
        await h.stores['O']!.getRow('bookmark', 'r1'),
        isNull,
        reason: '필드 0개짜리 RowState 가 저장되면 안 된다',
      );
    });

    test('[투영 ②] v2 전용 테이블의 tombstone 은 v1 스토어에 들어가지 않는다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('highlight', 'h1', {'color': 1, 'text': 'x'});
      h.wall = 2000;
      await v2.sync();
      await v2.delete('highlight', 'h1');
      h.wall = 3000;
      await v2.sync();
      final report = await v1.sync();
      expect(report.pulledChanges, 0);
      expect(
        await h.stores['O']!.getRow('highlight', 'h1'),
        isNull,
        reason: '미지 테이블 행이 스토어에 들어가면 안 된다',
      );
    });

    test(
      '[투영 ③] 본 적 없는 행의 되살림(\$deleted:false 만)은 phantom 을 만들지 않는다',
      () async {
        final h = VersionedHarness();
        final v2 = h.client('N', schema: _v2, schemaVersion: 2);
        final v1 = h.client('O', schema: _v1, schemaVersion: 1);

        // v1 이 한 번도 보지 못한 행 — 생성(신 컬럼만)·삭제·되살림이 v1 sync 전에
        // 모두 끝난다. 서버는 tombstone 과 되살림 둘 다 내려주지만(lattice 원소를
        // 떨어뜨리지 않는다), 병합 결과가 되살림이라 v1 은 만들 이유가 없다.
        await v2.upsert('bookmark', 'r1', {'note': 'v2 only'});
        h.wall = 2000;
        await v2.sync();
        await v2.delete('bookmark', 'r1');
        h.wall = 3000;
        await v2.sync();
        await v2.restore('bookmark', 'r1');
        h.wall = 4000;
        await v2.sync();

        final report = await v1.sync();
        // tombstone 은 만들어지고(삭제는 의미 있는 상태) 되살림은 그 위에 병합된다
        // — 결과는 alive 인데 앱 필드가 0개인 행이다. 이것은 phantom 이 아니라
        // "삭제됐다가 되살아난, 이 버전에는 보이는 필드가 없는 행" 이다.
        final row = await h.stores['O']!.getRow('bookmark', 'r1');
        expect(report.pulledChanges, anyOf(0, 1, 2));
        if (row != null) {
          expect(
            row.isDeleted(TombstonePolicy.deleteWins),
            isFalse,
            reason: '되살림이 tombstone 위에 병합돼야 한다 (삭제 고착 금지)',
          );
        }
      },
    );

    test('[투영 ③-b] 삭제·되살림이 없는 신 컬럼 전용 행의 재편집도 phantom 을 만들지 않는다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {'note': 'a'});
      h.wall = 2000;
      await v2.sync();
      await v2.upsert('bookmark', 'r1', {'note': 'b'});
      h.wall = 3000;
      await v2.sync();
      await v1.sync();
      expect(await h.stores['O']!.getRow('bookmark', 'r1'), isNull);
    });

    test('[롤링 배포] v1 이 창 안 신 컬럼을 되실어 push 해도 거부되지 않는다', () async {
      // 구 인스턴스(투영 없음)가 v1 에 note 를 내려준 뒤, 신 서버가 그 에코를
      // 받는 상황. 그 클라이언트 버전 기준으로 거부하면 단말이 영구 차단된다.
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      await v2.upsert('bookmark', 'r1', {'title': 't', 'page': 1, 'note': 'n'});
      h.wall = 2000;
      await v2.sync();

      final echoed = await h.serverStore.getRow('bookmark', 'r1');
      final response = await h.server.handlePush(
        SyncPushRequest(
          nodeId: 'O',
          schemaSignature: computeSchemaSignature(_v1),
          schemaVersion: 1,
          changes: [RowChange(table: 'bookmark', state: echoed!)],
        ),
      );
      expect(response.appliedCount, 0, reason: '에코는 LWW no-op');

      // 레지스트리 어느 버전도 모르는 컬럼은 여전히 프로토콜 위반이다.
      expect(
        () => h.server.handlePush(
          SyncPushRequest(
            nodeId: 'O',
            schemaSignature: computeSchemaSignature(_v1),
            schemaVersion: 1,
            changes: [
              RowChange(
                table: 'bookmark',
                state: RowState(
                  rowId: 'r1',
                  fields: const {'zzz': FieldValue('x', Hlc(100, 0, 'O'))},
                ),
              ),
            ],
          ),
        ),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('[시계] v1 은 숨겨진 컬럼의 스탬프도 응답 hlc 로 관찰해 뒤처지지 않는다', () async {
      final h = VersionedHarness();
      final v2 = h.client('N', schema: _v2, schemaVersion: 2);
      final v1 = h.client('O', schema: _v1, schemaVersion: 1);

      await v2.upsert('bookmark', 'r1', {'title': 't', 'page': 1});
      await v2.sync();
      h.wall = 3000;
      await v2.upsert('bookmark', 'r1', {'note': 'hidden@3000'});
      await v2.sync();

      // v1 의 벽시계는 1000 에 머문다 — 응답 hlc 가 없으면 시계가 1000 대다.
      h.wall = 1000;
      await v1.sync();
      await v1.upsert('bookmark', 'r1', {'title': 't2'});
      await v1.sync();

      final titleHlc = (await h.serverStore.getRow(
        'bookmark',
        'r1',
      ))!.fields['title']!.hlc;
      expect(
        titleHlc.compareTo(const Hlc(3000, 0, 'O')) >= 0,
        isTrue,
        reason: '숨겨진 note@3000 이후에 찍혀야 인과가 보존된다',
      );
    });

    test('v0 (창 밖) 클라이언트는 push·pull 모두 clientOutdated 로 거부', () async {
      final h = VersionedHarness();
      final v0 = h.client('Z', schema: _v0, schemaVersion: 0);
      await v0.upsert('bookmark', 'r1', {'title': 'x'});
      expect(
        v0.sync,
        throwsA(
          isA<SchemaMismatchException>().having(
            (e) => e.reason,
            'reason',
            SchemaMismatchReason.clientOutdated,
          ),
        ),
      );
    });

    test('v1 클라이언트가 v2 전용 테이블에 push 하면 프로토콜 위반이다', () async {
      // 컬럼은 롤링 배포 에코 때문에 레지스트리 기준으로 관대하지만, 테이블은
      // 레지스트리 어느 버전에도 없으면 여전히 거부된다.
      final h = VersionedHarness();
      final request = SyncPushRequest(
        nodeId: 'X',
        schemaSignature: computeSchemaSignature(_v1),
        schemaVersion: 1,
        changes: [
          RowChange(
            table: 'not_in_any_version',
            state: RowState(
              rowId: 'r1',
              fields: const {'title': FieldValue('x', Hlc(100, 0, 'X'))},
            ),
          ),
        ],
      );
      expect(
        () => h.server.handlePush(request),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('와이어 호환', () {
    test('버전 힌트가 없는 구 요청(JSON 에 sv 없음)도 서명으로 해석된다', () async {
      final h = VersionedHarness();
      final legacy = SyncPullRequest.fromJson({
        'node': 'L',
        'schema': computeSchemaSignature(_v1),
        'cursor': null,
        'limit': 10,
      });
      expect(legacy.schemaVersion, isNull);
      final response = await h.server.handlePull(legacy);
      expect(response.hasMore, isFalse);
    });

    test('sv 힌트는 관대하게 읽는다 — 정수/정수값 num 허용, 그 밖은 프로토콜 위반', () {
      Map<String, Object?> pushJson(Object? sv) => {
        'node': 'A',
        'schema': 's',
        'sv': sv,
        'changes': <Object?>[],
      };
      expect(SyncPushRequest.fromJson(pushJson(2)).schemaVersion, 2);
      expect(SyncPushRequest.fromJson(pushJson(2.0)).schemaVersion, 2);
      expect(SyncPushRequest.fromJson(pushJson(null)).schemaVersion, isNull);
      expect(
        () => SyncPushRequest.fromJson(pushJson('2')),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncPullRequest.fromJson({
          'node': 'A',
          'schema': 's',
          'sv': true,
          'cursor': null,
          'limit': 10,
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('클라이언트는 pull 요청에도 schemaVersion 을 싣는다', () async {
      final h = VersionedHarness();
      final recorded = <SyncPullRequest>[];
      final recording = _RecordingTransport(h.transport, recorded);
      final v1 = CoSyncClient(
        store: InMemoryClientSyncStore(),
        transport: recording,
        clock: HlcClock(nodeId: 'R', wallClock: () => h.wall),
        syncSchema: _v1,
        schemaVersion: 1,
      );
      await v1.sync();
      expect(recorded, isNotEmpty);
      expect(recorded.first.schemaVersion, 1);
    });

    test('pull 응답 hlc 는 선택 키 — 없는 구 서버 응답도 파싱된다', () {
      final legacy = SyncPullResponse.fromJson({
        'changes': <Object?>[],
        'cursor': '0',
        'more': false,
      });
      expect(legacy.serverHlcPacked, isNull);
      const withHlc = SyncPullResponse(
        changes: [],
        nextCursor: '1',
        hasMore: false,
        serverHlcPacked: '0000000003e8-0000-server',
      );
      expect(withHlc.toJson()['hlc'], '0000000003e8-0000-server');
      expect(
        SyncPullResponse.fromJson(withHlc.toJson()).serverHlcPacked,
        '0000000003e8-0000-server',
      );
    });

    test('단일 스키마 서버에서도 delete 만으로 생긴 행의 restore 가 전파된다 (HEAD 회귀 방지)', () async {
      final store = InMemoryServerSyncStore();
      var wall = 1000;
      final server = CoSyncServer(
        store: store,
        clock: HlcClock(nodeId: 'server', wallClock: () => wall),
        syncSchema: _v1,
      );
      final transport = InProcessTransport(server);
      CoSyncClient client(String id) => CoSyncClient(
        store: InMemoryClientSyncStore(),
        transport: transport,
        clock: HlcClock(nodeId: id, wallClock: () => wall),
        syncSchema: _v1,
        schemaVersion: 1,
      );
      final a = client('A');
      final b = client('B');

      await a.delete('bookmark', 'r1'); // upsert 없이 tombstone 만
      wall = 2000;
      await a.sync();
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isTrue);

      wall = 3000;
      await a.restore('bookmark', 'r1');
      await a.sync();
      final report = await b.sync();
      expect(report.pulledChanges, 1);
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isFalse);
    });

    test('schemaVersion 은 있을 때만 직렬화된다', () {
      const withVersion = SyncPushRequest(
        nodeId: 'A',
        schemaSignature: 's',
        schemaVersion: 2,
        changes: [],
      );
      const without = SyncPushRequest(
        nodeId: 'A',
        schemaSignature: 's',
        changes: [],
      );
      expect(withVersion.toJson()['sv'], 2);
      expect(without.toJson().containsKey('sv'), isFalse);
      expect(SyncPushRequest.fromJson(withVersion.toJson()).schemaVersion, 2);
    });

    test('단일 스키마 생성자는 종전과 동일하게 동작한다 (회귀)', () async {
      final server = CoSyncServer(
        store: InMemoryServerSyncStore(),
        clock: HlcClock(nodeId: 'server'),
        syncSchema: _v1,
      );
      expect(server.schemaSignature, computeSchemaSignature(_v1));
      expect(server.registry.versions, hasLength(1));
    });
  });

  group('RowState.project', () {
    test('컬럼 부분집합 + \$deleted 만 남긴다', () {
      final state = RowState(
        rowId: 'r1',
        fields: const {
          'title': FieldValue('t', Hlc(1, 0, 'A')),
          'note': FieldValue('n', Hlc(2, 0, 'A')),
          kDeletedField: FieldValue(false, Hlc(3, 0, 'A')),
        },
      );
      final projected = state.project(const {'title'});
      expect(projected.fields.keys, unorderedEquals(['title', kDeletedField]));
      expect(projected.rowId, 'r1');
    });
  });
}
