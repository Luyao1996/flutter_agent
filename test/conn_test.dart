// 连接方式、身份、电脑离线、管理员看别人的对话：口令远程（pass）、toolbox 新格式（不带 mcp）、顶栏身份标签、离线后重新连接
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

const pass = NetbarOpsConfig(baseUrl: 'http://fake', env: 'pass', mcpUrl: 'https://rtc2.03kan.com/mcp/agent-T03-abcd12', mcpToken: 'pass-token-123', isDebug: true);
const tbNew = NetbarOpsConfig(baseUrl: 'http://fake', env: 'toolbox', token: 'login-token-1', root: 'gO0k3hkCVQM', branch: 'T03', role: 'client');

ChatController ctlOf(NetbarOpsConfig c, FakeBackend be) => ChatController(c, api: NetbarApi(c, newClient: be.client));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('口令远程（pass）：只要 mcp 和通行证；不能多机；调试模式不生效但能删除对话', () async {
    expect(pass.isValid, isTrue);
    expect(pass.isPass, isTrue);
    expect(pass.hasMulti, isFalse);
    expect(pass.canLaunch, isFalse);
    expect(pass.storeKey, 'pass/https://rtc2.03kan.com/mcp/agent-T03-abcd12');
    expect(pass.netbar['netbarSeat'], 'agent-T03-abcd12');
    expect(const NetbarOpsConfig(baseUrl: 'x', env: 'pass', mcpUrl: 'https://a/mcp/x').isValid, isFalse);
    expect(const NetbarOpsConfig(baseUrl: 'x', env: 'pass', mcpUrl: 'https://a/mcp/x', mcpToken: 't', branch: '038').netbar['netbarSeat'], '038');
    final be = FakeBackend()
      ..startExtra = {
        'who': '*',
        'borrowedBar': {'id': '富贵测试组/远程部', 'group': '富贵测试组', 'name': '远程部'}
      };
    final ctl = ctlOf(pass, be);
    expect(ctl.config.isDebug, isFalse);
    expect(ctl.canDeleteSessions, isTrue);
    final seen = <String>{};
    ctl.addListener(() => seen.addAll(ctl.notes.map((n) => n.text)));
    await ctl.start();
    expect(be.startBodies.single, {'env': 'pass', 'mcp': 'https://rtc2.03kan.com/mcp/agent-T03-abcd12', 'mcpToken': 'pass-token-123', 'branch': ''});
    // 口令远程不会启动 AI 助手，不提“要等几十秒”
    expect(seen, contains('正在连接这台电脑…'));
    // 身份：管理员
    expect(ctl.who, '*');
    expect(ctl.whoLabel, '管理员');
    expect(ctl.isAdmin, isTrue);
    expect(ctl.api.info.who, '*');
    // 借来的网吧名称：显示出来，“这家网吧”的记忆也用它
    expect(ctl.config.machineName, '富贵测试组-远程部-agent-T03-abcd12');
    expect(ctl.barKey, '富贵测试组/远程部');
    ctl.input.text = '看看';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.single['barId'], '富贵测试组/远程部');
    expect(be.chatBodies.single['netbar']['netbarName'], '远程部');
  });

  test('口令远程借不到网吧名称时，不用后台的 room- 网吧号', () async {
    final be = FakeBackend()..startExtra = {'who': '*'};
    final ctl = ctlOf(pass, be);
    await ctl.start();
    expect(ctl.barKey, '');
  });

  test('打开失败：提示里已经说了“重新打开”就不再重复', () async {
    final be = FakeBackend();
    final ctl = ChatController(pass, api: NetbarApi(pass, newClient: () => _failing('远程已断开，请从远程控制端重新打开')));
    await ctl.start();
    expect(ctl.notes.single.text, '远程已断开，请从远程控制端重新打开');
    expect(be.calls, isEmpty);
  });

  test('toolbox 新格式：不带 mcp，只带登录令牌、网吧号、座位号、角色；按网吧号区分网吧记忆', () async {
    expect(tbNew.isValid, isTrue);
    expect(tbNew.isToolboxNew, isTrue);
    expect(tbNew.autoRun, isTrue);
    expect(tbNew.hasMulti, isTrue);
    expect(tbNew.canLaunch, isTrue);
    expect(tbNew.netbar['netbarSeat'], 'T03');
    expect(tbNew.storeKey, 'toolbox/gO0k3hkCVQM/T03');
    expect(tbNew.startBody, {'env': 'toolbox', 'token': 'login-token-1', 'root': 'gO0k3hkCVQM', 'branch': 'T03', 'role': 'client'});
    // 带 mcp 的新格式：mcp、mcpToken 一起交给后台；机位用地址最后一段
    const withMcp = NetbarOpsConfig(baseUrl: 'x', token: 't', root: 'r', mcpUrl: 'https://rtc2.03kan.com/mcp/agent-T03-abcd12', mcpToken: 'm');
    expect(withMcp.startBody, {'env': 'toolbox', 'token': 't', 'root': 'r', 'branch': '', 'mcp': 'https://rtc2.03kan.com/mcp/agent-T03-abcd12', 'mcpToken': 'm'});
    expect(withMcp.autoRun, isFalse);
    expect(withMcp.netbar['netbarSeat'], 'agent-T03-abcd12');
    expect(const NetbarOpsConfig(baseUrl: 'x', env: 'toolbox', root: 'r').isValid, isFalse);
    final be = FakeBackend()..startExtra = {'who': 'toolbox', 'barId': '5001'};
    final ctl = ctlOf(tbNew, be);
    final seen = <String>{};
    ctl.addListener(() => seen.addAll(ctl.notes.map((n) => n.text)));
    await ctl.start();
    expect(seen, contains('正在连接 T03 ，AI 助手没在运行的话要先启动，可能要等几十秒…'));
    expect(ctl.whoLabel, '工具箱');
    expect(ctl.isAdmin, isFalse);
    expect(ctl.barKey, 'toolbox-5001');
    expect(ctl.api.connBody['mcpUrl'], 'netbar://toolbox/2/T03');
  });

  test('电脑离线：能照常对话；不能自动检查；一轮里掉线/上线有提示；重新连接', () async {
    final be = FakeBackend()..startExtra = {'who': 'yx', 'offline': 'AI 助手没在运行'};
    const yx = NetbarOpsConfig(baseUrl: 'http://fake', env: 'yx', token: 'yx-token-1', root: 'gO0k3hkCVQM', branch: '038');
    final ctl = ctlOf(yx, be);
    final toasts = <String>[];
    ctl.onToast = toasts.add;
    await ctl.start();
    expect(ctl.isOffline, isTrue);
    expect(ctl.offline, 'AI 助手没在运行');
    expect(ctl.notes.single.text, startsWith('这台电脑现在连不上：AI 助手没在运行。'));
    expect(ctl.showStartChoices, isTrue);
    ctl.pickStart(true);
    expect(toasts.last, contains('检查不了'));
    expect(be.chatBodies, isEmpty);
    // 照常能对话
    be.mcpStatus = 'offline';
    be.offlineReason = 'AI 助手没在运行';
    ctl.input.text = '这台电脑怎么了';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.length, 1);
    expect(ctl.isOffline, isTrue);
    expect(ctl.mcpStatus, isNot('failed'));
    // 下一轮电脑又连上了
    be.mcpStatus = 'connected';
    ctl.input.text = '再看看';
    ctl.sendComposer();
    await settle();
    expect(ctl.isOffline, isFalse);
    expect(ctl.notes.last.text, '这台电脑已经连上了，AI 可以照常操作它。');
    // 再掉线：提示一次
    be.mcpStatus = 'offline';
    be.offlineReason = '电脑关机了';
    ctl.input.text = '还在吗';
    ctl.sendComposer();
    await settle();
    expect(ctl.offline, '电脑关机了');
    expect(ctl.notes.last.text, contains('这台电脑现在连不上：电脑关机了。'));
    // 重新连接：还是连不上
    be.reconnectOffline = '还是关机';
    await ctl.reconnect();
    expect(be.calls.last, '/api/reconnect');
    expect(toasts.last, '还是连不上：还是关机');
    expect(ctl.offline, '还是关机');
    // 重新连接成功
    be.reconnectOffline = '';
    await ctl.reconnect();
    expect(ctl.isOffline, isFalse);
    expect(ctl.mcpStatus, 'connected');
    expect(ctl.notes.last.text, '这台电脑已经连上了，AI 可以照常操作它。');
    expect(ctl.reconnecting, isFalse);
  });

  test('管理员看别人的对话：列表标出从哪里打开，只能查看，不能接着问', () async {
    final be = FakeBackend()
      ..startExtra = {'who': '*'}
      ..extraSessions = [
        {'id': 'other-1', 'title': '别人的对话', 'updatedAt': '2026-10-21T10:00:00Z', 'rounds': 1, 'others': true, 'from': '银杏'}
      ]
      ..sessionGet = {
        'session': {'id': 'other-1', 'title': '别人的对话', 'createdAt': '2026-10-21T10:00:00Z'},
        'events': [
          {'e': 'user', 'd': {'text': '游戏打不开'}},
          {'e': 'text', 'd': {'text': '好的'}},
          {'e': 'done', 'd': {}},
        ],
        'running': false,
        'readOnly': true,
        'from': '银杏',
      };
    final ctl = ctlOf(pass, be);
    final toasts = <String>[];
    ctl.onToast = toasts.add;
    await ctl.start();
    final list = await ctl.listSessions();
    expect(list.map((s) => s.others), [false, true]);
    expect(list.last.from, '银杏');
    expect(await ctl.openSession('other-1'), isTrue);
    expect(ctl.readOnlySession, isTrue);
    expect(ctl.historyNote, isTrue);
    expect(ctl.historyNoteText, startsWith('以上是银杏用户在这台电脑上的对话 · 只能查看'));
    ctl.input.text = '接着问';
    ctl.sendComposer();
    await settle();
    expect(toasts.last, contains('只能查看'));
    expect(be.chatBodies, isEmpty);
    expect(ctl.input.text, '接着问'); // 没发出去，输入的内容还在
    // 新对话就能问了
    ctl.newChat();
    expect(ctl.readOnlySession, isFalse);
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.length, 1);
  });

  for (final style in NetbarUiStyle.values) {
    testWidgets('${style.name}：顶栏身份标签、电脑离线和重新连接、历史里别人的对话', (t) async {
      // 手机按最窄的 320 宽测：身份标签、“电脑离线 · 重新连接”都挤得下
      t.view.physicalSize = style == NetbarUiStyle.desktop ? const Size(1280, 800) : const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final be = FakeBackend()
        ..startExtra = {'who': '*', 'offline': 'AI 助手没在运行'}
        ..extraSessions = [
          {'id': 'other-1', 'title': '别人的对话', 'updatedAt': '2026-10-21T10:00:00Z', 'rounds': 1, 'others': true, 'from': '云启动'}
        ];
      final config = pass.copyWith(uiStyle: style);
      final ctl = ctlOf(config, be);
      await t.pumpWidget(MaterialApp(home: NetbarOpsView(config: config, controller: ctl)));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('管理员'), findsOneWidget);
      expect(find.text('电脑离线'), findsOneWidget);
      expect(find.textContaining('这台电脑现在连不上'), findsOneWidget);
      await t.tap(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '重新连接'));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('电脑离线'), findsNothing);
      expect(find.text('已连接'), findsOneWidget);
      // 历史对话：别人的对话标出“云启动用户”，管理员能删除
      if (style == NetbarUiStyle.cupertino) {
        await t.tap(find.byIcon(CupertinoIcons.clock));
      } else if (style == NetbarUiStyle.material) {
        Scaffold.of(t.element(find.byType(AppBar))).openDrawer();
      } else {
        await t.tap(find.text('历史'));
      }
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('云启动用户'), findsOneWidget);
      if (style == NetbarUiStyle.desktop) expect(find.byTooltip('删除这个对话'), findsNWidgets(2));
      await t.pumpWidget(const SizedBox());
      ctl.dispose();
    });
  }
}

/// 打开时后台报错的假后台
http.Client _failing(String error) => MockClient((_) async => http.Response(jsonEncode({'error': error}), 502, headers: {'content-type': 'application/json; charset=utf-8'}));
