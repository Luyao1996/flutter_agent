// “始终允许”开关：默认按链接（客户机链接开、其他关）、新对话时带上、中途切换调 /api/auto-approve、离开对话回到默认；
// 电脑顶栏开关、手机“更多”菜单和标题标记，普通链接打开前先看风险说明
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/ui/composer.dart' show inputKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';
import 'ui_test.dart' show app, base, findAction, flush, loadFonts;

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('普通链接：默认关；新对话发第一条时带上开关；对话中途切换调后台；离开对话回到默认', () async {
    final be = FakeBackend();
    final ctl = ChatController(base, api: NetbarApi(base, newClient: be.client));
    await ctl.start();
    await settle();
    expect(ctl.autoApprove, isFalse);
    expect(ctl.autoHint, '改动操作要你确认');
    // 还没有对话：只记在本地，发第一条消息时带上
    await ctl.setAutoApprove(true);
    expect(be.autoBodies, isEmpty);
    ctl.input.text = '电脑很卡';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last['autoApprove'], isTrue);
    expect(ctl.autoApprove, isTrue);
    expect(ctl.autoHint, '高危操作仍需确认');
    // 已有对话：以后台记的为准，后续消息不再带
    ctl.input.text = '再看看';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last.containsKey('autoApprove'), isFalse);
    await ctl.setAutoApprove(false);
    expect(be.autoBodies.last, containsPair('on', false));
    expect(ctl.autoApprove, isFalse);
    await ctl.setAutoApprove(true);
    // 新对话：回到默认，后台清掉这个对话的设置
    ctl.newChat();
    await settle();
    expect(be.autoBodies.last.containsKey('on'), isTrue);
    expect(be.autoBodies.last['on'], isNull);
    expect(ctl.autoApprove, isFalse);
    ctl.dispose();
  });

  test('客户机链接：默认开（所有操作直接执行），也能关掉', () async {
    final be = FakeBackend()..startExtra = {'autoRun': true};
    final ctl = ChatController(base, api: NetbarApi(base, newClient: be.client));
    await ctl.start();
    await settle();
    expect(ctl.autoDefault, isTrue);
    expect(ctl.autoApprove, isTrue);
    expect(ctl.autoHint, '所有操作直接执行');
    ctl.input.text = '电脑很卡';
    ctl.sendComposer();
    await settle();
    await ctl.setAutoApprove(false);
    expect(ctl.autoApprove, isFalse);
    expect(ctl.autoHint, '改动操作要你确认');
    ctl.newChat();
    expect(ctl.autoApprove, isTrue);
    ctl.dispose();
  });

  for (final (name, style, size, platform) in [
    ('windows', NetbarUiStyle.desktop, const Size(1280, 800), TargetPlatform.windows),
    ('ios', NetbarUiStyle.cupertino, const Size(390, 844), TargetPlatform.iOS),
    ('android', NetbarUiStyle.material, const Size(390, 844), TargetPlatform.android),
  ]) {
    testWidgets('$name：打开“始终允许”要先看风险说明，开着时有明显标记', (t) async {
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
      await t.enterText(find.byKey(inputKey), '电脑很卡');
      await t.pump();
      await t.tap(findAction(style == NetbarUiStyle.desktop ? '发送（Enter）' : '发送'));
      await flush(t);

      Future<void> openSwitch() async {
        if (style == NetbarUiStyle.desktop) {
          await t.tap(find.text('始终允许'));
        } else {
          await t.tap(find.byTooltip('更多').evaluate().isNotEmpty ? find.byTooltip('更多') : find.bySemanticsLabel('更多'));
          await flush(t, 6);
          await t.tap(find.textContaining('始终允许：'));
        }
        await flush(t, 6);
      }

      // 取消：不打开
      await openSwitch();
      expect(find.text('我已了解风险，开启'), findsOneWidget);
      await t.tap(find.text('取消').last);
      await flush(t, 6);
      expect(ctl.autoApprove, isFalse);
      expect(be.autoBodies, isEmpty);

      await openSwitch();
      await t.tap(find.text('我已了解风险，开启'));
      await flush(t, 6);
      expect(ctl.autoApprove, isTrue);
      expect(be.autoBodies.last, containsPair('on', true));
      if (style == NetbarUiStyle.desktop) {
        expect(find.text('高危操作仍需确认'), findsOneWidget);
      } else {
        expect(find.text('始终允许'), findsOneWidget); // 标题下面的标记
      }
      await t.pump(const Duration(seconds: 5));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/auto-$name-on.png'));

      // 关掉不用确认
      if (style == NetbarUiStyle.desktop) {
        await t.tap(find.text('始终允许'));
      } else {
        await t.tap(find.text('始终允许'));
      }
      await flush(t, 6);
      expect(ctl.autoApprove, isFalse);
      expect(be.autoBodies.last, containsPair('on', false));
      await t.pump(const Duration(seconds: 5));
      await t.pumpWidget(const SizedBox());
      ctl.dispose();
      await t.pump();
    });
  }
}
