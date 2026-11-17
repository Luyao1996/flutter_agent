// 管理面板：工具库、资料库、知识库 / 技能的分类列表、刷新按钮（逻辑 + 界面）
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/panels/kb_panel.dart';
import 'package:netbar_ops/src/panels/library_panel.dart';
import 'package:netbar_ops/src/panels/listview.dart';
import 'package:netbar_ops/src/panels/panel_files.dart';
import 'package:netbar_ops/src/panels/skills_panel.dart';
import 'package:netbar_ops/src/panels/tool_args.dart';
import 'package:netbar_ops/src/panels/tools_panel.dart';
import 'package:netbar_ops/src/ui/composer.dart' show Composer;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';
import 'ui_test.dart' show app, base, flush, loadFonts;

void main() {
  group('工具库规则', () {
    test('参数表生成启动参数：选项 + 值、只传值、开关、可选没值整段不加', () {
      final rows = [
        ParamRow(name: 'drive', how: 'opt', opt: '--drive', required: true),
        ParamRow(name: 'mode', how: 'opt', opt: '/mode:'),
        ParamRow(name: 'file', how: 'pos', def: 'a.txt'),
        ParamRow(name: 'verbose', how: 'flag', opt: '-v'),
      ];
      final args = toolArgsFrom(['/silent'], rows);
      expect(args, ['/silent', '--drive', '{drive}', '?mode:/mode:{mode}', '{file}', '?verbose:-v']);
      // 反过来能拆回参数表
      final p = toolParseArgs(args, {
        'drive': {'required': true},
        'mode': {},
        'file': {'default': 'a.txt'},
        'verbose': {'flag': true},
      })!;
      expect(p.fixed, ['/silent']);
      expect(p.how['drive'], const ParamHow('opt', '--drive'));
      expect(p.how['mode'], const ParamHow('opt', '/mode:'));
      expect(p.how['file'], const ParamHow('pos'));
      expect(p.how['verbose'], const ParamHow('flag', '-v'));
      expect(toolPreview('check.exe', p.fixed, rows), 'check.exe /silent --drive <drive> [/mode:<mode>] a.txt [-v]');
    });

    test('常见写错能认出来：“--name {name}”写在一段、只写了选项没写 {参数}', () {
      expect(toolParseArgs(['--name {name}'], {'name': {}})!.how['name'], const ParamHow('opt', '--name'));
      final p = toolParseArgs(['/x', '--name'], {'name': {}})!;
      expect(p.fixed, ['/x']);
      expect(p.how['name'], const ParamHow('opt', '--name'));
      // 拆不开的特殊写法
      expect(toolParseArgs(['pre{name}post'], {'name': {}}), isNull);
      final pr = toolArgProblems({
        'type': 'zip',
        'args': ['--a {a}'],
        'params': {'a': {}, 'b': {}}
      });
      expect(pr.unused, ['b']);
      expect(pr.joined, ['--a {a}']);
    });

    test('参数值字符限制跟着风险和入口变', () {
      expect(toolValueRule('safe', 'a.exe').re.hasMatch('C:/a b_1'), isTrue);
      expect(toolValueRule('safe', 'a.exe').re.hasMatch('a=b'), isFalse);
      expect(toolValueRule('', 'a.exe').re.hasMatch('a=b,"c"&%'), isTrue);
      expect(toolValueRule('', 'a.exe').re.hasMatch('a\nb'), isFalse);
      expect(toolValueRule('danger', 'a.bat').re.hasMatch('a=b,c'), isTrue);
      expect(toolValueRule('danger', 'a.bat').re.hasMatch('a&b'), isFalse);
    });

    test('保存前的检查', () {
      ToolForm f0() => ToolForm()
        ..name = 'disk-check'
        ..desc = '检查硬盘'
        ..entry = 'bin/check.exe';
      expect(buildToolMeta(f0()..name = 'Disk').error, contains('名称'));
      expect(buildToolMeta(f0()..entry = 'a.txt').error, contains('入口程序'));
      expect(buildToolMeta(f0()..rows = [ParamRow(name: 'x', how: 'opt')]).error, contains('选项名'));
      expect(buildToolMeta(f0()..rows = [ParamRow(name: 'x', how: 'pos', def: 'a=b')]).error, isNull); // 高风险的 .exe 可以用 =
      expect(buildToolMeta(f0()
                ..risk = 'safe'
                ..rows = [ParamRow(name: 'x', how: 'pos', def: 'a=b')])
            .error,
          contains('默认值'));
      expect(buildToolMeta(f0()..timeout = '999').error, contains('超时'));
      expect(buildToolMeta(f0()..help = '/?').error, contains('帮助指令'));
      // 自己写启动参数：用到了没登记的参数、登记了没用到
      expect(buildToolMeta(f0()
                ..raw = true
                ..argsText = '{y}')
            .error,
          contains('没登记'));
      expect(buildToolMeta(f0()
                ..raw = true
                ..rows = [ParamRow(name: 'y')])
            .error,
          contains('没用到'));
      // 结果文件不以 {TMP} 开头、写在一段：要再确认
      final ok = buildToolMeta(f0()
        ..raw = true
        ..argsText = '--y {y}'
        ..rows = [ParamRow(name: 'y', desc: '值')]
        ..output = 'out.txt'
        ..category = ' 硬件 / 硬盘 / 多余 '
        ..help = '-h');
      expect(ok.error, isNull);
      expect(ok.confirms.length, 2);
      expect(ok.meta, {
        'name': 'disk-check',
        'type': 'zip',
        'desc': '检查硬盘',
        'category': '硬件/硬盘',
        'entry': 'bin/check.exe',
        'help': '-h',
        'args': ['--y {y}'],
        'params': {
          'y': {'desc': '值'}
        },
        'output': 'out.txt',
      });
      // 显示窗口的工具不能用 {TMP}
      expect(buildToolMeta(f0()
                ..mode = 'interactive'
                ..fixed = '{TMP}')
            .error,
          contains('{TMP}'));
      // http_get
      final h = buildToolMeta(ToolForm()
        ..type = 'http_get'
        ..name = 'bar'
        ..desc = '查'
        ..url = 'https://a/{id}'
        ..headers = 'X-Key: 1'
        ..rows = [ParamRow(name: 'id')]);
      expect(h.meta!['headers'], {'X-Key': '1'});
      expect(h.meta!.containsKey('args'), isFalse);
    });

    test('表单按已有工具填好；自己写和参数表能来回切；没见过的参数字段原样留着', () {
      final f = ToolForm.of({
        'name': 't',
        'type': 'zip',
        'desc': 'd',
        'entry': 'a.exe',
        'args': ['/q', '--n', '{n}'],
        'params': {
          'n': {'desc': '名字', 'future': 1}
        },
      });
      expect(f.raw, isFalse);
      expect(f.fixed, '/q');
      expect(f.rows.single.opt, '--n');
      expect(f.preview, 'a.exe /q [--n <名字>]');
      f.toRaw();
      expect(f.argsText, '/q\n?n:--n\n?n:{n}');
      expect(f.toSimple(), isTrue);
      expect(f.rows.single.how, 'opt');
      expect(buildToolMeta(f).meta!['params'], {
        'n': {'future': 1, 'desc': '名字'}
      });
      expect(ToolForm.of({
        'type': 'zip',
        'args': ['x{n}y'],
        'params': {'n': {}}
      }).raw, isTrue);
    });

    test('上传工具的 multipart：先 meta 再 zip，长度对得上', () async {
      final f = PanelFile(name: 'a.zip', size: 3, bytes: Uint8List.fromList([1, 2, 3]));
      final mp = toolMultipart({'name': 'a'}, f);
      final bytes = (await mp.body().toList()).expand((x) => x).toList();
      expect(bytes.length, mp.length);
      final text = latin1.decode(bytes);
      expect(text.indexOf('name="meta"') < text.indexOf('name="file"'), isTrue);
      final noFile = toolMultipart({'name': 'a'}, null);
      expect((await noFile.body().toList()).expand((x) => x).length, noFile.length);
    });
  });

  group('列表和资料库', () {
    test('分类整理、命中的那一句', () {
      expect(cleanCategory(' 云启动 ／ 日志 /多 '), '云启动/日志');
      expect(categoriesOf(['a/b', 'c', '', 'a']), ['a', 'a/b', 'c']);
      expect(snippetOf('前面的话 错误码 E1024 后面', 'e1024', width: 3), ('…误码 ', 'E1024', ' 后面'));
      expect(snippetOf('abc', 'x'), isNull);
      expect(envOptions(['toolbox']), isEmpty);
      expect(envOptions(['admin', 'yx', '']), [('all', '全部'), ('yx', '银杏'), ('admin', '管理员')]);
    });

    test('资料库的树：路径、放置位置、文件数、能移到哪', () {
      final be = FakeBackend();
      final t = LibTree(be.libRoots, be.libNodes);
      expect(t.path('f2').map((p) => p.$2), ['我们的资料', '云启动', '日志']);
      expect(t.spot('root:admin')!.canEdit, isFalse);
      expect(t.spot('n1'), isNull);
      expect(t.fileCount('root:toolbox'), 1);
      expect(t.kidsOf('f1').map((n) => n.name), ['日志', '说明.md']);
      // 移动文件夹 f1：不能移到它自己和它里面；管理员那套只读不能选
      expect(t.moveTargets([t.byId['f1']!]).map((o) => o.id), ['root:toolbox']);
      expect(t.moveTargets([t.byId['n1']!]).map((o) => o.label), ['▣ 我们的资料', '　云启动', '　　日志']);
    });
  });

  group('面板界面', () {
    setUpAll(loadFonts);
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(FakeBackend, BuildContext)> open(WidgetTester t, NetbarUiStyle style, Size size, {FakeBackend? backend}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final be = backend ?? FakeBackend();
      final config = base.copyWith(uiStyle: style);
      final ctl = ChatController(config, api: NetbarApi(config, newClient: be.client));
      addTearDown(ctl.dispose);
      await t.pumpWidget(app(NetbarOpsView(config: config, controller: ctl),
          platform: style == NetbarUiStyle.cupertino ? TargetPlatform.iOS : (style == NetbarUiStyle.material ? TargetPlatform.android : TargetPlatform.windows)));
      await flush(t, 4);
      return (be, t.element(find.byType(Composer)) as BuildContext);
    }

    testWidgets('工具库（电脑）：按名字打开详情、分类、只读说明、修改后上传', (t) async {
      final (be, ctx) = await open(t, NetbarUiStyle.desktop, const Size(1280, 800));
      openToolsPanel(ctx, name: 'disk-check');
      await flush(t, 10);
      expect(find.textContaining('小王 最后上传'), findsOneWidget);
      expect(find.text('bin/check.exe /silent --drive <盘符>'), findsOneWidget);
      expect(find.text('硬件'), findsOneWidget); // 分类分组
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/windows-7-tools.png'));

      // 管理员上传的：不显示修改、删除，并说明原因
      await t.tap(find.text('bar-info').first);
      await flush(t, 4);
      expect(find.textContaining('只有用管理密码打开的页面能修改'), findsOneWidget);
      expect(find.text('修改'), findsNothing);

      // 修改 disk-check，不换包：只传 meta（multipart）
      await t.tap(find.text('硬盘检查').first);
      await flush(t, 4);
      await t.tap(find.text('修改'));
      await flush(t, 4);
      expect(find.text('修改工具：disk-check'), findsOneWidget);
      await t.dragUntilVisible(find.text('保存'), find.text('修改工具：disk-check'), const Offset(0, -300));
      await t.pump();
      await t.tap(find.text('保存'));
      await flush(t, 10);
      expect(be.calls, contains('/api/tools/upload'));
      expect(be.lastHeaders['content-type'], startsWith('multipart/form-data'));
      expect(be.lastHeaders['x-ops-sfu'], '0');
      final body = utf8.decode(be.lastRaw);
      expect(body, contains('"args":["/silent","--drive","{drive}"]'));
      expect(body, isNot(contains('name="file"')));
      expect(find.textContaining('已更新：disk-check'), findsOneWidget);
    });

    testWidgets('工具库：链接没有登录令牌时先输管理密码（只记在内存里）', (t) async {
      final (be, ctx) = await open(t, NetbarUiStyle.desktop, const Size(1280, 800), backend: FakeBackend()..toolToken = false);
      openToolsPanel(ctx);
      await flush(t, 8);
      expect(find.textContaining('输入管理密码后才能查看'), findsWidgets);
      expect(be.calls.where((c) => c == '/api/tools/list'), isEmpty);
      await t.tap(find.text('输入管理密码'));
      await flush(t, 4);
      await t.enterText(find.byType(TextField).last, 'pw');
      await t.tap(find.text('确定'));
      await flush(t, 10);
      expect(find.text('已输入管理密码'), findsOneWidget);
      expect(find.text('硬盘检查'), findsWidgets);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().any((k) => prefs.get(k).toString().contains('0123456789abcdef')), isFalse);
    });

    testWidgets('资料库（iOS 窄屏）：文件夹按钮选文件夹、打开文件、搜索点进去标出命中', (t) async {
      final (_, ctx) = await open(t, NetbarUiStyle.cupertino, const Size(390, 844));
      openKbPanel(ctx, type: 'background');
      await flush(t, 12);
      expect(find.text('资料库 2'), findsOneWidget); // 文件数
      await t.tap(find.byIcon(Icons.folder_open_outlined));
      await flush(t, 10);
      await t.tap(find.text('云启动'));
      await flush(t, 10);
      expect(find.text('说明.md'), findsOneWidget);
      expect(find.text('日志'), findsOneWidget);
      expect(find.text('云启动的说明和日志'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ios-7-library.png'));
      await t.tap(find.text('说明.md'));
      await flush(t, 10);
      expect(find.text('云启动说明'), findsOneWidget); // md 按格式显示
      await t.enterText(find.byType(CupertinoSearchTextField), 'E1024');
      await t.pump(const Duration(milliseconds: 400));
      await flush(t, 6);
      expect(find.text('搜索“E1024”'), findsOneWidget);
      await t.tap(find.text('说明.md').last);
      await flush(t, 10);
      expect(find.text('搜索命中的地方'), findsOneWidget);
    });

    testWidgets('技能（安卓）：用密码打开时标出归属，不能改的不显示修改；刷新按钮重新载入', (t) async {
      final be = FakeBackend()..allEnvs = true;
      be.skills.add({'id': 's2', 'name': '管理员的技能', 'description': '什么时候用', 'content': 'x', 'category': '云启动/日志', 'env': 'admin', 'canEdit': false});
      final (_, ctx) = await open(t, NetbarUiStyle.material, const Size(390, 844), backend: be);
      openSkillsPanel(ctx);
      await flush(t, 10);
      expect(find.text('云启动'), findsOneWidget); // 分类分组
      expect(find.text('管理员'), findsOneWidget); // 归属标签
      final before = be.calls.where((c) => c == '/api/skills/list').length;
      await t.tap(find.byTooltip('刷新：重新载入这个窗口的数据'));
      await flush(t, 6);
      expect(be.calls.where((c) => c == '/api/skills/list').length, before + 1);
      // 收起分组再展开：记在本机
      await t.tap(find.text('云启动'));
      await flush(t, 2);
      expect(find.text('管理员的技能'), findsNothing);
      await t.tap(find.text('云启动'));
      await flush(t, 2);
      await t.tap(find.text('管理员的技能'));
      await flush(t, 10);
      expect(find.textContaining('只有用管理密码打开的页面能修改'), findsOneWidget);
      expect(find.text('修改'), findsNothing);
      expect(find.text('运行'), findsOneWidget);
    });
  });
}
