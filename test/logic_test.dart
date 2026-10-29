// 逻辑测试：轮次树和版本、配置解析、发送和实时返回、排队、@ 推荐、操作确认
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/models.dart';
import 'package:netbar_ops/src/panels/skills_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';

const cfg = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-TEST', token: 'test-token-123', name: '富贵测试组-远程部-WIN-20260917-192.168.11.110');

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧链接 name 拆成分组、网吧、机位、IP；网吧标识用分组/网吧名称', () {
    expect(cfg.netbar, {'netbarGroup': '富贵测试组', 'netbarName': '远程部', 'netbarSeat': 'WIN-20260917', 'netbarIp': '192.168.11.110'});
    expect(cfg.machineName, '富贵测试组-远程部-WIN-20260917-192.168.11.110');
    expect(cfg.barKey, '富贵测试组/远程部');
    const noName = NetbarOpsConfig(baseUrl: 'x', mcpUrl: 'https://a/mcp/PC-01', token: 't');
    expect(noName.netbar['netbarSeat'], 'PC-01');
    expect(noName.barKey, '');
  });

  test('轮次树：旧记录编成 L1、L2；分支按 selected 选，没选看最新的', () {
    final events = [
      ChatEvent('user', {'text': '第一问'}),
      ChatEvent('text', {'text': '答1'}),
      ChatEvent('done', {}),
      ChatEvent('user', {'text': '第二问'}),
      ChatEvent('text', {'text': '答2'}),
      ChatEvent('user', {'text': '第二问改', 'turn': 'a', 'parent': 'L1'}, 'a'),
      ChatEvent('text', {'text': '答2改'}, 'a'),
      ChatEvent('feedback', {'value': 'down', 'reason': '不对'}, 'a'),
    ];
    final tree = TurnTree.build(events);
    expect(tree.turns.keys, ['L1', 'L2', 'a']);
    expect(tree.path({}).map((t) => t.id), ['L1', 'a']);
    expect(tree.path({'L1': 'L2'}).map((t) => t.id), ['L1', 'L2']);
    expect(tree.siblings(tree.turns['a']!), ['L2', 'a']);
    expect(tree.turns['a']!.feedback?['reason'], '不对');
    expect(tree.turns['L1']!.done, isTrue);
    expect(tree.turns['a']!.replyText, '答2改');
  });

  test('问题选项代码块', () {
    final r = splitOptions('桌面有弹窗\n```options\n[{"title":"程序崩溃","detail":"有报错框"}]\n```');
    expect(r.text, '桌面有弹窗');
    expect(r.options!.single.title, '程序崩溃');
  });

  test('技能文件解析', () {
    final p = parseSkillFile('---\nname: 开机慢检查\ndescription: "开机慢时"\n---\n# 步骤\n1. 看启动项', 'SKILL.md');
    expect([p.name, p.description, p.content], ['开机慢检查', '开机慢时', '# 步骤\n1. 看启动项']);
  });

  test('发送：实时返回逐条显示，记住对话，标题、连接状态更新', () async {
    final be = FakeBackend();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    await ctl.start();
    expect(ctl.showStartChoices, isTrue);
    ctl.input.text = '游戏打不开';
    ctl.sendComposer();
    expect(ctl.input.text, '');
    await settle();
    expect(ctl.busy, isFalse);
    expect(ctl.sessionId, 'session-1');
    expect(ctl.title, '游戏打不开');
    expect(ctl.mcpStatus, 'connected');
    expect(ctl.path.single.text, '游戏打不开');
    expect(ctl.path.single.done, isTrue);
    expect(be.chatBodies.single['barId'], '富贵测试组/远程部');
    expect((await SharedPreferences.getInstance()).getString('netbar_ops.session.${cfg.mcpUrl}'), 'session-1');
    // 接着问：接在上一轮后面
    ctl.input.text = '还是不行';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last['parentTurn'], 't1');
    expect(ctl.path.map((t) => t.text), ['游戏打不开', '还是不行']);
  });

  test('连接：toolbox 照旧参数先 /api/start，之后带连接编号；连接过期自动重连再发', () async {
    const tb = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/T03-abcd', token: 'mcp-token-1', isClient: true,
        toolboxToken: 'admin-token-1', merchantId: '5001', sfuRoom: 'T03-abcd', sfuAddr: 'https://rtc2.03kan.com');
    expect(tb.isNewEnv, isFalse);
    expect(tb.autoRun, isTrue);
    expect(tb.hasMulti, isTrue);
    final be = FakeBackend();
    final ctl = ChatController(tb, api: NetbarApi(tb, newClient: be.client));
    await ctl.start();
    expect(be.startBodies.single, {
      'env': 'toolbox', 'mcp': 'https://rtc2.03kan.com/mcp/T03-abcd', 'token': 'mcp-token-1', 'isclient': '1',
      'toolboxToken': 'admin-token-1', 'merchant_id': '5001', 'sfuroom': 'T03-abcd', 'sfuaddr': 'https://rtc2.03kan.com',
    });
    expect(ctl.api.connBody, {'mcpUrl': 'https://rtc2.03kan.com/mcp/T03-abcd', 'token': 'conn-1'});
    ctl.input.text = '看看';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.single['token'], 'conn-1');
    expect(be.chatBodies.single.containsKey('isClient'), isFalse);
    // 后台重启过：发消息时先收到“连接已过期”，自动重新连上再发，用户看不到错误
    be.expireNext = true;
    ctl.input.text = '再看看';
    ctl.sendComposer();
    await settle();
    expect(be.startBodies.length, 2);
    expect(be.chatBodies.last['token'], 'conn-2');
    expect(ctl.path.map((t) => t.text), ['看看', '再看看']);
    // 普通接口也一样
    be.expireNext = true;
    await ctl.api.post('/api/sessions');
    expect(be.startBodies.length, 3);
  });

  test('连接：cloud/yx 用新参数；没有网吧编号和名称时按解密出的网吧号区分网吧记忆', () async {
    const cl = NetbarOpsConfig(baseUrl: 'http://fake', env: 'cloud', token: 'yx-token-1', root: 'gO0k3hkCVQM', branch: 'x002', role: 'client');
    expect(cl.isValid, isTrue);
    expect(cl.autoRun, isTrue);
    expect(cl.netbar['netbarSeat'], 'x002');
    expect(const NetbarOpsConfig(baseUrl: 'x', env: 'yx', token: 't', root: 'r').netbar['netbarSeat'], '服务端');
    expect(const NetbarOpsConfig(baseUrl: 'x', env: 'cloud', token: 't').isValid, isFalse);
    final be = FakeBackend();
    final ctl = ChatController(cl, api: NetbarApi(cl, newClient: be.client));
    await ctl.start();
    expect(be.startBodies.single, {'env': 'cloud', 'token': 'yx-token-1', 'root': 'gO0k3hkCVQM', 'branch': 'x002', 'role': 'client'});
    expect(ctl.barKey, 'cloud-2');
    ctl.input.text = '看看';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.single['mcpUrl'], 'netbar://cloud/2/x002');
    expect(be.chatBodies.single['barId'], 'cloud-2');
    expect((await SharedPreferences.getInstance()).getString('netbar_ops.session.cloud/gO0k3hkCVQM/x002'), 'session-1');
  });

  test('AI 处理中发送的消息排队，结束后自动处理；立即处理会停掉当前这一轮', () async {
    final be = FakeBackend()..askApproval = true;
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    await ctl.start();
    ctl.input.text = '结束记事本';
    ctl.sendComposer();
    await settle();
    expect(ctl.busy, isTrue);
    expect(ctl.path.single.events.any((e) => e.e == 'approval'), isTrue);
    be.askApproval = false;
    ctl.input.text = '排队的一条';
    ctl.sendComposer();
    expect(ctl.queue.length, 1);
    await ctl.approve('tool1', allow: true);
    await settle();
    await settle();
    expect(ctl.queue, isEmpty);
    expect(ctl.path.map((t) => t.text), ['结束记事本', '排队的一条']);
    // 被替换的内容里执行过写操作
    expect(ctl.executedWrites(ctl.path.first), ['kill_process']);
    // 停止后排队暂停
    be.askApproval = true;
    ctl.input.text = '又一个操作';
    ctl.sendComposer();
    await settle();
    ctl.input.text = '暂停中的一条';
    ctl.sendComposer();
    ctl.stopByUser();
    expect(ctl.queuePaused, isTrue);
    expect(be.calls, contains('/api/stop'));
  });

  test('@ 推荐：候选分组排序，选中后变成标签，技能只能一个', () async {
    final be = FakeBackend();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    ctl.input.text = '看看 @桌';
    ctl.input.selection = TextSelection.collapsed(offset: ctl.input.text.length);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(ctl.mentionOpen, isTrue);
    expect(ctl.mentionItems.map((x) => x.type), ['experience', 'background', 'skill']);
    ctl.pickMention(0);
    expect(ctl.input.text, '看看 ');
    expect(ctl.refs.single.title, '桌面图标被隐藏的排查方法');
    ctl.input.text = '@开';
    ctl.input.selection = const TextSelection.collapsed(offset: 2);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    ctl.pickMention(ctl.mentionItems.indexWhere((x) => x.isSkill));
    expect(ctl.skill?.title, '客户机开机慢标准检查');
    final c = ctl.composerContent();
    expect(c.opts!.text, '使用技能：客户机开机慢标准检查');
    expect(c.opts!.skillId, 's1');
  });

  test('重新生成：接在原来那一轮的上一轮后面', () async {
    final be = FakeBackend();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    await ctl.start();
    ctl.input.text = '第一问';
    ctl.sendComposer();
    await settle();
    ctl.input.text = '第二问';
    ctl.sendComposer();
    await settle();
    await ctl.regenerate(ctl.path.last);
    await settle();
    expect(be.chatBodies.last['parentTurn'], 't1');
    expect(be.chatBodies.last['message'], '第二问');
    expect(ctl.tree.siblings(ctl.path.last).length, 2);
    ctl.stepBranch(ctl.path.last, -1);
    expect(ctl.path.last.id, 't2');
  });

  test('切换 AI：列表从后台取，选择记住，发送时带上；生成中的文字结束后清掉；同一段回复只显示一次', () async {
    final be = FakeBackend();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    await ctl.start();
    await settle();
    expect(ctl.harnesses.map((h) => h.id), ['claude', 'codex', 'dsh']);
    expect(ctl.harnessId, 'claude');
    await ctl.setHarness('codex');
    expect((await SharedPreferences.getInstance()).getString('netbar_ops.harness'), 'codex');
    ctl.input.text = '没有声音';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last['harness'], 'codex');
    expect(ctl.streamingText, isNull);
    expect(ctl.path.single.events.where((e) => e.e == 'text').length, 1);
    expect(ctl.path.single.events.where((e) => e.e == 'done').single.d['harness'], 'codex');
  });

  test('网络中途断开：这一轮标记结束并显示原因，不会一直转圈', () async {
    final be = FakeBackend();
    final client = MockClient.streaming((req, body) async {
      if (req.url.path != '/api/chat') return be.client().send(req);
      final c = StreamController<List<int>>();
      c.add(utf8.encode('event: start\ndata: {"taskId":"x","turn":"t1"}\n\n'));
      c.add(utf8.encode('event: user\ndata: {"text":"hi","kind":"chat","turn":"t1"}\n\n'));
      Future<void>.delayed(const Duration(milliseconds: 20), () {
        c.addError(const SocketException('reset'));
        c.close();
      });
      return http.StreamedResponse(c.stream, 200);
    });
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: () => client));
    await ctl.start();
    ctl.input.text = 'hi';
    ctl.sendComposer();
    await settle();
    expect(ctl.busy, isFalse);
    final t = ctl.path.single;
    expect(t.done, isTrue);
    expect(str(t.events.last.d['error']), contains('连接断开'));
    ctl.dispose();
  });
}
