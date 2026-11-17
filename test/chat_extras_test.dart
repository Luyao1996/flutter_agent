// 对话里的新内容：截图缩略图、“使用了工具”、取回的文件、语音通话记录、新的确认卡片、@ 工具、语音选项气泡
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const cfg = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-TEST', token: 'test-token-123', netbarName: '测试网吧', netbarSeat: '01');

final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

/// 一个对话的历史记录：@ 了工具、AI 用了工具、截了图、取回了文件、要确认写资料说明；再加一段语音通话记录
List<Map<String, dynamic>> history(String g) => [
  {
    'e': 'user',
    'turn': 't1',
    'd': {
      'text': '清一下临时文件',
      'turn': 't1',
      'kind': 'chat',
      'kbRefs': [
        {'id': 'tool:clean_temp', 'type': 'tool', 'title': '清理临时文件'}
      ]
    }
  },
  {
    'e': 'tool_used',
    'turn': 't1',
    'd': {'name': 'clean_temp', 'title': '清理临时文件', 'args': 'days=7', 'ok': true}
  },
  {
    'e': 'tool_image',
    'turn': 't1',
    'd': {
      'id': 'x1',
      'tool': 'screenshot',
      'machine': '02',
      'attachments': [
        {'group': g, 'id': 'img1', 'name': '02-截图.png', 'size': 100, 'kind': 'image'}
      ]
    }
  },
  {
    'e': 'file_shared',
    'turn': 't1',
    'd': {'machine': '01', 'path': r'C:\logs\a.zip', 'name': 'a.zip', 'size': 2048, 'link': 'http://fake/f/abc'}
  },
  {
    'e': 'approval',
    'turn': 't1',
    'd': {
      'id': 'ap1',
      'tool': 'lib_describe',
      'what': 'AI 要给资料库里的 2 份资料写说明',
      'risks': <String>[],
      'input': {
        '操作': '写资料说明（会覆盖原来的说明）',
        '数量': '2 条',
        '说明': {'/网维/工具箱.docx': '工具箱的安装说明', '/网维/驱动.txt': '显卡驱动版本记录'}
      }
    }
  },
  {
    'e': 'approval',
    'turn': 't1',
    'd': {
      'id': 'ap2',
      'tool': 'tool_library_save',
      'manual': true,
      'what': 'AI 要把工具“清理临时文件”保存到工具库',
      'risks': <String>[],
      'input': {'名称': 'clean_temp'}
    }
  },
  {'e': 'done', 'turn': 't1', 'd': {'turns': 3}},
  {
    'e': 'user',
    'turn': 't2',
    'd': {'text': '📞 语音通话', 'turn': 't2', 'parent': 't1', 'kind': 'voice'}
  },
  {'e': 'voice', 'turn': 't2', 'd': {'role': 'user', 'text': '帮我看看网络'}},
  {'e': 'voice', 'turn': 't2', 'd': {'role': 'assistant', 'text': '好的，我看一下'}},
  {'e': 'done', 'turn': 't2', 'd': {'voice': true}},
];

class Mock {
  Mock([this.group = 'g1']);

  /// 附件按组缓存在内存里：每个界面测试用自己的组，免得拿到上一个测试里的缓存
  final String group;
  final calls = <String, Map<String, dynamic>>{};
  final chatBodies = <Map<String, dynamic>>[];
  http.Client client() => MockClient.streaming((req, body) async {
        final path = req.url.path;
        final text = await body.bytesToString();
        final b = text.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(text) as Map);
        calls[path] = b;
        if (path == '/api/uploads/get') return http.StreamedResponse(Stream.value(png), 200);
        if (path == '/api/chat') {
          chatBodies.add(b);
          return http.StreamedResponse(Stream.value(utf8.encode('event: done\ndata: {}\n\n')), 200, headers: {'content-type': 'text/event-stream'});
        }
        final d = switch (path) {
          '/api/start' => {'token': 'conn-1', 'key': cfg.mcpUrl, 'env': 'toolbox'},
          '/api/sessions/get' => {
              'session': {'title': '清临时文件', 'createdAt': '2026-11-11T08:00:00Z'},
              'events': history(group),
            },
          '/api/uploads/link' => {'path': '/f/img1-link'},
          '/api/kb/suggest' => {
              'items': [
                {'id': 'tool:clean_temp', 'type': 'tool', 'title': '清理临时文件', 'snippet': 'clean_temp · 清掉 7 天前的临时文件'},
                {'id': 's1', 'type': 'skill', 'title': '开机慢检查', 'snippet': ''},
                {'id': 'lib:f1', 'type': 'library', 'title': '工具箱.docx', 'snippet': '/网维/工具箱.docx'},
                {'id': 'k1', 'type': 'experience', 'title': '临时文件太多', 'snippet': ''},
              ]
            },
          _ => {'ok': true},
        };
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(d))), 200, headers: {'content-type': 'application/json'});
      });
}

Widget app(Widget child, {TargetPlatform? platform}) => MaterialApp(theme: ThemeData(platform: platform), home: child);

Future<void> flush(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('@ 工具：候选按 经验、背景知识、资料、技能、工具 分组；选中后变成标签，发送时按 tool:名称 带给后台', () async {
    final m = Mock();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: m.client));
    ctl.input.text = '@清理';
    ctl.input.selection = const TextSelection.collapsed(offset: 3);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(ctl.mentionItems.map((x) => x.type), ['experience', 'library', 'skill', 'tool']);
    ctl.pickMention(ctl.mentionItems.indexWhere((x) => x.type == 'tool'));
    expect(ctl.refs.single.id, 'tool:clean_temp');
    expect(ctl.skill, isNull);
    ctl.input.text = '清一下';
    ctl.sendComposer();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(m.chatBodies.single['kbRefs'], ['tool:clean_temp']);
    ctl.dispose();
  });

  test('语音通话：要选择时的选项气泡不会自动消失，超出数量也不删，选完（交出去执行）才收起', () async {
    final m = Mock();
    final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: m.client));
    final v = ctl.voice..on = true;
    v.debugEvent({
      'type': 'choices',
      'items': ['重启网卡', '换一根网线', '']
    });
    expect(v.choices, ['重启网卡', '换一根网线']);
    expect(v.bubbles.single.choices, ['重启网卡', '换一根网线']);
    // 后面又说了好几句：最早的普通气泡被挤掉，选项气泡留着
    for (var i = 0; i < 8; i++) {
      v.debugEvent({'type': 'speech_started'});
      v.debugEvent({'type': 'user_text', 'text': '第 $i 句'});
    }
    expect(v.bubbles.length, lessThanOrEqualTo(6));
    expect(v.bubbles.where((b) => b.choices != null), hasLength(1));
    v.debugEvent({'type': 'delegate', 'objective': '重启网卡'});
    expect(v.choices, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(v.bubbles.where((b) => b.choices != null), isEmpty);
    expect(m.chatBodies.single['message'], '重启网卡');
    v.on = false;
    ctl.dispose();
  });

  for (final (name, style, platform) in [
    ('windows', NetbarUiStyle.desktop, TargetPlatform.windows),
    ('ios', NetbarUiStyle.cupertino, TargetPlatform.iOS),
    ('android', NetbarUiStyle.material, TargetPlatform.android),
  ]) {
    testWidgets('$name：历史对话里的截图、使用了工具、取回的文件、新确认卡片、语音通话记录', (t) async {
      t.view.physicalSize = name == 'windows' ? const Size(1280, 2400) : const Size(430, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final m = Mock('g-$name');
      final config = cfg.copyWith(uiStyle: style);
      final ctl = ChatController(config, api: NetbarApi(config, newClient: m.client));
      await t.pumpWidget(app(NetbarOpsView(config: config, controller: ctl), platform: platform));
      await flush(t, 4);
      await ctl.openSession('s1');
      // 让第一轮当作正在执行：确认卡片显示按钮
      ctl.liveTurn = 't1';
      ctl.taskId = 'task-1';
      ctl.refresh();
      await flush(t);

      // @ 的工具标签、“使用了工具”一行
      expect(find.text('清理临时文件'), findsOneWidget);
      expect(find.textContaining('使用了工具：', findRichText: true), findsOneWidget);
      expect(find.textContaining('（days=7）', findRichText: true), findsOneWidget);
      // 截图：标题、缩略图、复制链接
      expect(find.text('02 的截图'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      // 取回的文件
      expect(find.text('a.zip'), findsOneWidget);
      // 写资料说明的批量确认：一行一份，只有“允许”（没有“始终允许”）
      expect(find.text('AI 要给资料库里的 2 份资料写说明'), findsOneWidget);
      expect(find.textContaining('工具箱的安装说明', findRichText: true), findsOneWidget);
      expect(find.text('AI 要把工具“清理临时文件”保存到工具库'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('允许执行'), findsOneWidget);
      expect(find.text('本次会话始终允许'), findsOneWidget);
      expect(find.textContaining('改动工具库每次都需要手动允许'), findsOneWidget);
      // 语音通话记录：两句话，没有“本轮结束”
      expect(find.text('帮我看看网络'), findsOneWidget);
      expect(find.text('好的，我看一下'), findsOneWidget);
      expect(find.textContaining('本轮结束'), findsOneWidget);

      // 复制截图的下载链接
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
        return null;
      });
      await t.tap(find.byWidgetPredicate((w) => (w is Tooltip && w.message == '复制下载链接') || (w is Semantics && w.properties.label == '复制下载链接')).first);
      await flush(t, 4);
      expect(m.calls['/api/uploads/link']?['id'], 'img1');
      expect(copied, 'http://fake/f/img1-link');

      // 点消息里 @ 的工具：没接工具面板时弹详情框
      await t.tap(find.text('清理临时文件'));
      await flush(t, 6);
      expect(find.text('工具：清理临时文件'), findsOneWidget);
      await t.tap(find.text('知道了'));
      await flush(t, 12);
      expect(find.text('工具：清理临时文件'), findsNothing);
      // 接了工具面板：交给它打开
      String? opened;
      ctl.onOpenTool = (n) => opened = n;
      await t.tap(find.text('清理临时文件'));
      await t.pump();
      expect(opened, 'clean_temp');
      // 点允许
      await t.tap(find.text('允许'));
      await t.pump();
      expect(m.calls['/api/approve']?['approvalId'], 'ap2');

      // 等提示条自己消失
      await t.pump(const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 1));
      ctl.liveTurn = null;
      ctl.taskId = null;
      await t.pumpWidget(const SizedBox());
      ctl.dispose();
      await t.pump();
    });
  }
}
