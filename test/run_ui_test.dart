// 界面测试：切换 AI 的三级菜单（电脑级联菜单、手机分级面板）、进度条和“AI 的处理过程”、额度用完提示卡、目标栏
// 截图用：flutter test test/run_ui_test.dart --update-goldens
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/ui/composer.dart' show inputKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';
import 'ui_test.dart' show app, base, findAction, flush, loadFonts;

Future<(ChatController, FakeBackend)> open(WidgetTester t, NetbarUiStyle style, Size size, TargetPlatform platform) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final be = FakeBackend();
  final config = base.copyWith(uiStyle: style);
  final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
  await t.pumpWidget(app(NetbarOpsView(config: config, controller: ctl), platform: platform));
  await flush(t, 4);
  await t.tap(find.text('我自己描述问题'));
  await t.pump();
  return (ctl, be);
}

Future<void> say(WidgetTester t, NetbarUiStyle style, String text) async {
  await t.enterText(find.byKey(inputKey), text);
  await t.pump();
  await t.tap(findAction(style == NetbarUiStyle.desktop ? '发送（Enter）' : '发送'));
  await flush(t);
}

Future<void> close(WidgetTester t, ChatController ctl) async {
  // 等提示条自己消失
  await t.pump(const Duration(seconds: 5));
  await t.pumpWidget(const SizedBox());
  ctl.dispose();
  await t.pump();
}

void main() {
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('电脑：三级菜单，鼠标移上去展开下一级，点哪一级就用哪一级并收起', (t) async {
    final (ctl, _) = await open(t, NetbarUiStyle.desktop, const Size(1280, 800), TargetPlatform.windows);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 点第一级：直接换 AI，菜单收起
    await t.tap(find.text('Claude'));
    await flush(t, 3);
    expect(find.text('用哪个 AI 处理'), findsOneWidget);
    expect(find.text('claude-opus-5-5'), findsOneWidget); // 名字后面显示现在用的模型
    expect(find.text('这台服务器上没有安装或没有登录'), findsOneWidget);
    await t.tap(find.text('Codex'), kind: PointerDeviceKind.mouse);
    await flush(t, 3);
    expect(ctl.harnessId, 'codex');
    expect(find.text('用哪个 AI 处理'), findsNothing);

    // 鼠标划过只展开，不改变选择；点第三级选思考深度
    await t.tap(find.text('Codex'));
    await flush(t, 3);
    await mouse.moveTo(t.getCenter(find.text('Claude').last));
    await flush(t, 3);
    expect(find.text('Claude 的模型'), findsOneWidget);
    expect(ctl.harnessId, 'codex');
    await mouse.moveTo(t.getCenter(find.text('Codex').last));
    await flush(t, 3);
    await mouse.moveTo(t.getCenter(find.text('GPT-6.1 Sol')));
    await flush(t, 3);
    expect(find.text('思考深度'), findsOneWidget);
    expect(find.text('想得更深'), findsOneWidget); // Codex 每一档自己的说明
    expect(find.text('默认用 medium'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run-windows-harness-menu.png'));
    await t.tap(find.text('high'), kind: PointerDeviceKind.mouse);
    await flush(t, 3);
    expect(find.text('思考深度'), findsNothing);
    expect(ctl.harnessPick, (model: '', effort: 'high'));
    expect(find.text('Codex · high'), findsOneWidget); // 按钮上显示选的思考深度

    // 点第二级：直接用这个模型，思考深度按默认
    await t.tap(find.text('Codex · high'));
    await flush(t, 3);
    await mouse.moveTo(t.getCenter(find.text('Codex').last));
    await flush(t, 3);
    await t.tap(find.text('GPT-5.1 Codex'), kind: PointerDeviceKind.mouse);
    await flush(t, 3);
    expect(ctl.harnessPick, (model: 'gpt-5.1-codex', effort: ''));
    expect(find.text('Claude 的模型'), findsNothing);
    await close(t, ctl);
  });

  for (final (name, style, platform) in [('ios', NetbarUiStyle.cupertino, TargetPlatform.iOS), ('android', NetbarUiStyle.material, TargetPlatform.android)]) {
    testWidgets('$name：分级面板，点 AI、模型立即生效并进入下一级，点思考深度后关闭', (t) async {
      final (ctl, _) = await open(t, style, const Size(390, 844), platform);
      await t.tap(findAction('添加附件、技能、总结'));
      await flush(t, 6);
      await t.tap(find.textContaining('切换 AI'));
      await flush(t, 8);
      expect(find.text('用哪个 AI 处理'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run-$name-harness-1.png'));
      await t.tap(find.text('Codex'));
      await flush(t, 4);
      expect(ctl.harnessId, 'codex');
      expect(find.text('Codex 的模型'), findsOneWidget);
      await t.tap(find.text('GPT-6.1 Sol'));
      await flush(t, 4);
      expect(find.text('思考深度'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run-$name-harness-3.png'));
      // 返回上一级再进来
      await t.tap(findAction('返回上一级'));
      await flush(t, 2);
      expect(find.text('Codex 的模型'), findsOneWidget);
      await t.tap(find.text('GPT-6.1 Sol'));
      await flush(t, 2);
      await t.tap(find.text('low'));
      await flush(t, 8);
      expect(find.text('思考深度'), findsNothing);
      expect(ctl.harnessPick, (model: '', effort: 'low'));
      await close(t, ctl);
    });
  }

  for (final (name, style, size, platform) in [
    ('windows', NetbarUiStyle.desktop, const Size(1280, 800), TargetPlatform.windows),
    ('android', NetbarUiStyle.material, const Size(390, 844), TargetPlatform.android),
  ]) {
    testWidgets('$name：进度条和处理过程、额度用完提示卡、目标栏', (t) async {
      final (ctl, be) = await open(t, style, size, platform);
      be.withThinking = true;
      await say(t, style, '电脑很卡');
      // 结束后：灰色的一行，写这一轮思考了几段、调用了几次工具
      expect(find.text('处理过程'), findsOneWidget);
      // 手机上窄，只显示标题
      if (style == NetbarUiStyle.desktop) expect(find.textContaining('思考 1 段，调用工具 1 次'), findsWidgets);
      await t.tap(findAction('查看详情 · 2 步'));
      await flush(t, 10);
      expect(find.text('AI 的处理过程'), findsOneWidget);
      expect(find.text('执行 PowerShell 命令'), findsOneWidget);
      expect(find.text('notepad 12%'), findsNothing);
      await t.tap(find.text('Get-Process | Sort CPU'));
      await flush(t, 2);
      expect(find.text('notepad 12%'), findsOneWidget);
      // 有新内容刷新时，展开的不会收起
      ctl.refresh();
      await flush(t, 2);
      expect(find.text('notepad 12%'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run-$name-think.png'));
      if (style == NetbarUiStyle.desktop) {
        await t.tap(find.byTooltip('关闭'));
      } else {
        await t.pageBack();
      }
      await flush(t, 10);

      // 额度用完：提示卡 + “用 Codex 重试这条消息”，英文报错不再重复显示
      be.quotaFail = true;
      await say(t, style, '修好菜单');
      expect(find.text('Claude 的额度用完了，这一轮没做完'), findsOneWidget);
      expect(find.textContaining('处理过程中出错了'), findsNothing);
      expect(ctl.harnessId, 'codex');

      // 目标：设定后输入框上方显示目标栏
      await t.enterText(find.byKey(inputKey), '/目标 修好12号机的菜单');
      await t.pump();
      await t.tap(findAction(style == NetbarUiStyle.desktop ? '发送（Enter）' : '发送'));
      await flush(t);
      expect(find.text('修好12号机的菜单'), findsWidgets);
      expect(find.text('3 秒后自动继续'), findsOneWidget);
      await t.tap(find.text('暂停'));
      await flush(t, 4);
      expect(find.text('已暂停'), findsOneWidget);
      // 回到额度用完的那一轮看提示卡（切到第二轮的分支，目标那轮先不看）
      await t.drag(find.byType(ListView).first, const Offset(0, 300));
      await flush(t, 4);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/run-$name-quota-goal.png'));
      await close(t, ctl);
    });
  }

  testWidgets('额度用完提示卡：点“用 Codex 重试这条消息”真的重发，失败的那轮留在 1/2', (t) async {
    final (ctl, be) = await open(t, NetbarUiStyle.desktop, const Size(1280, 800), TargetPlatform.windows);
    be.quotaFail = true;
    await say(t, NetbarUiStyle.desktop, '修好菜单');
    await t.tap(find.text('用 Codex 重试这条消息'));
    await flush(t);
    expect(be.chatBodies.last['harness'], 'codex');
    expect(be.chatBodies.last['message'], '修好菜单');
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('用 Codex 重试这条消息'), findsNothing);
    await close(t, ctl);
  });
}
