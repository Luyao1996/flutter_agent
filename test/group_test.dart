// 多人会话（群聊）的逻辑：实时连接、群聊模式下打字交给 AI 还是只发给人、@ 人、群聊消息和自动任务、别人叫 AI 时一起看
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/group.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';

const cfg = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-TEST', token: 'test-token-123', name: '富贵测试组-远程部-WIN-20260917-192.168.11.110');

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

/// 开好一个对话（session-1），实时连接已连上
Future<(FakeBackend, ChatController, List<String>)> opened() async {
  final be = FakeBackend();
  final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
  final toasts = <String>[];
  ctl.onToast = toasts.add;
  await ctl.start();
  ctl.input.text = '游戏打不开';
  ctl.sendComposer();
  await settle();
  return (be, ctl, toasts);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('唤醒词：墩墩龙、龙龙、龙妹任意位置，“助手”只在开头，@AI', () {
    expect(callsAi('龙龙帮我看下'), isTrue);
    expect(callsAi('看下 12 号机，墩墩龙'), isTrue);
    expect(callsAi('龙妹'), isTrue);
    expect(callsAi('助手，看下'), isTrue);
    expect(callsAi('@助手 看下'), isTrue);
    expect(callsAi('这个助手不好用'), isFalse);
    expect(callsAi('@AI 看下'), isTrue);
    expect(callsAi('@AIR 看下'), isFalse);
    expect(callsAi('老王你看下'), isFalse);
  });

  test('房间状态：默认名字“房主”，有别人在线才是群聊模式', () {
    final info = RoomInfo.fromJson({
      'ownerName': '',
      'members': [
        {'id': 'owner', 'name': '房主', 'owner': true, 'online': true},
        {'id': 'm1', 'name': '老王', 'online': false},
      ],
    });
    expect(info.ownerName, '房主');
    expect(info.invite, isNull);
  });

  test('连上实时房间：用这台电脑的连接打招呼；一个人时打字都交给 AI', () async {
    final (be, ctl, _) = await opened();
    final hello = be.roomSockets.single.sent.single;
    expect(hello, {'type': 'hello', 'sessionId': 'session-1', 'mcpUrl': cfg.mcpUrl, 'token': 'conn-1', 'barId': '富贵测试组/远程部'});
    expect(be.chatBodies.single['clientId'], ctl.group.clientId);
    expect(ctl.group.info?.ownerName, '房主');
    expect(ctl.group.active, isFalse);
    expect(ctl.group.showBadge, isFalse);
    expect(ctl.inputHint, startsWith('描述遇到的问题'));
    // 只有自己：@ 谁都交给 AI
    ctl.input.text = '@老王 看下';
    ctl.sendComposer();
    await settle();
    expect(be.roomSays, isEmpty);
    expect(be.chatBodies.length, 2);
    ctl.dispose();
  });

  test('有别人在线（v1.67.1）：默认交给 AI；只 @ 人或 @所有人 时只发给大家；@ 人又 @龙龙 的仍交给 AI', () async {
    final (be, ctl, _) = await opened();
    be.guests.add({'id': 'm1', 'name': '老王', 'online': true});
    be.pushPresence();
    await settle();
    expect(ctl.group.active, isTrue);
    expect(ctl.group.showBadge, isTrue);
    expect(ctl.group.onlineCount, 2);
    expect(ctl.inputHint, groupPlaceholder);

    ctl.input.text = '12号机卡了';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.length, 2);

    ctl.input.text = '@老王 你去看下';
    ctl.sendComposer();
    expect(ctl.input.text, '');
    await settle();
    expect(be.chatBodies.length, 2);
    expect(be.roomSays.last['text'], '@老王 你去看下');
    expect(be.roomSays.last['mentions'], ['m1']);
    // 推回来的群聊消息记进对话记录（属于当前最后一轮）
    final chat = ctl.path.last.events.where((e) => e.e == 'chat').single;
    expect(chat.d['text'], '@老王 你去看下');

    ctl.input.text = '@所有人 注意';
    ctl.sendComposer();
    await settle();
    expect(be.roomSays.last['mentions'], ['all']);

    ctl.input.text = '@老王 龙龙 也看下';
    ctl.sendComposer();
    await settle();
    expect(be.roomSays.length, 2);
    expect(be.chatBodies.length, 3);
    expect(be.chatBodies.last['message'], '@老王 龙龙 也看下');
    ctl.dispose();
  });

  test('别人发的消息：@ 我时提醒；自动发起的任务按最新状态显示，取消', () async {
    final (be, ctl, toasts) = await opened();
    be.guests.add({'id': 'm1', 'name': '老王', 'online': true});
    be.pushPresence();
    be.pushRoomEvent('chat', {
      'from': {'id': 'm1', 'name': '老王'},
      'text': '@房主 12号机蓝屏了',
      'mentions': ['owner'],
    });
    be.pushRoomEvent('chat', {
      'from': {'id': 'm1', 'name': '老王'},
      'text': '没人 @ 的话',
    });
    be.pushRoomEvent('auto_task', {'id': 'a1', 'task': '看一下 12 号机为什么蓝屏', 'from': '老王', 'reason': '老王说12号机蓝屏'});
    await settle();
    expect(toasts.where((t) => t == '老王 @了你').length, 1);
    expect(ctl.events.where((e) => e.e == 'chat').length, 2);
    expect(ctl.group.autoTaskStatus('a1', ctl.events).status, 'pending');
    be.pushRoomEvent('auto_task_status', {'id': 'a1', 'status': 'queued'});
    await settle();
    expect(ctl.group.autoTaskStatus('a1', ctl.events).status, 'queued');
    await ctl.group.cancelAutoTask('a1');
    await settle();
    final st = ctl.group.autoTaskStatus('a1', ctl.events);
    expect([st.status, st.by], ['cancelled', '房主']);
    ctl.dispose();
  });

  test('别人叫 AI 干活：连上去一起看；自己发起的不重复连', () async {
    final (be, ctl, _) = await opened();
    be.pushRoom({'type': 'task', 'taskId': 'x', 'turn': 't9', 'clientId': ctl.group.clientId});
    await settle();
    expect(be.calls.where((c) => c == '/api/chat/attach'), isEmpty);
    be.pushRoom({'type': 'task', 'taskId': 'x', 'turn': 't9', 'clientId': 'other-page'});
    await settle();
    expect(be.calls.where((c) => c == '/api/chat/attach').length, 1);
    ctl.dispose();
  });

  test('群聊里刚好别人在让 AI 干活（409）：这条排到最前面，先一起看完那一轮再发', () async {
    final (be, ctl, _) = await opened();
    be.guests.add({'id': 'm1', 'name': '老王', 'online': true});
    be.pushPresence();
    await settle();
    be.otherRunning = true;
    ctl.input.text = '再看看声卡';
    ctl.sendComposer();
    await settle();
    await settle();
    expect(be.calls.where((c) => c == '/api/chat/attach').length, 1);
    // 一起看完后接着发出去
    expect(ctl.queue, isEmpty);
    expect(be.chatBodies.last['message'], '再看看声卡');
    expect(ctl.notes.where((n) => n.kind == 'error'), isEmpty);
    ctl.dispose();
  });

  test('@ 弹出的候选：群里有别人时最前面是龙龙、所有人、群成员；选人在文字里写上“@名字 ”', () async {
    final (be, ctl, _) = await opened();
    // 只有自己：没有“群成员”
    expect(ctl.group.mentionItems(''), isEmpty);
    be.guests.add({'id': 'm1', 'name': '老王', 'online': false});
    be.pushPresence();
    await settle();
    ctl.input.text = '你看下 @';
    ctl.input.selection = const TextSelection.collapsed(offset: 5);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(ctl.mentionOpen, isTrue);
    expect(ctl.mentionItems.take(3).map((x) => x.title), ['龙龙', '所有人', '老王']);
    expect(ctl.mentionSnippets[2], '不在线');
    expect(ctl.mentionItems.skip(3).every((x) => x.type != 'person'), isTrue);
    ctl.pickMention(2);
    expect(ctl.input.text, '你看下 @老王 ');
    expect(ctl.refs, isEmpty);
    expect(ctl.group.mentionItems('ai').single.item.title, '龙龙');
    expect(ctl.group.mentionItems('王').single.item.title, '老王');
    ctl.dispose();
  });

  test('邀请：生成、重新生成、关闭；改名；移出成员', () async {
    final (be, ctl, _) = await opened();
    final g = ctl.group;
    await g.refresh();
    await g.createInvite('never');
    expect(g.info!.invite!.expiresAt, 0);
    expect(g.inviteUrl(g.info!.invite!.code), 'http://fake/join/abcdef0123456789abcdef01');
    expect(g.showBadge, isTrue);
    expect(await g.rename('小李'), '小李');
    be.guests.add({'id': 'm1', 'name': '老王', 'online': true});
    await g.kick('m1');
    expect(g.info!.members.length, 1);
    await g.closeInvite();
    expect(g.info!.invite, isNull);
    ctl.dispose();
  });

  test('换对话、开新对话：实时连接跟着换', () async {
    final (be, ctl, _) = await opened();
    expect(be.roomSockets.single.closed, isFalse);
    ctl.newChat();
    expect(be.roomSockets.single.closed, isTrue);
    expect(ctl.group.sid, isNull);
    await ctl.openSession('session-1');
    await settle();
    expect(be.roomSockets.length, 2);
    expect(be.roomSockets.last.sent.single['sessionId'], 'session-1');
    ctl.dispose();
    expect(be.roomSockets.last.closed, isTrue);
  });

  test('连接编号过期：重新连上电脑再进房间', () async {
    final (be, ctl, _) = await opened();
    final s = be.roomSockets.single;
    s.push({'type': 'error', 'error': '连接已过期，请刷新页面重新连接。', 'expired': true});
    await settle();
    s.close();
    await settle();
    expect(be.startBodies.length, 2);
    expect(be.roomSockets.length, 2);
    expect(be.roomSockets.last.sent.single['token'], 'conn-2');
    ctl.dispose();
  });
}
