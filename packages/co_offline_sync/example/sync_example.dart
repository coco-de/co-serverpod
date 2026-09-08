import 'package:co_offline_sync/co_offline_sync.dart';

Future<void> main() async {
  const schema = {
    'note': ['title', 'body'],
  };
  final server = CoSyncServer(
    store: InMemoryServerSyncStore(),
    clock: HlcClock(nodeId: 'server-demo'),
    syncSchema: schema,
  );
  CoSyncClient device(String nodeId) => CoSyncClient(
    store: InMemoryClientSyncStore(),
    transport: InProcessTransport(server),
    clock: HlcClock(nodeId: nodeId),
    syncSchema: schema,
    schemaVersion: 1,
  );
  final phone = device('phone-demo');
  final tablet = device('tablet-demo');

  // 네트워크 왕복 없이 로컬 반영. 실제 앱은 충돌 없는 UUID 등의 rowId를 사용.
  await phone.upsert('note', 'note-1', {'title': '제목', 'body': '초안'});
  await phone.sync();
  await tablet.sync();

  // 서로 다른 필드를 오프라인에서 수정하면 둘 다 보존된다.
  await phone.upsert('note', 'note-1', {'title': '수정한 제목'});
  await tablet.upsert('note', 'note-1', {'body': '태블릿에서 작성'});
  await phone.sync();
  await tablet.sync();
  await phone.sync();
  final note = await phone.read('note', 'note-1');
  assert(note!.values['title'] == '수정한 제목');
  assert(note!.values['body'] == '태블릿에서 작성');

  await phone.delete('note', 'note-1');
  await phone.sync();
  await tablet.sync();
  assert((await tablet.read('note', 'note-1'))!.isDeleted);

  await phone.restore('note', 'note-1');
  await phone.sync();
  await tablet.sync();
  assert(!(await tablet.read('note', 'note-1'))!.isDeleted);
}
