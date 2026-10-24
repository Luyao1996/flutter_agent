// 界面测试：Windows、iOS、Android 三种外壳各走一遍主要流程，并截图（test/goldens/）
// 截图用：flutter test test/ui_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/panels/kb_panel.dart' show KbPanel;
import 'package:netbar_ops/src/ui/composer.dart' show inputKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';

/// 测试环境默认把文字画成方块；加载真实字体，截图才看得清
Future<void> loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      if (File(f).existsSync()) l.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await l.load();
  }

  const cjk = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
  final home = Platform.environment['HOME'];
  final material = '$home/flutter/bin/cache/artifacts/material_fonts';
  for (final f in ['CJK', 'Roboto', 'CupertinoSystemText', 'CupertinoSystemDisplay', '.SF Pro Text', '.SF Pro Display', '.SF UI Text']) {
    await load(f, [cjk]);
  }
  await load('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await load('packages/cupertino_icons/CupertinoIcons', ['$home/.pub-cache/hosted/pub.dev/cupertino_icons-2.0.0/assets/CupertinoIcons.ttf']);
  await load('monospace', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', cjk]);
}

const base = NetbarOpsConfig(
    baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-TEST', token: 'test-token-123', netbarGroup: '测试组', netbarName: '测试网吧', netbarSeat: '01', isDebug: true);

Widget app(Widget child, {bool dark = false, TargetPlatform? platform}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light, colorSchemeSeed: const Color(0xFF3B82F6), fontFamily: 'Roboto', fontFamilyFallback: const ['CJK'], platform: platform),
      home: child,
    );

/// 按钮：电脑和安卓按提示文字（Tooltip）找，iOS 没有 Tooltip，按读屏标签找
Finder findAction(String label) => find.byWidgetPredicate((w) => (w is Tooltip && w.message == label) || (w is Semantics && w.properties.label == label)).first;

/// 多走几帧，让假后台的实时返回都到
Future<void> flush(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, style, size, platform) in [
    ('windows', NetbarUiStyle.desktop, const Size(1280, 800), TargetPlatform.windows),
    ('ios', NetbarUiStyle.cupertino, const Size(390, 844), TargetPlatform.iOS),
    ('android', NetbarUiStyle.material, const Size(390, 844), TargetPlatform.android),
  ]) {
    testWidgets('$name：新对话选项、发送、实时回复、操作确认、知识库', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final be = FakeBackend();
      final config = base.copyWith(uiStyle: style);
      final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
      await t.pumpWidget(app(NetbarOpsView(config: config, controller: ctl), platform: platform));
      await flush(t, 4);
      expect(find.text('帮我检查这台电脑'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-1-start.png'));

      // 选“我自己描述问题”，输入并发送
      await t.tap(find.text('我自己描述问题'));
      await t.pump();
      expect(find.textContaining('请在下方输入框描述你遇到的问题'), findsOneWidget);
      await t.enterText(find.byKey(inputKey), '12号机开机后游戏菜单打不开');
      await t.pump();
      await t.tap(findAction(style == NetbarUiStyle.desktop ? '发送（Enter）' : '发送'));
      await flush(t);
      expect(find.text('12号机开机后游戏菜单打不开'), findsWidgets);
      expect(find.textContaining('本轮结束'), findsOneWidget);
      expect(ctl.title, '12号机开机后游戏菜单打不开');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-2-chat.png'));

      // 写操作：确认卡片，点“允许执行”
      be.askApproval = true;
      await t.enterText(find.byKey(inputKey), '结束记事本');
      await t.pump();
      await t.tap(findAction(style == NetbarUiStyle.desktop ? '发送（Enter）' : '发送'));
      await flush(t, 4);
      expect(find.text('允许执行'), findsOneWidget);
      await t.enterText(find.byKey(inputKey), '排队的一条');
      await t.pump();
      await t.tap(findAction(style == NetbarUiStyle.desktop ? '排队发送：AI 正在处理，这一轮结束后接着处理' : '排队发送'));
      await flush(t, 2);
      expect(find.text('立即处理'), findsOneWidget);
      await t.ensureVisible(find.text('允许执行'));
      await t.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-3-approval.png'));
      await t.tap(find.text('允许执行'));
      await flush(t, 20);
      // 确认卡片已经滚到上面去了，从记录里检查结果
      expect(ctl.path[1].events.any((e) => e.e == 'approval_done' && e.d['allow'] == true), isTrue);
      expect(ctl.queue, isEmpty);
      expect(ctl.path.length, 3);

      // 知识库：电脑上点顶部按钮；手机上从“更多”菜单打开
      if (style == NetbarUiStyle.desktop) {
        await t.tap(find.text('知识库'));
      } else {
        await t.tap(find.byTooltip('更多').evaluate().isNotEmpty ? find.byTooltip('更多') : find.byIcon(CupertinoIcons.ellipsis_circle));
        await flush(t, 6);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-4-menu.png'));
        await t.tap(find.text('知识库'));
      }
      await flush(t, 10);
      final kbItem = find.descendant(of: find.byType(KbPanel), matching: find.text('桌面图标被隐藏的排查方法'));
      expect(kbItem, findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-5-kb.png'));
      await t.tap(kbItem);
      await flush(t, 10);
      expect(find.text('调用次数'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name-6-kb-detail.png'));
      // 第三轮（排队的那条）还在等确认：关掉组件，实时连接跟着断开
      await t.pumpWidget(const SizedBox());
      ctl.dispose();
      await t.pump();
    });
  }

  testWidgets('暗色主题（Windows）', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final be = FakeBackend();
    final config = base.copyWith(uiStyle: NetbarUiStyle.desktop);
    final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
    await t.pumpWidget(app(NetbarOpsView(config: config, controller: ctl), dark: true));
    await flush(t, 4);
    await t.enterText(find.byKey(inputKey), '游戏打不开');
    await t.pump();
    await t.tap(find.byTooltip('发送（Enter）'));
    await flush(t);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/windows-dark.png'));
  });
}
