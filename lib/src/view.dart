// 组件入口：按平台换外壳，里面的消息区、输入区、面板共用
// Windows：顶部一排按钮、右侧历史抽屉、可以把文件拖进聊天区
// iOS：导航栏（左边历史，右边新对话和“…”），菜单用底部操作表，历史是推入的整页
// Android：Material 顶栏（右边新对话和更多菜单），历史在左侧抽屉
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

/// 远程运维聊天组件。放在一个页面里即可，它自带顶栏和输入区
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ctl.start());
  }

  @override
  void dispose() {
    _reader.stop();
    _dictation.stop();
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.config.resolveStyle(defaultTargetPlatform);
    return NetbarScope(
      controller: _ctl,
      style: style,
      reader: _reader,
      dictation: _dictation,
      child: Builder(builder: (ctx) {
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
      for (final e in count.entries) Text('• ${e.key}${e.value > 1 ? ' × ${e.value}' : ''}', style: const TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback)),
      const SizedBox(height: 8),
      Text('之前已经在机器上执行过的操作不会撤销，重新生成可能会再执行一遍。需要改动机器时，仍会照常请你确认。', style: TextStyle(color: c.dangerText)),
    ]),
  );
}

// ---------- 共用的小部件 ----------
/// 连接状态：已连接 / 连接失败 / 未连接
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 5)])),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(fontSize: 11.5, color: color)),
    ]);
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
      child: !ctl.thinking
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [const ASpinner(size: 12), const SizedBox(width: 8), Expanded(child: Text(ctl.thinkingText, style: TextStyle(fontSize: 12, color: c.muted)))]),
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
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
          color: NetbarColors.warn.withValues(alpha: .08), border: Border.all(color: NetbarColors.warn.withValues(alpha: .25)), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.bolt, size: 16, color: c.warnText),
        const SizedBox(width: 6),
        Expanded(child: Text('本次会话已开启“始终允许”，高危操作仍需手动确认', style: TextStyle(fontSize: 12, color: c.warnText))),
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
  if (await confirmDialog(context, title: '删除对话？', message: '确定删除对话“${ctl.title.isEmpty ? '(无标题)' : ctl.title}”吗？\n对话记录会全部删除，不能恢复；已经记进知识库的经验会保留。', ok: '删除', destructive: true)) {
    await ctl.deleteSession(ctl.sessionId!);
  }
}

/// 手机上的“更多”菜单
List<SheetAction<String>> _moreActions(BuildContext context) {
  final ctl = NetbarScope.read(context).controller;
  final has = ctl.sessionId != null;
  return [
    const SheetAction('技能', 'skills', icon: Icons.auto_awesome_outlined),
    const SheetAction('知识库', 'kb', icon: Icons.menu_book_outlined),
    SheetAction('记忆${ctl.config.barKey.isEmpty ? '（网吧记忆不可用）' : ''}', 'memory', icon: Icons.sticky_note_2_outlined),
    SheetAction('分享对话', 'share', icon: Icons.ios_share, enabled: has && !ctl.busy),
    SheetAction('总结经验到知识库', 'summarize', icon: Icons.summarize_outlined, enabled: has && !ctl.busy),
    SheetAction('修改对话名称', 'rename', icon: Icons.edit_outlined, enabled: has),
    SheetAction('删除这个对话（调试模式）', 'delete', icon: Icons.delete_outline, destructive: true, enabled: has && ctl.config.isDebug),
  ];
}

void _onMore(BuildContext context, String? r) {
  final ctl = NetbarScope.read(context).controller;
  switch (r) {
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
        ctl.addFile(await f.readAsBytes(), f.name);
      } catch (_) {
        ctl.toast('“${f.name}”读取失败，可能是文件夹或没有权限');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final has = ctl.sessionId != null;
    Widget headBtn(IconData icon, String label, VoidCallback? onPressed) => TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 16),
          label: Text(label),
          style: TextButton.styleFrom(foregroundColor: c.text2, visualDensity: VisualDensity.compact, textStyle: const TextStyle(fontSize: 12.5)),
        );
    return Scaffold(
      key: _scaffold,
      backgroundColor: c.background,
      endDrawer: Drawer(
        width: 340,
        child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
            child: Row(children: [
              Icon(Icons.history, size: 18, color: c.text2),
              const SizedBox(width: 8),
              const Expanded(child: Text('历史对话', style: TextStyle(fontWeight: FontWeight.w600))),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
            ]),
          ),
          Expanded(child: HistoryList(onOpened: () => _scaffold.currentState?.closeEndDrawer())),
        ])),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 顶栏：机器名、自动执行 / 调试模式、连接状态
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
          child: Row(children: [
            Text('远程运维', style: TextStyle(fontWeight: FontWeight.w600, color: c.text2, fontSize: 12.5)),
            const SizedBox(width: 12),
            Icon(Icons.desktop_windows_outlined, size: 15, color: c.muted),
            const SizedBox(width: 6),
            Expanded(
                child: Text(ctl.config.machineName,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.text2, fontFamily: monoFont, fontFamilyFallback: monoFallback))),
            if (ctl.config.isClient) ...[Tag('自动执行模式', icon: Icons.bolt), const SizedBox(width: 8)],
            if (ctl.config.isDebug) ...[const Tag('调试模式', color: Color(0xFFA855F7), icon: Icons.bug_report_outlined), const SizedBox(width: 8)],
            _McpBadge(ctl),
          ]),
        ),
        // 对话栏：名称、改名、删除（调试模式）、各个功能按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 14, 4),
          child: Row(children: [
            if (ctl.title.isNotEmpty) ...[
              ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(ctl.title, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: c.text))),
              if (has) AIconButton(icon: Icons.edit_outlined, tooltip: '修改对话名称', size: 15, onPressed: () => _rename(context)),
              if (has && ctl.config.isDebug) AIconButton(icon: Icons.delete_outline, tooltip: '删除这个对话（调试模式）', size: 15, color: c.dangerText, onPressed: () => _delete(context)),
            ],
            const SizedBox(width: 6),
            Flexible(child: Text(ctl.sessionInfo, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.muted))),
            const Spacer(),
            headBtn(Icons.auto_awesome_outlined, '技能', () => openSkillsPanel(context)),
            headBtn(Icons.share_outlined, '分享', has && !ctl.busy ? () => openSharePanel(context) : null),
            headBtn(Icons.sticky_note_2_outlined, '记忆', () => openMemoryPanel(context)),
            headBtn(Icons.menu_book_outlined, '知识库', () => openKbPanel(context)),
            headBtn(Icons.history, '历史对话', () => _scaffold.currentState?.openEndDrawer()),
            headBtn(Icons.edit_square, '新对话', ctl.newChat),
          ]),
        ),
        Divider(height: 1, color: c.line),
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
                          color: NetbarColors.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(16), border: Border.all(color: NetbarColors.accent, width: 2)),
                      child: Center(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.upload_file, color: c.accentText),
                        const SizedBox(width: 8),
                        Text('松开即可上传', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.accentText)),
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
            constraints: const BoxConstraints(maxWidth: 960),
            child: const Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, 10), child: Composer()),
          ),
        ),
      ]),
    );
  }
}

/// 手机顶栏中间：对话名称 + 机器名和连接状态
class _NavTitle extends StatelessWidget {
  const _NavTitle(this.ctl);
  final ChatController ctl;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ctl, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final c = NetbarColors(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(ctl.title.isEmpty ? '远程运维' : ctl.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(ctl.config.machineName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.muted, fontWeight: FontWeight.w400))),
        const SizedBox(width: 6),
        _McpBadge(ctl),
        if (ctl.config.isClient) ...[const SizedBox(width: 6), Icon(Icons.bolt, size: 13, color: c.accentText)],
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
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemBackground.resolveFrom(context),
      navigationBar: CupertinoNavigationBar(
        padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
        leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => pushPanel(context, title: '历史对话', builder: (ctx) => HistoryList(onOpened: () => Navigator.pop(ctx))),
            child: const Icon(CupertinoIcons.clock, size: 24)),
        middle: _NavTitle(ctl),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CupertinoButton(padding: const EdgeInsets.symmetric(horizontal: 6), onPressed: ctl.newChat, child: const Icon(CupertinoIcons.square_pencil, size: 24)),
          CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: const Icon(CupertinoIcons.ellipsis_circle, size: 24),
              onPressed: () async {
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
              decoration:
                  BoxDecoration(color: CupertinoColors.systemBackground.resolveFrom(context).withValues(alpha: .96), border: Border(top: BorderSide(color: c.line, width: .5))),
              padding: EdgeInsets.fromLTRB(10, 8, 10, 8 + MediaQuery.paddingOf(context).bottom),
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Align(alignment: Alignment.centerLeft, child: _NavTitle(ctl)),
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
                      Padding(padding: const EdgeInsets.fromLTRB(20, 16, 16, 8), child: Text('历史对话', style: Theme.of(ctx).textTheme.titleMedium)),
                      Expanded(child: HistoryList(onOpened: () => Navigator.pop(ctx))),
                    ]))),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _AutoBanner(),
        const Expanded(child: MessageList()),
        const _StatusLine(),
        SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 8), child: const Composer())),
      ]),
    );
  }
}
