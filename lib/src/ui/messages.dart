// 消息区：每一轮的用户消息、AI 回复、操作确认、问题选项、提示行，以及消息下方的操作
// 电脑上：选中文字右键可以“引用”，每条回复下方有一排操作按钮
// 手机上：长按消息弹出操作菜单（复制、选择文字、引用、朗读、反馈、重新生成），符合手机聊天应用的习惯
import 'dart:convert';

import 'package:flutter/cupertino.dart';
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

class MessageList extends StatefulWidget {
  const MessageList({super.key});
  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scroll = ScrollController();
  ChatController? _ctl;
  int _lastCount = -1;
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
    final count = _ctl!.events.length + _ctl!.notes.length;
    final grew = count != _lastCount;
    final newTurn = _ctl!.events.isNotEmpty && _ctl!.events.last.e == 'user';
    _lastCount = count;
    if (!grew || !(_stick || newTurn)) return;
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
    final items = <Widget>[
      if (path.isEmpty && ctl.notes.isEmpty && !ctl.showStartChoices && !ctl.busy) const _EmptyTip(),
      if (ctl.showStartChoices) const _StartChoices(),
      for (final t in path) TurnView(t, key: ValueKey(t.id)),
      for (final n in ctl.notes) NoteView(n),
      if (ctl.historyNote) const _Divider('以上是历史记录 · 在下方输入，AI 会记得前面的内容，接着这个对话继续处理'),
    ];
    final maxWidth = s.isDesktop ? 920.0 : 760.0;
    return Scrollbar(
      controller: _scroll,
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 20 : 12, vertical: 16),
        children: [
          for (final w in items)
            Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: Padding(padding: const EdgeInsets.only(bottom: 12), child: w))),
        ],
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
      padding: const EdgeInsets.only(top: 80),
      child: Column(children: [
        Icon(Icons.smart_toy_outlined, size: 44, color: NetbarColors.accent.withValues(alpha: .9)),
        const SizedBox(height: 10),
        Text('描述遇到的问题，AI 会通过远程连接帮你排查处理。', style: TextStyle(color: c.muted)),
        const SizedBox(height: 4),
        Text('例如：“12号机开机后游戏菜单打不开，帮我看看原因”', style: TextStyle(color: c.faint, fontSize: 12)),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: NetbarColors.accent.withValues(alpha: .05), border: Border.all(color: NetbarColors.accent.withValues(alpha: .25)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(2, 0, 2, 8), child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.accentText))),
        for (final ch in choices)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: c.bubble,
              borderRadius: BorderRadius.circular(9),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: enabled ? ch.onTap : null,
                child: Opacity(
                  opacity: enabled ? 1 : .45,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(9)),
                    child: Row(children: [
                      if (ch.icon != null) ...[Icon(ch.icon, size: 18, color: c.accentText), const SizedBox(width: 10)],
                      Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(ch.title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                        if (ch.detail.isNotEmpty) Text(ch.detail, style: TextStyle(fontSize: 12, color: c.muted)),
                      ])),
                      if (NetbarScope.of(context).isMobile) Icon(Icons.chevron_right, color: c.faint),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// 居中的灰色提示行（本轮结束、已记入知识库…），可以带一个可点的链接
class SysLine extends StatelessWidget {
  const SysLine({super.key, required this.text, this.icon, this.link, this.onLink, this.tail, this.color, this.trailing});
  final String text;
  final IconData? icon;
  final String? link, tail;
  final VoidCallback? onLink;
  final Color? color;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final col = color ?? c.muted;
    return Center(
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, spacing: 6, children: [
        if (icon != null) Icon(icon, size: 14, color: col),
        Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: col), children: [
          TextSpan(text: text),
          if (link != null)
            WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: onLink,
                  child:
                      MouseRegion(cursor: SystemMouseCursors.click, child: Text(link!, style: TextStyle(fontSize: 12, color: c.accentText, decoration: TextDecoration.underline))),
                )),
          if (tail != null) TextSpan(text: tail),
        ])),
        ?trailing,
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
    return Column(children: [Divider(color: c.line), Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: c.muted))]);
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
    return Align(alignment: Alignment.centerLeft, child: _AiBubbleFrame(child: Text(n.text, style: TextStyle(color: NetbarColors(context).text2))));
  }
}

class ErrorBubble extends StatelessWidget {
  const ErrorBubble(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
            color: NetbarColors.danger.withValues(alpha: .08), border: Border.all(color: NetbarColors.danger.withValues(alpha: .3)), borderRadius: BorderRadius.circular(12)),
        child: SelectableText(text, style: TextStyle(color: c.dangerText, fontSize: 13.5)),
      ),
    );
  }
}

class _AiBubbleFrame extends StatelessWidget {
  const _AiBubbleFrame({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final mobile = NetbarScope.of(context).isMobile;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: mobile && !c.dark ? const Color(0xFFF0F1F4) : c.bubble,
        border: mobile ? null : Border.all(color: c.line),
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), topRight: Radius.circular(14), bottomRight: Radius.circular(14), bottomLeft: Radius.circular(4)),
      ),
      child: child,
    );
  }
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
      Text('${i + 1}/${ids.length}', style: TextStyle(fontSize: 12, color: c.muted, fontFamily: monoFont, fontFamilyFallback: monoFallback)),
      AIconButton(icon: Icons.chevron_right, tooltip: '下一个版本', size: 18, onPressed: idle && i < ids.length - 1 ? () => ctl.stepBranch(t, 1) : null),
    ]);
  }
}

/// 一轮对话
class TurnView extends StatelessWidget {
  const TurnView(this.t, {super.key});
  final Turn t;

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
    final undone = ctl.events.where((e) => e.e == 'memory_undone').map((e) => str(e.d['id'])).toSet();
    for (var i = 0; i < t.events.length; i++) {
      final ev = t.events[i];
      final d = ev.d;
      switch (ev.e) {
        case 'text':
          final sp = splitOptions(str(d['text']));
          if (sp.text.isNotEmpty) children.add(AiMessage(t, sp.text));
          if (sp.options != null && sp.options!.isNotEmpty) {
            final key = '${t.id}:$i';
            final enabled = !ctl.lockedOptions.contains(key) && ctl.path.isNotEmpty && ctl.path.last.id == t.id && !ctl.busy;
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
            color: isUndone ? c.faint : null,
            trailing: isUndone
                ? Text('已撤销', style: TextStyle(fontSize: 12, color: c.faint))
                : AButton(label: '撤销', icon: Icons.undo, small: true, kind: BtnKind.text, onPressed: () => ctl.undoMemory(str(d['id']), t.id)),
          ));
        case 'notice':
          children.add(SysLine(icon: Icons.warning_amber_rounded, text: str(d['text']), color: c.warnText));
        case 'auto_mode':
          children.add(const SysLine(text: '已开启“本次会话始终允许”，高危操作仍需手动确认'));
        case 'done':
          if (d['isError'] == true) children.add(ErrorBubble(d['subtype'] == 'error_max_turns' ? '已达到单次最多步数，可以回复“继续”接着处理。' : '处理过程中出错了。'));
          final cost = d['cost'] is num ? ' · 花费约 \$${(d['cost'] as num).toStringAsFixed(4)}' : '';
          children.add(SysLine(text: '本轮结束 · ${d['turns'] ?? '-'} 步$cost'));
        case 'error':
          children.add(ErrorBubble(str(d['error'])));
      }
    }
    for (final n in ctl.turnNotes[t.id] ?? const <LocalNote>[]) {
      children.add(NoteView(n));
    }
    if (!live) children.add(TurnActions(t));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < children.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 10), child: children[i]),
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
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: const BoxDecoration(
        color: NetbarColors.accentStrong,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(14), topRight: Radius.circular(14), bottomLeft: Radius.circular(14), bottomRight: Radius.circular(4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (t.quote.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(4), border: const Border(left: BorderSide(color: Colors.white70, width: 2))),
            child: Text(t.quote, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: .85))),
          ),
        if (t.skill != null || t.kbRefs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
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
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [for (final a in t.attachments) AttachmentCard(a, onBubble: true)])),
        if (!t.noText) Text(t.text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5)),
      ]),
    );
    void menu() async {
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

    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: s.isMobile ? .86 : .8,
          alignment: Alignment.centerRight,
          child: Align(
              alignment: Alignment.centerRight,
              child: s.isMobile
                  ? GestureDetector(
                      onLongPress: () {
                        HapticFeedback.mediumImpact();
                        menu();
                      },
                      child: bubble)
                  : SelectionArea(child: bubble)),
        ),
      ),
      // 电脑上消息下方一排按钮；手机上长按气泡操作，这里只留版本切换
      Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        if (s.isDesktop) ...[
          AIconButton(
              icon: Icons.copy_outlined,
              tooltip: '复制',
              onPressed: () async {
                await copyText(t.noText ? '' : t.text);
                if (context.mounted) showToast(context, '已复制');
              }),
          if (ctl.canBranch(t)) AIconButton(icon: Icons.edit_outlined, tooltip: '编辑后重新发送', onPressed: ctl.busy ? null : () => ctl.beginEdit(t)),
        ],
        BranchNav(t),
      ]),
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
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: skill ? const Color(0x73A855F7) : Colors.white.withValues(alpha: .16), borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Colors.white))),
          ]),
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

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final field = s.isCupertino
        ? CupertinoTextField(controller: _ctl, focusNode: _focus, minLines: 2, maxLines: 8, padding: const EdgeInsets.all(10))
        : TextField(controller: _ctl, focusNode: _focus, minLines: 2, maxLines: 8, decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true));
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): ctl.cancelEdit,
              if (s.isDesktop) const SingleActivator(LogicalKeyboardKey.enter): () => ctl.submitEdit(widget.t, _ctl.text),
            },
            child: field,
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text('附件、引用和推荐的内容会保留', style: TextStyle(fontSize: 11.5, color: c.muted))),
            AButton(label: '取消', kind: BtnKind.text, small: true, onPressed: ctl.cancelEdit),
            const SizedBox(width: 6),
            AButton(label: '发送', kind: BtnKind.primary, small: true, onPressed: () => ctl.submitEdit(widget.t, _ctl.text)),
          ]),
        ]),
      ),
    );
  }
}

/// AI 的一段回复
class AiMessage extends StatefulWidget {
  const AiMessage(this.t, this.text, {super.key});
  final Turn t;
  final String text;
  @override
  State<AiMessage> createState() => _AiMessageState();
}

class _AiMessageState extends State<AiMessage> {
  String _selected = '';

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final body = MarkdownBody(widget.text, fontSize: s.isMobile ? 15 : 14);
    final bubble = _AiBubbleFrame(child: body);
    if (s.isMobile) {
      return Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
            onLongPress: () {
              HapticFeedback.mediumImpact();
              showReplyMenu(context, widget.t, widget.text);
            },
            child: bubble),
      );
    }
    // 电脑上：选中文字后右键菜单里多一个“引用”
    return Align(
      alignment: Alignment.centerLeft,
      child: SelectionArea(
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
        child: bubble,
      ),
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
    SheetAction(ctl.speakingTurn == t.id ? '停止朗读' : '朗读', 'speak', icon: Icons.volume_up_outlined),
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
    case 'speak':
      await toggleSpeak(context, t, text);
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

Future<void> toggleSpeak(BuildContext context, Turn t, String text) async {
  final s = NetbarScope.read(context);
  final ctl = s.controller;
  if (ctl.speakingTurn == t.id) return s.reader.stop();
  await s.reader.stop();
  ctl.speakingTurn = t.id;
  ctl.refresh();
  try {
    await s.reader.speak(text, () {
      if (ctl.speakingTurn == t.id) {
        ctl.speakingTurn = null;
        ctl.refresh();
      }
    });
  } catch (e) {
    if (context.mounted) showToast(context, e.toString().replaceFirst('Exception: ', ''));
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

/// 一轮结束后的操作：复制、朗读、点赞点踩、重新生成
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
    final buttons = <Widget>[
      if (text.isNotEmpty) ...[
        AIconButton(
            icon: Icons.copy_outlined,
            tooltip: '复制',
            onPressed: () async {
              await copyText(text);
              if (context.mounted) showToast(context, '已复制');
            }),
        AIconButton(
            icon: ctl.speakingTurn == t.id ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
            tooltip: ctl.speakingTurn == t.id ? '停止朗读' : '朗读',
            color: ctl.speakingTurn == t.id ? on : null,
            onPressed: () => toggleSpeak(context, t, text)),
        AIconButton(icon: fb == 'up' ? Icons.thumb_up : Icons.thumb_up_outlined, tooltip: '有帮助', color: fb == 'up' ? on : null, onPressed: () => giveFeedback(context, t, 'up')),
        AIconButton(
            icon: fb == 'down' ? Icons.thumb_down : Icons.thumb_down_outlined,
            color: fb == 'down' ? on : null,
            tooltip: fb == 'down' ? '你点了“没帮助”${str(t.feedback?['reason']).isEmpty ? '' : '：${t.feedback!['reason']}'}（再点一次取消）' : '没帮助',
            onPressed: () => giveFeedback(context, t, 'down')),
      ],
      if (t.kind != 'summarize' && ctl.canBranch(t)) AIconButton(icon: Icons.refresh, tooltip: '重新生成', onPressed: ctl.busy ? null : () => ctl.regenerate(t)),
      if (t.kind == 'summarize') BranchNav(t),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Row(children: buttons);
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
    final tone = result == null
        ? (high ? NetbarColors.danger : NetbarColors.warn)
        : allowed
            ? NetbarColors.ok
            : NetbarColors.danger;
    Widget footer;
    if (result != null) {
      final reason = str(result!['reason']).split('。').first;
      footer = Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(allowed ? Icons.check : Icons.close, size: 16, color: allowed ? c.okText : c.dangerText),
          const SizedBox(width: 4),
          Text(allowed ? '已允许' : '已拒绝', style: TextStyle(fontWeight: FontWeight.w600, color: allowed ? c.okText : c.dangerText)),
        ]),
        if (!allowed && reason.isNotEmpty) Text(reason, style: TextStyle(fontSize: 12, color: c.muted)),
      ]);
    } else if (live) {
      footer = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        AButton(label: '允许执行', kind: BtnKind.primary, small: s.isDesktop, onPressed: () => ctl.approve(str(a['id']), allow: true)),
        if (!high)
          AButton(
              label: '本次会话始终允许',
              small: s.isDesktop,
              onPressed: () async {
                if (await confirmAutoApprove(context)) ctl.approve(str(a['id']), allow: true, always: true);
              }),
        AButton(label: '拒绝', kind: BtnKind.danger, small: s.isDesktop, onPressed: () => ctl.approve(str(a['id']), allow: false)),
        Text('${high ? '高危操作每次都需要手动允许；' : ''}10 分钟内不处理将自动拒绝', style: TextStyle(fontSize: 11.5, color: c.muted)),
      ]);
    } else {
      footer = Text('未处理（对话已中断）', style: TextStyle(fontSize: 12, color: c.muted));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: tone.withValues(alpha: .06), border: Border.all(color: tone.withValues(alpha: .4)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (high) Tag('高危操作', color: c.dangerText) else Icon(Icons.warning_amber_rounded, size: 17, color: c.warnText),
          Text('AI 要执行一个会改动机器的操作：', style: TextStyle(color: c.text2)),
          Text(str(a['tool']), style: TextStyle(fontWeight: FontWeight.w600, color: c.text, fontFamily: monoFont, fontFamilyFallback: monoFallback)),
        ]),
        if (high) Padding(padding: const EdgeInsets.only(top: 6), child: Text('风险：${risks.join('；')}', style: TextStyle(fontSize: 12.5, color: c.dangerText))),
        Container(
          margin: const EdgeInsets.only(top: 8),
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
          child: SingleChildScrollView(
              child: SelectableText(const JsonEncoder.withIndent('  ').convert(a['input']),
                  style: TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: 12, color: c.text2))),
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
