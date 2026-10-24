// 兼容性测试：嵌在宿主应用的窄面板里、宿主有自己的主题（输入框边框、按钮样式）、手机窄屏、系统字体放大
// 截图：flutter test test/compat_test.dart --update-goldens（test/goldens/compat-*.png）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/ui/composer.dart' show inputKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';
import 'ui_test.dart' show loadFonts, flush, findAction;

const base = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-20260917-7GzPA8J3Z9By', token: 'test-token-123', isDebug: true);

/// 一个“不友好”的宿主主题：输入框带外框和底色、按钮加大内边距、列表项加大、字体放大
ThemeData hostTheme(Brightness b) => ThemeData(
      brightness: b,
      colorSchemeSeed: Colors.teal,
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['CJK'],
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0x22FFFFFF),
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.blueAccent, width: 2)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.orange, width: 3)),
        contentPadding: EdgeInsets.all(20),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18), textStyle: const TextStyle(fontSize: 18))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(padding: const EdgeInsets.all(22), shape: const BeveledRectangleBorder())),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(iconSize: 32, padding: const EdgeInsets.all(16))),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.all(24), tileColor: Colors.purple),
      cardTheme: const CardThemeData(margin: EdgeInsets.all(30)),
    );

Future<ChatController> pumpHost(WidgetTester t, {required Size size, required NetbarUiStyle style, required TargetPlatform platform, double textScale = 1, Brightness b = Brightness.dark}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final be = FakeBackend();
  final config = base.copyWith(uiStyle: style);
  final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
  // 宿主应用：自己的 Scaffold、AppBar，把组件放在右侧面板里
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: hostTheme(b).copyWith(platform: platform),
    builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: Scaffold(
      appBar: AppBar(title: const Text('AI 助手 运行中'), toolbarHeight: 40),
      body: NetbarOpsView(config: config, controller: ctl),
    ),
  ));
  await flush(t, 4);
  addTearDown(ctl.dispose);
  return ctl;
}

Future<void> chat(WidgetTester t, String tooltip) async {
  await t.tap(find.text('我自己描述问题'));
  await t.pump();
  await t.enterText(find.byKey(inputKey), '请帮我解决这个问题：网卡丢包计数异常（主网卡 以太网 3，丢弃计数持续上涨），顺便看看驱动版本');
  await t.pump();
  await t.tap(findAction(tooltip));
  await flush(t);
}

void main() {
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Windows 窄面板 820px + 宿主主题', (t) async {
    final ctl = await pumpHost(t, size: const Size(820, 900), style: NetbarUiStyle.desktop, platform: TargetPlatform.windows);
    await chat(t, '发送（Enter）');
    ctl.autoApprove = true;
    ctl.refresh();
    await t.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/compat-windows-820.png'));
  });

  testWidgets('Windows 600px 极窄 + 字体放大 1.3', (t) async {
    await pumpHost(t, size: const Size(600, 800), style: NetbarUiStyle.desktop, platform: TargetPlatform.windows, textScale: 1.3, b: Brightness.light);
    await chat(t, '发送（Enter）');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/compat-windows-600.png'));
  });

  testWidgets('安卓 320px + 字体放大 1.5', (t) async {
    await pumpHost(t, size: const Size(320, 640), style: NetbarUiStyle.material, platform: TargetPlatform.android, textScale: 1.5);
    await chat(t, '发送');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/compat-android-320.png'));
  });

  testWidgets('iOS 320px + 字体放大 1.5（亮色）', (t) async {
    await pumpHost(t, size: const Size(320, 640), style: NetbarUiStyle.cupertino, platform: TargetPlatform.iOS, textScale: 1.5, b: Brightness.light);
    await chat(t, '发送');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/compat-ios-320.png'));
  });
}
