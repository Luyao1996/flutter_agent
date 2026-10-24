// 组件入口：按平台换外壳，里面的消息区、输入区、面板共用
// Windows：一行顶栏（宽度够时按钮带文字，窄了只留图标，再窄收进“更多”），右侧历史抽屉，可以把文件拖进聊天区
// iOS：导航栏（左边历史，右边新对话和“…”），菜单用底部操作表，历史是推入的整页
// Android：Material 顶栏（右边新对话和更多菜单），历史在左侧抽屉
// 组件有自己的主题、导航和小提示范围：嵌在宿主应用的一块区域里时，样式不受宿主影响，弹窗和面板也不会盖住宿主的其他部分
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'controller.dart';
import 'panels/history_panel.dart';
import 'panels/kb_panel.dart';
import 'panels/memory_panel.dart';
import 'panels/share_panel.dart';
import 'panels/skills_panel.dart';
import 'services.dart' as services;
import 'ui/adaptive.dart';
import 'ui/composer.dart';
import 'ui/messages.dart';

/// 远程运维聊天组件。放在一个页面或一块区域里即可，它自带顶栏和输入区
class NetbarOpsView extends StatefulWidget {
  const NetbarOpsView({super.key, required this.config, this.controller});
  final NetbarOpsConfig config;

  /// 一般不用传；测试或者需要在外面控制时传入
  final ChatController? controller;

  @override
  State<NetbarOpsView> createState() => _NetbarOpsViewState();
}

class _NetbarOpsViewState extends State<NetbarOpsView> {
  late final ChatController _ctl = widget.controller ?? ChatController(widget.config, shrinkImage: services.shrinkImage);
  final _reader = services.Reader();
  final _dictation = services.Dictation();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _nav = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ctl.start());
  }

  @override
  void dispose() {
    _reader.stop();
    _dictation.cancel();
    _ctl.onToast = null;
    _ctl.onConfirmReplace = null;
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.config.resolveStyle(defaultTargetPlatform);
    final theme = isolatedTheme(context, style);
    Widget shell = Navigator(
      key: _nav,
      onGenerateRoute: (_) => PageRouteBuilder(
        pageBuilder: (ctx, _, _) => Builder(builder: (ctx) {
          // 逻辑层要弹提示、确认时，用组件里面的 context
          _ctl.onToast = (m) {
            if (ctx.mounted) showToast(ctx, m);
          };
          _ctl.onConfirmReplace = (ops) => _confirmReplace(ctx, ops);
          return switch (style) {
            NetbarUiStyle.desktop => const _DesktopShell(),
            NetbarUiStyle.cupertino => const _CupertinoShell(),
            NetbarUiStyle.material => const _MaterialShell(),
          };
        }),
      ),
    );
    // 组件里推入的页面先返回（安卓返回键、iOS 返回手势），回到聊天页后才交给宿主
    shell = NavigatorPopHandler<Object?>(onPopWithResult: (_) => _nav.currentState?.maybePop(), child: shell);
    shell = ScaffoldMessenger(key: _messenger, child: shell);
    // 宿主是 CupertinoApp 等没有 Material 文字资源的应用时，补上默认的
    if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) == null) {
      shell = Localizations(
        locale: const Locale('zh'),
        delegates: const [DefaultMaterialLocalizations.delegate, DefaultCupertinoLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
        child: shell,
      );
    }
    return NetbarScope(
      controller: _ctl,
      style: style,
      reader: _reader,
      dictation: _dictation,
      messengerKey: _messenger,
      child: Theme(
        data: theme,
        child: CupertinoTheme(
          data: CupertinoThemeData(brightness: theme.brightness, primaryColor: NT.accent, scaffoldBackgroundColor: theme.colorScheme.surface),
          child: DefaultTextStyle(style: TextStyle(color: theme.colorScheme.onSurface, fontSize: NT.fBody), child: shell),
        ),
      ),
    );
  }
}

/// 重新生成、编辑重发前的提醒：被替换的内容里已经在机器上执行过操作
Future<bool> _confirmReplace(BuildContext context, List<String> ops) {
  final count = <String, int>{};
  for (final o in ops) {
    count[o] = (count[o] ?? 0) + 1;
  }
  final c = NetbarColors(context);
  return confirmDialog(
    context,
    title: '之前的操作不会撤销',
    ok: '我知道了，继续',
    destructive: true,
    content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const Text('被替换的这段对话里，AI 已经在机器上执行过下面这些操作：'),
      const SizedBox(height: 6),
      for (final e in count.entries) Text('• ${e.key}${e.value > 1 ? ' × ${e.value}' : ''}', style: monoStyle(size: 13)),
      const SizedBox(height: 8),
      Text('之前已经在机器上执行过的操作不会撤销，重新生成可能会再执行一遍。需要改动机器时，仍会照常请你确认。', style: TextStyle(color: c.dangerText)),
    ]),
  );
}

// ---------- 共用的小部件 ----------
/// 连接状态：已连接 / 连接失败 / 连接中
/// 连接状态和顶栏标题直接拿 controller，不从上层找：iOS 推入新页面时导航栏会飞到别处去做转场动画，那里找不到上层
class _McpBadge extends StatelessWidget {
  const _McpBadge(this.ctl);
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final (text, color) = switch (ctl.mcpStatus) {
      'connected' => ('已连接', c.okText),
      'failed' => ('连接失败', c.dangerText),
      _ => ('未连接', c.warnText),
    };
    return Semantics(
      label: '远程机器$text',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(text, maxLines: 1, style: TextStyle(fontSize: NT.fCaption, color: color, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

/// AI 正在处理 / 正在调用工具
class _StatusLine extends StatelessWidget {
  const _StatusLine();
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      alignment: Alignment.topCenter,
      child: !ctl.thinking
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Row(children: [
                const ASpinner(size: 12),
                const SizedBox(width: 8),
                Expanded(child: Text(ctl.thinkingText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
              ]),
            ),
    );
  }
}

/// “本次会话始终允许”已开启的提示条
class _AutoBanner extends StatelessWidget {
  const _AutoBanner();
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    if (!ctl.autoApprove) return const SizedBox.shrink();
    final c = NetbarColors(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(color: NT.warn.withValues(alpha: .1), borderRadius: BorderRadius.circular(NT.rSm)),
      child: Row(children: [
        Icon(Icons.bolt, size: 16, color: c.warnText),
        const SizedBox(width: 6),
        Expanded(child: Text('已开启“本次会话始终允许”，高危操作仍需确认', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: c.warnText))),
        AButton(label: '关闭', small: true, kind: BtnKind.text, onPressed: ctl.autoApproveOff),
      ]),
    );
  }
}

Future<void> _rename(BuildContext context) async {
  final ctl = NetbarScope.read(context).controller;
  if (ctl.sessionId == null) return;
  final t = await promptText(context, title: '修改对话名称', initial: ctl.title, maxLength: 60, ok: '保存');
  if (t != null && t.trim().isNotEmpty && t.trim() != ctl.title) await ctl.renameSession(ctl.sessionId!, t.trim());
}

Future<void> _delete(BuildContext context) async {
  final ctl = NetbarScope.read(context).controller;
  if (ctl.sessionId == null) return;
  if (await confirmDialog(context,
      title: '删除对话？', message: '确定删除对话“${ctl.title.isEmpty ? '(无标题)' : ctl.title}”吗？\n对话记录会全部删除，不能恢复；已经记进知识库的经验会保留。', ok: '删除', destructive: true)) {
    await ctl.deleteSession(ctl.sessionId!);
  }
}

/// “更多”菜单（手机上，以及电脑窄面板里放不下的按钮）
List<SheetAction<String>> _moreActions(BuildContext context, {bool withHistory = false}) {
  final ctl = NetbarScope.read(context).controller;
  final has = ctl.sessionId != null;
  return [
    if (withHistory) const SheetAction('历史对话', 'history', icon: Icons.history),
    const SheetAction('技能', 'skills', icon: Icons.auto_awesome_outlined),
    const SheetAction('知识库', 'kb', icon: Icons.menu_book_outlined),
    SheetAction('记忆', 'memory', icon: Icons.sticky_note_2_outlined, subtitle: ctl.config.barKey.isEmpty ? '网吧记忆不可用（没有网吧名称）' : null),
    SheetAction('分享对话', 'share', icon: Icons.ios_share, enabled: has && !ctl.busy),
    SheetAction('总结经验到知识库', 'summarize', icon: Icons.summarize_outlined, enabled: has && !ctl.busy),
    SheetAction('修改对话名称', 'rename', icon: Icons.edit_outlined, enabled: has),
    if (ctl.config.isDebug) SheetAction('删除这个对话（调试模式）', 'delete', icon: Icons.delete_outline, destructive: true, enabled: has),
  ];
}

void _onMore(BuildContext context, String? r, {VoidCallback? openHistory}) {
  final ctl = NetbarScope.read(context).controller;
  switch (r) {
    case 'history':
      openHistory?.call();
    case 'skills':
      openSkillsPanel(context);
    case 'kb':
      openKbPanel(context);
    case 'memory':
      openMemoryPanel(context);
    case 'share':
      openSharePanel(context);
    case 'summarize':
      ctl.summarize();
    case 'rename':
      _rename(context);
    case 'delete':
      _delete(context);
  }
}

// ---------- Windows ----------
class _DesktopShell extends StatefulWidget {
  const _DesktopShell();
  @override
  State<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<_DesktopShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  bool _dragging = false;

  Future<void> _drop(DropDoneDetails d) async {
    final ctl = NetbarScope.read(context).controller;
    setState(() => _dragging = false);
    if (!ctl.config.isValid) return;
    for (final f in d.files) {
      try {
        final size = await f.length();
        if (size > services.maxFileBytes) {
          ctl.addOversized(f.name, size);
        } else {
          ctl.addFile(await f.readAsBytes(), f.name);
        }
      } catch (_) {
        ctl.toast('“${f.name}”读取失败，可能是文件夹或没有权限');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Scaffold(
      key: _scaffold,
      backgroundColor: c.background,
      endDrawer: Drawer(
        width: 340,
        backgroundColor: c.raised,
        child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
            child: Row(children: [
              const Expanded(child: Text('历史对话', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600))),
              AIconButton(icon: Icons.close, tooltip: '关闭', onPressed: () => _scaffold.currentState?.closeEndDrawer()),
            ]),
          ),
          Expanded(child: HistoryList(onOpened: () => _scaffold.currentState?.closeEndDrawer())),
        ])),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _DesktopHeader(onHistory: () => _scaffold.currentState?.openEndDrawer()),
        const Divider(height: 1),
        const _AutoBanner(),
        Expanded(
          child: DropTarget(
            enable: !kIsWeb,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _drop,
            child: Stack(children: [
              const Positioned.fill(child: MessageList()),
              if (_dragging)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: NT.accent.withValues(alpha: .1), borderRadius: BorderRadius.circular(NT.rLg), border: Border.all(color: NT.accent.withValues(alpha: .7), width: 2)),
                      child: Center(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.upload_file, color: c.accentText),
                        const SizedBox(width: 8),
                        Text('松开即可上传', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: c.accentText)),
                      ])),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const _StatusLine(),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(padding: EdgeInsets.fromLTRB(16, 2, 16, 12 + MediaQuery.paddingOf(context).bottom), child: const Composer()),
          ),
        ),
      ]),
    );
  }
}

/// 电脑上的顶栏：左边对话名称和机器，右边功能按钮；按可用宽度换布局，永远不会挤出界
class _DesktopHeader extends StatelessWidget {
  const _DesktopHeader({required this.onHistory});
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final has = ctl.sessionId != null;
    final cfg = ctl.config;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      // 宽：按钮带文字；中：只有图标；窄：新对话、历史，其余收进“更多”
      final mode = w >= 840 ? 2 : (w >= 560 ? 1 : 0);
      final actions = <(IconData, String, VoidCallback?)>[
        (Icons.auto_awesome_outlined, '技能', () => openSkillsPanel(context)),
        (Icons.menu_book_outlined, '知识库', () => openKbPanel(context)),
        (Icons.sticky_note_2_outlined, '记忆', () => openMemoryPanel(context)),
        (Icons.ios_share, '分享', has && !ctl.busy ? () => openSharePanel(context) : null),
        (Icons.history, '历史', onHistory),
      ];
      Widget labeled((IconData, String, VoidCallback?) a) => _HeaderButton(icon: a.$1, label: a.$2, onPressed: a.$3);
      Widget iconOnly((IconData, String, VoidCallback?) a) => AIconButton(icon: a.$1, tooltip: a.$2, size: 18, color: c.text2, onPressed: a.$3);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(
                  child: Text(ctl.title.isEmpty ? '远程运维' : ctl.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fBody + 1, fontWeight: FontWeight.w600, color: c.text)),
                ),
                if (has) AIconButton(icon: Icons.edit_outlined, tooltip: '修改对话名称', size: 15, onPressed: () => _rename(context)),
                if (has && cfg.isDebug && mode > 0) AIconButton(icon: Icons.delete_outline, tooltip: '删除这个对话（调试模式）', size: 15, color: c.dangerText, onPressed: () => _delete(context)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                _McpBadge(ctl),
                if (cfg.machineName.isNotEmpty) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('·', style: TextStyle(color: c.faint))),
                  Flexible(child: Text(cfg.machineName, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(size: NT.fCaption, color: c.muted))),
                ],
                if (cfg.isClient) ...[const SizedBox(width: 6), const Tag('自动执行', icon: Icons.bolt)],
                if (cfg.isDebug) ...[const SizedBox(width: 6), const Tag('调试', color: Color(0xFFA855F7), icon: Icons.bug_report_outlined)],
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          if (mode == 2) ...actions.map(labeled),
          if (mode == 1) ...actions.map(iconOnly),
          if (mode == 0)
            Builder(
                builder: (bctx) => AIconButton(
                    icon: Icons.more_horiz,
                    tooltip: '更多',
                    size: 18,
                    color: c.text2,
                    onPressed: () async {
                      final r = await actionSheet<String>(bctx, actions: _moreActions(bctx, withHistory: true), anchor: rectOf(bctx));
                      if (bctx.mounted) _onMore(bctx, r, openHistory: onHistory);
                    })),
          const SizedBox(width: 4),
          mode == 2
              ? Padding(padding: const EdgeInsets.only(left: 4), child: AButton(label: '新对话', icon: Icons.edit_square, small: true, kind: BtnKind.normal, onPressed: ctl.newChat))
              : AIconButton(icon: Icons.edit_square, tooltip: '新对话', size: 18, color: c.text2, onPressed: ctl.newChat),
        ]),
      );
    });
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, maxLines: 1),
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.disabled) ? c.faint : c.text2),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll((Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(fontSize: NT.fSmall)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(NT.rSm))),
        overlayColor: WidgetStatePropertyAll(c.fill2),
      ),
    );
  }
}

/// 手机顶栏中间：对话名称 + 连接状态和机器名
class _NavTitle extends StatelessWidget {
  const _NavTitle(this.ctl, {this.center = false});
  final ChatController ctl;
  final bool center;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ctl, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final c = NetbarColors(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
      Text(ctl.title.isEmpty ? '远程运维' : ctl.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _McpBadge(ctl),
        if (ctl.config.machineName.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(ctl.config.machineName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: c.muted, fontWeight: FontWeight.w400))),
        ],
        if (ctl.config.isClient) ...[const SizedBox(width: 4), Icon(Icons.bolt, size: 13, color: c.accentText)],
      ]),
    ]);
  }
}

// ---------- iOS ----------
class _CupertinoShell extends StatelessWidget {
  const _CupertinoShell();
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    Widget navButton(IconData icon, String label, VoidCallback onPressed) =>
        Semantics(button: true, label: label, child: CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size(44, 44), onPressed: onPressed, child: Icon(icon, size: 24)));
    return CupertinoPageScaffold(
      backgroundColor: c.background,
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
        leading: navButton(CupertinoIcons.clock, '历史对话', () => pushPanel(context, title: '历史对话', builder: (ctx) => HistoryList(onOpened: () => Navigator.pop(ctx)))),
        middle: _NavTitle(ctl, center: true),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          navButton(CupertinoIcons.square_pencil, '新对话', ctl.newChat),
          navButton(CupertinoIcons.ellipsis_circle, '更多', () async {
            final r = await actionSheet<String>(context, actions: _moreActions(context));
            if (context.mounted) _onMore(context, r);
          }),
        ]),
      ),
      child: SafeArea(
        bottom: false,
        child: Material(
          type: MaterialType.transparency,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _AutoBanner(),
            const Expanded(child: MessageList()),
            const _StatusLine(),
            Container(
              decoration: BoxDecoration(color: c.background, border: Border(top: BorderSide(color: c.line, width: .5))),
              padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + MediaQuery.paddingOf(context).bottom),
              child: const Composer(),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------- Android ----------
class _MaterialShell extends StatelessWidget {
  const _MaterialShell();
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        // 顶栏高度固定，字体放大时只放大到 1.2 倍，免得两行标题挤出界
        title: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.2, child: _NavTitle(ctl)),
        actions: [
          IconButton(tooltip: '新对话', icon: const Icon(Icons.edit_square), onPressed: ctl.newChat),
          Builder(
              builder: (ctx) => IconButton(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () async {
                    final r = await actionSheet<String>(ctx, actions: _moreActions(ctx));
                    if (ctx.mounted) _onMore(ctx, r);
                  })),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
            child: Builder(
                builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Padding(padding: EdgeInsets.fromLTRB(20, 16, 16, 8), child: Text('历史对话', style: TextStyle(fontSize: NT.fTitle + 2, fontWeight: FontWeight.w600))),
                      Expanded(child: HistoryList(onOpened: () => Navigator.pop(ctx))),
                    ]))),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _AutoBanner(),
        const Expanded(child: MessageList()),
        const _StatusLine(),
        SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), child: const Composer())),
      ]),
    );
  }
}
