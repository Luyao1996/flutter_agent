// 消息区：每一轮的用户消息、AI 回复、操作确认、问题选项、提示行，以及消息下方的操作
// AI 回复不加气泡、占满宽度（像 ChatGPT / Claude），边生成边显示，末尾有闪烁的光标
// 电脑上：选中文字右键可以“引用”，每条回复下方有一排操作按钮
// 手机上：长按消息弹出操作菜单（复制、选择文字、引用、反馈、重新生成），符合手机聊天应用的习惯
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../models.dart';
import '../panels/kb_panel.dart';
import '../panels/skills_panel.dart';
import '../services.dart';
import 'adaptive.dart';
import 'attachments.dart';
import 'markdown.dart';

const _harnessNames = {'claude': 'Claude', 'codex': 'Codex', 'dsh': 'DeepSeek'};

class MessageList extends StatefulWidget {
  const MessageList({super.key});
  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scroll = ScrollController();
  ChatController? _ctl;
  String _lastSig = '';
  bool _stick = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ctl = NetbarScope.of(context).controller;
    if (ctl != _ctl) {
      _ctl?.removeListener(_onChange);
      _ctl = ctl..addListener(_onChange);
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _stick = _scroll.position.maxScrollExtent - _scroll.offset < 160;
    });
  }

  /// 有新内容时：原来就在底部（或开始了新的一轮）就滚到最下面
  void _onChange() {
    final c = _ctl!;
    final sig = '${c.events.length}:${c.notes.length}:${c.streamingText?.length ?? 0}:${c.liveTurn}';
    if (sig == _lastSig) return;
    final newTurn = c.events.isNotEmpty && c.events.last.e == 'user' && !_lastSig.startsWith('${c.events.length}:');
    _lastSig = sig;
    if (!(_stick || newTurn)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _ctl?.removeListener(_onChange);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final path = ctl.path;
    final undone = {
      for (final e in ctl.events)
        if (e.e == 'memory_undone') str(e.d['id'])
    };
    final lastId = path.isEmpty ? null : path.last.id;
    // 先列出要显示的块，列表只构建看得见的那几块
    final items = <Widget Function()>[
      if (path.isEmpty && ctl.notes.isEmpty && !ctl.showStartChoices && !ctl.busy) () => const _EmptyTip(),
      if (ctl.showStartChoices) () => const _StartChoices(),
      for (final t in path) () => TurnView(t, key: ValueKey(t.id), undone: undone, isLast: t.id == lastId),
      for (final n in ctl.notes) () => NoteView(n),
      if (ctl.historyNote) () => const _Divider('以上是历史记录 · 在下方输入，AI 会记得前面的内容，接着这个对话继续处理'),
    ];
    final maxWidth = s.isDesktop ? 860.0 : 760.0;
    return ScrollConfiguration(
      // 自己画一个滚动条，避免电脑上出现两个
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 20 : 14, vertical: 16),
          itemCount: items.length,
          itemBuilder: (ctx, i) => Center(
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: Padding(padding: const EdgeInsets.only(bottom: 18), child: items[i]())),
          ),
        ),
      ),
    );
  }
}

class _EmptyTip extends StatelessWidget {
  const _EmptyTip();
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Column(children: [
        Icon(Icons.smart_toy_outlined, size: 40, color: NT.accent.withValues(alpha: .9)),
        const SizedBox(height: 12),
        Text('描述遇到的问题，AI 会通过远程连接帮你排查处理。', textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
        const SizedBox(height: 4),
        Text('例如：“12号机开机后游戏菜单打不开，帮我看看原因”', textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: NT.fCaption)),
      ]),
    );
  }
}

/// 新对话的两个选项
class _StartChoices extends StatelessWidget {
  const _StartChoices();
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ChoicesCard(
          title: '新对话，想怎么开始？',
          enabled: !ctl.startPicked,
          choices: [
            (icon: Icons.document_scanner_outlined, title: '帮我检查这台电脑', detail: 'AI 截图查看当前桌面，找出可能的问题列给你选，只查看、不改动机器', onTap: () => ctl.pickStart(true)),
            (icon: Icons.edit_outlined, title: '我自己描述问题', detail: '在下方输入框说说遇到了什么，例如：游戏打不开、没有声音、上不了网', onTap: () => ctl.pickStart(false)),
          ],
        ),
      ),
    );
  }
}

typedef Choice = ({IconData? icon, String title, String detail, VoidCallback onTap});

/// 一组可选项的卡片（新对话选项、自动检查后发现的问题）
class ChoicesCard extends StatelessWidget {
  const ChoicesCard({super.key, required this.title, required this.choices, required this.enabled});
  final String title;
  final List<Choice> choices;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final s = NetbarScope.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(2, 0, 2, 8), child: Text(title, style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.text2))),
      for (final ch in choices)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Opacity(
            opacity: enabled ? 1 : .5,
            child: DecoratedBox(
              decoration: BoxDecoration(color: c.card, border: Border.all(color: c.line), borderRadius: BorderRadius.circular(NT.rMd)),
              child: Pressable(
                onTap: enabled ? ch.onTap : null,
                radius: NT.rMd,
                label: ch.title,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: s.isMobile ? 13 : 11),
                  child: Row(children: [
                    if (ch.icon != null) ...[Icon(ch.icon, size: 20, color: c.accentText), const SizedBox(width: 12)],
                    Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(ch.title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                      if (ch.detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(ch.detail, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
                    ])),
                    Icon(s.isCupertino ? CupertinoIcons.chevron_forward : Icons.chevron_right, size: 18, color: c.faint),
                  ]),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// 居中的灰色提示行（本轮结束、已记入知识库…），可以带一个可点的链接
/// 链接是文字的一部分（TextSpan），系统字体放大时和周围的字一样大，换行也自然
class SysLine extends StatefulWidget {
  const SysLine({super.key, required this.text, this.icon, this.link, this.onLink, this.tail, this.color, this.trailing});
  final String text;
  final IconData? icon;
  final String? link, tail;
  final VoidCallback? onLink;
  final Color? color;
  final Widget? trailing;
  @override
  State<SysLine> createState() => _SysLineState();
}

class _SysLineState extends State<SysLine> {
  final _tap = TapGestureRecognizer();
  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final col = widget.color ?? c.muted;
    _tap.onTap = widget.onLink;
    return Center(
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, spacing: 6, runSpacing: 2, children: [
        Text.rich(
          TextSpan(style: TextStyle(fontSize: NT.fCaption, color: col, height: 1.5), children: [
            if (widget.icon != null) WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: const EdgeInsets.only(right: 5), child: Icon(widget.icon, size: 14, color: col))),
            TextSpan(text: widget.text),
            if (widget.link != null)
              TextSpan(
                text: widget.link,
                recognizer: _tap,
                mouseCursor: SystemMouseCursors.click,
                style: TextStyle(color: c.accentText, decoration: TextDecoration.underline, decorationColor: c.accentText.withValues(alpha: .5)),
              ),
            if (widget.tail != null) TextSpan(text: widget.tail),
          ]),
          textAlign: TextAlign.center,
        ),
        ?widget.trailing,
      ]),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Column(children: [const Divider(), const SizedBox(height: 6), Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: NT.fCaption, color: c.muted))]);
  }
}

/// 只在界面上显示的提示（AI 口吻的提示、出错）
class NoteView extends StatelessWidget {
  const NoteView(this.n, {super.key});
  final LocalNote n;
  @override
  Widget build(BuildContext context) {
    if (n.kind == 'sys') return SysLine(text: n.text);
    if (n.kind == 'error') return ErrorBubble(n.text);
    return _AiText(child: Text(n.text, style: TextStyle(color: NetbarColors(context).text2, fontSize: _bodySize(context), height: 1.6)));
  }
}

double _bodySize(BuildContext context) => NetbarScope.of(context).isMobile ? NT.fBodyMobile : NT.fBody;

class ErrorBubble extends StatelessWidget {
  const ErrorBubble(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: NT.danger.withValues(alpha: .08), borderRadius: BorderRadius.circular(NT.rMd), border: Border.all(color: NT.danger.withValues(alpha: .25))),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 16, color: c.dangerText)),
          const SizedBox(width: 8),
          Flexible(child: SelectableText(text, style: TextStyle(color: c.dangerText, fontSize: NT.fSmall, height: 1.5))),
        ]),
      ),
    );
  }
}

/// AI 回复的容器：不加气泡，占满宽度
class _AiText extends StatelessWidget {
  const _AiText({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: child));
}

/// 版本切换 ‹ 1/2 ›
class BranchNav extends StatelessWidget {
  const BranchNav(this.t, {super.key});
  final Turn t;
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final ids = ctl.tree.siblings(t);
    if (ids.length < 2) return const SizedBox.shrink();
    final i = ids.indexOf(t.id);
    final c = NetbarColors(context);
    final idle = !ctl.busy;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AIconButton(icon: Icons.chevron_left, tooltip: '上一个版本', size: 18, onPressed: idle && i > 0 ? () => ctl.stepBranch(t, -1) : null),
      Text('${i + 1}/${ids.length}', style: monoStyle(size: NT.fCaption, color: c.muted)),
      AIconButton(icon: Icons.chevron_right, tooltip: '下一个版本', size: 18, onPressed: idle && i < ids.length - 1 ? () => ctl.stepBranch(t, 1) : null),
    ]);
  }
}

/// 一轮对话
class TurnView extends StatelessWidget {
  const TurnView(this.t, {super.key, required this.undone, required this.isLast});
  final Turn t;

  /// 已经撤销的记忆
  final Set<String> undone;

  /// 是不是当前版本的最后一轮（问题选项只在最后一轮能点）
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final live = ctl.liveTurn == t.id;
    final children = <Widget>[];
    // 开头：用户消息，或者“自动检查当前桌面”这类提示行
    if (t.kind == 'chat') {
      children.add(ctl.editingTurn == t.id ? _EditBox(t) : _UserMessage(t));
    } else {
      children.add(Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Flexible(child: SysLine(text: t.text.replaceFirst(RegExp(r'^\S+\s*'), ''), icon: t.kind == 'diagnose' ? Icons.document_scanner_outlined : Icons.summarize_outlined)),
        if (t.kind == 'diagnose') BranchNav(t),
      ]));
    }
    final approvals = {for (final e in t.events.where((e) => e.e == 'approval_done')) str(e.d['id']): e.d};
    final harnessName = _harnessNames[str(t.user['harness'])];
    for (var i = 0; i < t.events.length; i++) {
      final ev = t.events[i];
      final d = ev.d;
      switch (ev.e) {
        case 'text':
          final sp = splitOptions(str(d['text']));
          final key = '${t.id}:$i';
          final animate = live && ctl.typewriterKey == key && DateTime.now().difference(ctl.typewriterAt) < const Duration(seconds: 2);
          if (sp.text.isNotEmpty) children.add(AiMessage(t, sp.text, key: ValueKey(key), typewriter: animate));
          if (sp.options != null && sp.options!.isNotEmpty) {
            final enabled = !ctl.lockedOptions.contains(key) && isLast && !ctl.busy;
            children.add(ChoicesCard(
              title: 'AI 发现了下面这些可能的问题，请选择要解决的：',
              enabled: enabled,
              choices: [
                for (final o in sp.options!) (icon: null, title: o.title, detail: o.detail, onTap: () => ctl.pickOption(key, o)),
                (icon: null, title: '都不是，我自己描述问题', detail: '', onTap: () => ctl.pickOption(key, null)),
              ],
            ));
          }
        case 'approval':
          children.add(ApprovalCard(d, result: approvals[str(d['id'])], live: live && ctl.taskId != null));
        case 'kb_used':
          final eff = d['effective'];
          children.add(SysLine(
            icon: eff == false
                ? Icons.close
                : eff == true
                    ? Icons.check
                    : Icons.lightbulb_outline,
            text: '经验',
            link: str(d['title']),
            tail: eff == true
                ? '这次有效'
                : eff == false
                    ? '这次没有解决问题'
                    : '参照处理',
            onLink: () => openKbPanel(context, type: 'experience', selectId: str(d['id'])),
          ));
        case 'kb_saved':
          children.add(SysLine(
              icon: Icons.menu_book_outlined,
              text: d['updated'] == true ? '已更新知识库：' : '已记入知识库：',
              link: str(d['title']),
              onLink: () => openKbPanel(context, type: 'experience', selectId: str(d['id']))));
        case 'skill_used':
          children.add(SysLine(icon: Icons.auto_awesome_outlined, text: '正在使用技能：', link: str(d['name']), onLink: () => openSkillsPanel(context, selectId: str(d['id']))));
        case 'memory_saved':
          final isUndone = undone.contains(str(d['id']));
          children.add(SysLine(
            icon: Icons.sticky_note_2_outlined,
            text: '已记住：${str(d['content'])}（${memoryScopeNames[str(d['scope'])] ?? ''}）',
            trailing: isUndone
                ? Text('已撤销', style: TextStyle(fontSize: NT.fCaption, color: c.muted))
                : AButton(label: '撤销', icon: Icons.undo, small: true, kind: BtnKind.text, onPressed: () => ctl.undoMemory(str(d['id']), t.id)),
          ));
        case 'notice':
          children.add(SysLine(icon: Icons.info_outline, text: str(d['text']), color: c.warnText));
        case 'auto_mode':
          children.add(const SysLine(icon: Icons.bolt, text: '已开启“本次会话始终允许”，高危操作仍需手动确认'));
        case 'machine_connected':
          children.add(SysLine(icon: Icons.link, text: '已连接本网吧的另一台电脑：${str(d['seat'])}${str(d['name']).isNotEmpty ? '（${str(d['name'])}）' : ''}'));
        case 'machine_disconnected':
          children.add(SysLine(icon: Icons.link_off, text: '已断开 ${str(d['seat'])}'));
        case 'done':
          if (d['isError'] == true) {
            children.add(ErrorBubble(d['subtype'] == 'error_max_turns'
                ? '已达到单次最多步数，可以回复“继续”接着处理。'
                : str(d['error']).isNotEmpty
                    ? '处理过程中出错了：${d['error']}'
                    : '处理过程中出错了。'));
          }
          final cost = d['cost'] is num ? ' · 约 \$${(d['cost'] as num).toStringAsFixed(4)}' : '';
          final who = _harnessNames[str(d['harness'])] ?? harnessName;
          children.add(SysLine(text: '本轮结束${who == null ? '' : ' · $who'} · ${d['turns'] ?? '-'} 步$cost'));
        case 'error':
          children.add(ErrorBubble(str(d['error'])));
      }
    }
    // 正在生成、还没写完的这段
    if (live && ctl.streamingText != null) children.add(AiMessage(t, ctl.streamingText!, key: const ValueKey('streaming'), streaming: true));
    for (final n in ctl.turnNotes[t.id] ?? const <LocalNote>[]) {
      children.add(NoteView(n));
    }
    if (!live) children.add(TurnActions(t));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < children.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: children[i]),
    ]);
  }
}

/// 用户消息气泡：引用、技能和 @ 标签、附件、文字
class _UserMessage extends StatelessWidget {
  const _UserMessage(this.t);
  final Turn t;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NT.accentStrong,
        borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (t.quote.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(4), border: const Border(left: BorderSide(color: Colors.white70, width: 2))),
            child: Text(t.quote, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: Colors.white.withValues(alpha: .88))),
          ),
        if (t.skill != null || t.kbRefs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              if (t.skill != null)
                _BubbleChip(icon: Icons.auto_awesome_outlined, label: str(t.skill!['name']), skill: true, onTap: () => openSkillsPanel(context, selectId: str(t.skill!['id']))),
              for (final r in t.kbRefs)
                _BubbleChip(
                    icon: r.type == 'background' ? Icons.menu_book_outlined : Icons.lightbulb_outline,
                    label: r.title,
                    onTap: () => openKbPanel(context, type: r.type, selectId: r.id)),
            ]),
          ),
        if (t.attachments.isNotEmpty)
          Padding(
              padding: EdgeInsets.only(bottom: t.noText ? 0 : 8),
              child: Wrap(spacing: 6, runSpacing: 6, children: [for (final a in t.attachments) AttachmentCard(a, onBubble: true)])),
        if (!t.noText) Text(t.text, style: TextStyle(color: Colors.white, fontSize: _bodySize(context), height: 1.5)),
      ]),
    );
    Future<void> menu() async {
      final r = await actionSheet<String>(context, actions: [
        const SheetAction('复制', 'copy', icon: Icons.copy_outlined),
        if (ctl.canBranch(t) && !ctl.busy) const SheetAction('编辑后重新发送', 'edit', icon: Icons.edit_outlined),
      ]);
      if (r == 'copy') {
        await copyText(t.noText ? '' : t.text);
        if (context.mounted) showToast(context, '已复制');
      }
      if (r == 'edit') ctl.beginEdit(t);
    }

    final branch = BranchNav(t);
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      LayoutBuilder(
        builder: (ctx, box) => Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * (s.isMobile ? .86 : .78)),
            child: s.isMobile
                ? GestureDetector(
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      menu();
                    },
                    child: bubble)
                : SelectionArea(child: bubble),
          ),
        ),
      ),
      // 电脑上消息下方一排按钮；手机上长按气泡操作，这里只留版本切换
      if (s.isDesktop)
        Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          AIconButton(
              icon: Icons.copy_outlined,
              tooltip: '复制',
              size: 15,
              onPressed: () async {
                await copyText(t.noText ? '' : t.text);
                if (context.mounted) showToast(context, '已复制');
              }),
          if (ctl.canBranch(t)) AIconButton(icon: Icons.edit_outlined, tooltip: '编辑后重新发送', size: 15, onPressed: ctl.busy ? null : () => ctl.beginEdit(t)),
          branch,
        ])
      else
        branch,
    ]);
  }
}

class _BubbleChip extends StatelessWidget {
  const _BubbleChip({required this.icon, required this.label, required this.onTap, this.skill = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool skill;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: skill ? const Color(0x73A855F7) : Colors.white.withValues(alpha: .16), borderRadius: BorderRadius.circular(999)),
        child: Pressable(
          onTap: onTap,
          radius: 999,
          label: label,
          hoverColor: Colors.white.withValues(alpha: .1),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 12, color: Colors.white),
              const SizedBox(width: 4),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: NT.fCaption, color: Colors.white))),
            ]),
          ),
        ),
      );
}

/// 编辑后重新发送：在气泡原处改文字，附件、引用和推荐的内容保留
class _EditBox extends StatefulWidget {
  const _EditBox(this.t);
  final Turn t;
  @override
  State<_EditBox> createState() => _EditBoxState();
}

class _EditBoxState extends State<_EditBox> {
  late final TextEditingController _ctl = TextEditingController(text: widget.t.noText ? '' : widget.t.text);
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 电脑上 Enter 发送、Esc 取消；输入法正在组字时交给输入法
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final composing = _ctl.value.composing.isValid && !_ctl.value.composing.isCollapsed;
    if (composing) return KeyEventResult.ignored;
    final ctl = NetbarScope.read(context).controller;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      ctl.cancelEdit();
      return KeyEventResult.handled;
    }
    final enter = e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter && !HardwareKeyboard.instance.isShiftPressed && NetbarScope.read(context).isDesktop) {
      ctl.submitEdit(widget.t, _ctl.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final field = s.isCupertino
        ? CupertinoTextField(controller: _ctl, focusNode: _focus, minLines: 2, maxLines: 8, padding: const EdgeInsets.all(10), style: TextStyle(color: c.text))
        : TextField(controller: _ctl, focusNode: _focus, minLines: 2, maxLines: 8, decoration: fieldDecoration(context));
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Focus(onKeyEvent: _onKey, child: field),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text('附件、引用和推荐的内容会保留', maxLines: 2, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
            AButton(label: '取消', kind: BtnKind.text, small: true, onPressed: ctl.cancelEdit),
            const SizedBox(width: 6),
            AButton(label: '发送', kind: BtnKind.primary, small: true, onPressed: () => ctl.submitEdit(widget.t, _ctl.text)),
          ]),
        ]),
      ),
    );
  }
}

/// AI 的一段回复：streaming 时末尾带闪烁的光标；typewriter 时用打字机效果在 1 秒左右显示完
class AiMessage extends StatefulWidget {
  const AiMessage(this.t, this.text, {super.key, this.streaming = false, this.typewriter = false});
  final Turn t;
  final String text;
  final bool streaming, typewriter;
  @override
  State<AiMessage> createState() => _AiMessageState();
}

class _AiMessageState extends State<AiMessage> with SingleTickerProviderStateMixin {
  String _selected = '';
  AnimationController? _type;
  Widget? _cached;
  String _cachedKey = '';

  @override
  void initState() {
    super.initState();
    if (widget.typewriter) {
      _type = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
      _type!.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _type?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final typing = _type != null && _type!.isAnimating;
    final shown = typing ? widget.text.substring(0, (widget.text.length * _type!.value).ceil().clamp(0, widget.text.length)) : widget.text;
    final caret = widget.streaming || typing;
    // 内容没变就不重新解析 Markdown
    final key = '${c.dark}|$caret|${_bodySize(context)}|$shown';
    if (key != _cachedKey) {
      _cachedKey = key;
      _cached = MarkdownBody(shown, fontSize: _bodySize(context), caret: caret);
    }
    final body = _AiText(child: _cached!);
    if (s.isMobile) {
      return GestureDetector(
          onLongPress: caret
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  showReplyMenu(context, widget.t, widget.text);
                },
          child: body);
    }
    // 电脑上：选中文字后右键菜单里多一个“引用”
    return SelectionArea(
      onSelectionChanged: (v) => _selected = v?.plainText ?? '',
      contextMenuBuilder: (ctx, state) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          ...state.contextMenuButtonItems,
          if (_selected.trim().isNotEmpty)
            ContextMenuButtonItem(
                label: '引用',
                onPressed: () {
                  s.controller.setQuote(_selected);
                  state.hideToolbar();
                }),
        ],
      ),
      child: body,
    );
  }
}

/// 手机上长按 AI 回复的菜单
Future<void> showReplyMenu(BuildContext context, Turn t, String text) async {
  final s = NetbarScope.read(context);
  final ctl = s.controller;
  final r = await actionSheet<String>(context, actions: [
    const SheetAction('复制', 'copy', icon: Icons.copy_outlined),
    const SheetAction('选择文字', 'select', icon: Icons.text_fields),
    const SheetAction('引用这段回复', 'quote', icon: Icons.format_quote_outlined),
    if (t.done) ...[
      SheetAction(t.feedback?['value'] == 'up' ? '取消“有帮助”' : '有帮助', 'up', icon: Icons.thumb_up_outlined),
      SheetAction(t.feedback?['value'] == 'down' ? '取消“没帮助”' : '没帮助', 'down', icon: Icons.thumb_down_outlined),
      if (t.kind != 'summarize' && ctl.canBranch(t) && !ctl.busy) const SheetAction('重新生成', 'regen', icon: Icons.refresh),
    ],
  ]);
  if (!context.mounted || r == null) return;
  switch (r) {
    case 'copy':
      await copyText(text);
      if (context.mounted) showToast(context, '已复制');
    case 'select':
      await pushPanel(context, title: '选择文字', builder: (ctx) => _SelectText(text));
    case 'quote':
      ctl.setQuote(text);
    case 'up':
    case 'down':
      await giveFeedback(context, t, r);
    case 'regen':
      await ctl.regenerate(t);
  }
}

/// “选择文字”页：选中一段后，系统的文字菜单里多一个“引用”
class _SelectText extends StatefulWidget {
  const _SelectText(this.text);
  final String text;
  @override
  State<_SelectText> createState() => _SelectTextState();
}

class _SelectTextState extends State<_SelectText> {
  String _sel = '';
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        widget.text,
        style: TextStyle(fontSize: 16, height: 1.6, color: NetbarColors(context).text),
        onSelectionChanged: (sel, _) => _sel = sel.textInside(widget.text),
        contextMenuBuilder: (ctx, state) => AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: [
          ...state.contextMenuButtonItems,
          ContextMenuButtonItem(
              label: '引用',
              onPressed: () {
                ctl.setQuote(_sel);
                state.hideToolbar();
                Navigator.of(context).pop();
              }),
        ]),
      ),
    );
  }
}

/// 点赞、点踩（点踩可以填原因）；再点一次取消
Future<void> giveFeedback(BuildContext context, Turn t, String value) async {
  final ctl = NetbarScope.read(context).controller;
  if (t.feedback?['value'] == value) return ctl.sendFeedback(t, null);
  if (value == 'up') return ctl.sendFeedback(t, 'up');
  final reason = await promptText(context, title: '哪里不满意？', message: '可以不填，直接提交。', hint: '例如：判断错了原因、操作太多、没解决问题…', multiline: true, ok: '提交');
  if (reason != null) await ctl.sendFeedback(t, 'down', reason.trim());
}

/// 一轮结束后的操作：复制、点赞点踩、重新生成（放不下时自动换行）
class TurnActions extends StatelessWidget {
  const TurnActions(this.t, {super.key});
  final Turn t;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final text = t.replyText;
    final fb = t.feedback?['value'];
    final on = NetbarColors(context).accentText;
    final size = s.isDesktop ? 15.0 : 17.0;
    final buttons = <Widget>[
      if (text.isNotEmpty) ...[
        AIconButton(
            icon: Icons.copy_outlined,
            tooltip: '复制',
            size: size,
            onPressed: () async {
              await copyText(text);
              if (context.mounted) showToast(context, '已复制');
            }),
        AIconButton(
            icon: fb == 'up' ? Icons.thumb_up : Icons.thumb_up_outlined, tooltip: '有帮助', size: size, color: fb == 'up' ? on : null, onPressed: () => giveFeedback(context, t, 'up')),
        AIconButton(
            icon: fb == 'down' ? Icons.thumb_down : Icons.thumb_down_outlined,
            size: size,
            color: fb == 'down' ? on : null,
            tooltip: fb == 'down' ? '你点了“没帮助”${str(t.feedback?['reason']).isEmpty ? '' : '：${t.feedback!['reason']}'}（再点一次取消）' : '没帮助',
            onPressed: () => giveFeedback(context, t, 'down')),
      ],
      if (t.kind != 'summarize' && ctl.canBranch(t)) AIconButton(icon: Icons.refresh, tooltip: '重新生成', size: size, onPressed: ctl.busy ? null : () => ctl.regenerate(t)),
      if (t.kind == 'summarize') BranchNav(t),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Transform.translate(offset: Offset(s.isDesktop ? -6 : -10, -6), child: Wrap(children: buttons));
  }
}

/// 写操作确认卡片：等待中显示“允许 / 始终允许 / 拒绝”，处理过显示结果
class ApprovalCard extends StatelessWidget {
  const ApprovalCard(this.a, {super.key, this.result, required this.live});
  final Map<String, dynamic> a;
  final Map<String, dynamic>? result;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final risks = asList(a['risks']).map(str).toList();
    final high = risks.isNotEmpty;
    final allowed = result?['allow'] == true;
    final pending = result == null && live;
    final tone = pending ? (high ? NT.danger : NT.warn) : (result == null ? c.muted : (allowed ? NT.ok : NT.danger));
    Widget footer;
    if (result != null) {
      final reason = str(result!['reason']).split('。').first;
      footer = Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(allowed ? Icons.check_circle_outline : Icons.cancel_outlined, size: 16, color: allowed ? c.okText : c.dangerText),
          const SizedBox(width: 5),
          Text(allowed ? '已允许' : '已拒绝', style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: allowed ? c.okText : c.dangerText)),
        ]),
        if (!allowed && reason.isNotEmpty) Text(reason, style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
      ]);
    } else if (live) {
      footer = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          AButton(label: '允许执行', kind: BtnKind.primary, small: true, onPressed: () => ctl.approve(str(a['id']), allow: true)),
          if (!high)
            AButton(
                label: '本次会话始终允许',
                small: true,
                onPressed: () async {
                  if (await confirmAutoApprove(context)) ctl.approve(str(a['id']), allow: true, always: true);
                }),
          AButton(label: '拒绝', kind: BtnKind.danger, small: true, onPressed: () => ctl.approve(str(a['id']), allow: false)),
        ]),
        const SizedBox(height: 6),
        Text('${high ? '高危操作每次都需要手动允许；' : ''}10 分钟内不处理将自动拒绝', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
      ]);
    } else {
      footer = Text('未处理（对话已中断）', style: TextStyle(fontSize: NT.fCaption, color: c.muted));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: pending ? .07 : .04), c.card),
        border: Border.all(color: tone.withValues(alpha: pending ? .5 : .25)),
        borderRadius: BorderRadius.circular(NT.rMd),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (high) Tag('高危操作', color: c.dangerText) else Icon(Icons.shield_outlined, size: 16, color: pending ? c.warnText : c.muted),
          Text('要执行会改动机器的操作', style: TextStyle(fontSize: NT.fSmall, color: c.text2)),
          Text(str(a['tool']), style: monoStyle(size: NT.fSmall, color: c.text).copyWith(fontWeight: FontWeight.w600)),
        ]),
        if (high) Padding(padding: const EdgeInsets.only(top: 6), child: Text('风险：${risks.join('；')}', style: TextStyle(fontSize: NT.fCaption, color: c.dangerText))),
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(NT.rSm)),
          child: SingleChildScrollView(child: SelectableText(const JsonEncoder.withIndent('  ').convert(a['input']), style: monoStyle(size: NT.fCaption, color: c.text2))),
        ),
        const SizedBox(height: 10),
        footer,
      ]),
    );
  }
}

/// “本次会话始终允许”的风险说明
Future<bool> confirmAutoApprove(BuildContext context) {
  final c = NetbarColors(context);
  TextStyle st([Color? col]) => TextStyle(fontSize: 13.5, height: 1.5, color: col);
  return confirmDialog(
    context,
    title: '开启“本次会话始终允许”',
    ok: '我已了解风险，开启',
    destructive: true,
    content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('开启后，在这次对话结束前，AI 执行普通的改动操作将不再询问你，会直接在机器上执行，例如：结束进程、启停服务、启动程序、执行命令、模拟鼠标键盘、在顾客屏幕上弹提示、调整音量和分辨率。', style: st()),
      const SizedBox(height: 8),
      Text('风险：AI 可能判断失误，打断正在上机的顾客或影响营业；系统无法保证识别出所有危险操作；已经执行的操作可能无法撤销。', style: st(c.dangerText)),
      const SizedBox(height: 8),
      Text('关机、重启、注销、改注册表、删除文件等高危操作，仍然每次都需要你手动允许。可以随时点顶部的“关闭”取消，开始新对话后自动失效。', style: st(c.okText)),
    ]),
  );
}
