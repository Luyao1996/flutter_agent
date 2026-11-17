// 多人会话的界面：群聊消息（自己的靠右、别人的靠左带名字、@ 我的高亮）、别人叫 AI 的消息、“听到……我来处理”卡片、
// 确认记录写明谁点的、顶部“几人在线”、分享窗口里的“邀请加入”。三种界面风格各走一遍并截图
// 截图：flutter test test/group_ui_test.dart --update-goldens（test/goldens/group-*.png）
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/panels/invite_panel.dart';
import 'package:netbar_ops/src/ui/composer.dart' show inputKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';
import 'ui_test.dart' show loadFonts, flush, app, base;

Map<String, dynamic> ev(String e, Map<String, dynamic> d, String turn) => {'e': e, 'd': d, 'turn': turn};

final groupSession = {
  'session': {'id': 'g1', 'title': '12号机开机慢', 'createdAt': '2026-11-17T08:00:00Z'},
  'events': [
    ev('user', {
      'text': '12号机开机慢',
      'kind': 'chat',
      'turn': 't1',
      'by': {'id': 'owner', 'name': '房主'},
    }, 't1'),
    ev('text', {'text': '启动项里有个更新程序，已经关掉了。'}, 't1'),
    ev('done', {'turns': 2}, 't1'),
    ev('chat', {
      'from': {'id': 'm1', 'name': '老王'},
      'text': '@房主 3号机也没声音',
      'mentions': ['owner'],
    }, 't1'),
    ev('chat', {
      'from': {'id': 'owner', 'name': '房主'},
      'text': '@老王 好的，我让龙龙看看',
      'mentions': ['m1'],
    }, 't1'),
    ev('user', {
      'text': '龙龙 看下3号机声卡',
      'kind': 'chat',
      'turn': 't2',
      'parent': 't1',
      'by': {'id': 'm1', 'name': '老王'},
    }, 't2'),
    ev('tool_use', {
      'id': 'x1',
      'name': 'restart_service',
      'input': {'name': 'Audiosrv'},
      'write': true,
    }, 't2'),
    ev('approval', {
      'id': 'x1',
      'tool': 'restart_service',
      'input': {'name': 'Audiosrv'},
      'risks': [],
    }, 't2'),
    ev('approval_done', {'id': 'x1', 'allow': true, 'by': '老王'}, 't2'),
    ev('tool_result', {'id': 'x1', 'content': 'ok'}, 't2'),
    ev('text', {'text': '声卡服务已重启，3号机有声音了。'}, 't2'),
    ev('done', {'turns': 3}, 't2'),
    ev('auto_task', {'id': 'a1', 'task': '看一下 8 号机为什么卡', 'from': '老王', 'reason': '老王说8号机卡'}, 't2'),
    ev('auto_task_status', {'id': 'a1', 'status': 'queued'}, 't2'),
  ],
};

void main() {
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, style, size, platform) in [
    ('windows', NetbarUiStyle.desktop, const Size(1280, 860), TargetPlatform.windows),
    ('ios', NetbarUiStyle.cupertino, const Size(390, 844), TargetPlatform.iOS),
    ('android', NetbarUiStyle.material, const Size(390, 844), TargetPlatform.android),
  ]) {
    testWidgets('$name：群聊消息、自动任务、几人在线、邀请加入', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final be = FakeBackend()
        ..sessionData = groupSession
        ..guests.add({'id': 'm1', 'name': '老王', 'online': true});
      final config = base.copyWith(uiStyle: style);
      final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
      await t.pumpWidget(
        app(
          NetbarOpsView(config: config, controller: ctl),
          platform: platform,
        ),
      );
      await flush(t, 4);
      await ctl.openSession('g1');
      await flush(t, 6);

      expect(find.text('2 人在线'), findsOneWidget);
      expect(find.text('叫 AI 处理'), findsOneWidget);
      expect(find.text('老王 点的'), findsOneWidget);
      expect(find.text('旁听到要处理的事'), findsOneWidget);
      expect(find.text('排在当前工作后面，轮到了自动开始'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.textContaining('3号机也没声音'), findsOneWidget);
      // 群聊模式的输入框提示
      final hint = style == NetbarUiStyle.cupertino
          ? (t.widget<CupertinoTextField>(find.byKey(inputKey)).placeholder ?? '')
          : (t.widget<TextField>(find.byKey(inputKey)).decoration?.hintText ?? '');
      expect(hint, startsWith('直接说就是问 AI'));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/group-$name-chat.png'));

      // 取消自动任务
      await t.ensureVisible(find.text('取消'));
      await t.tap(find.text('取消'));
      await flush(t, 4);
      expect(find.text('已取消（房主 取消的）'), findsOneWidget);

      // 点“几人在线”打开分享窗口的“邀请加入”，生成链接
      await t.tap(find.text('2 人在线'));
      await flush(t, 10);
      expect(find.byType(InvitePanel), findsOneWidget);
      expect(find.text('群成员（2）'), findsOneWidget);
      await t.tap(find.text('永久'));
      await t.pump();
      await t.tap(find.text('生成邀请链接'));
      await flush(t, 6);
      expect(find.text('http://fake/join/abcdef0123456789abcdef01'), findsOneWidget);
      expect(find.text('永久有效'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/group-$name-invite.png'));

      // 移出老王
      await t.ensureVisible(find.text('移出'));
      await t.pump();
      await t.tap(find.text('移出'));
      await flush(t, 6);
      expect(find.text('确定把“老王”移出这个会话吗？'), findsOneWidget);
      await t.tap(find.text('移出').last);
      await flush(t, 6);
      expect(find.text('群成员（1）'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      ctl.dispose();
      await t.pump();
    });
  }
}
