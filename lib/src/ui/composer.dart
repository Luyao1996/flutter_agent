// 输入区
// 电脑：和网页版一样的输入卡片；Enter 发送、Shift+Enter 换行、Ctrl+V 粘贴截图和文件、空着按 ↑ 编辑上一条
// 手机：左边圆形“＋”（拍照、相册、文件、@、技能、总结），中间圆角输入框，右边没字时是麦克风、有字时是发送
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../models.dart';
import '../panels/skills_panel.dart';
import '../services.dart';
import 'adaptive.dart';
import 'attachments.dart';

/// 输入框的标识（测试、宿主应用要找到输入框时用）
const inputKey = ValueKey('netbar-ops-input');

class Composer extends StatefulWidget {
  const Composer({super.key});
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _focus = FocusNode();
  final _skillKey = GlobalKey();
  String _interim = '';
  bool _recording = false;
  String _prevText = '';
  ChatController? _ctl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ctl = NetbarScope.of(context).controller;
    if (ctl != _ctl) {
      _ctl?.input.removeListener(_watchPaste);
      _ctl = ctl..input.addListener(_watchPaste);
      _prevText = ctl.input.text;
    }
  }

  @override
  void dispose() {
    _ctl?.input.removeListener(_watchPaste);
    _focus.dispose();
    super.dispose();
  }

  /// 一下子粘贴进来很长的文字（手机长按粘贴、电脑右键粘贴）：变成文本附件
  void _watchPaste() {
    final ctl = _ctl!;
    final now = ctl.input.text;
    final prev = _prevText;
    _prevText = now;
    if (now.length - prev.length <= ChatController.longPaste) return;
    var start = 0;
    while (start < prev.length && prev[start] == now[start]) {
      start++;
    }
    final inserted = now.substring(start, start + now.length - prev.length);
    if (inserted.length <= ChatController.longPaste) return;
    _prevText = prev;
    ctl.input.value = TextEditingValue(text: prev, selection: TextSelection.collapsed(offset: start));
    ctl.addPastedText(inserted);
  }

  // ---------- 键盘（电脑） ----------
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ctl = _ctl!;
    final k = e.logicalKey;
    final keys = HardwareKeyboard.instance;
    // 输入法正在组字：交给输入法
    final composing = ctl.input.value.composing.isValid && !ctl.input.value.composing.isCollapsed;
    if (composing) return KeyEventResult.ignored;
    if (ctl.mentionOpen) {
      if (k == LogicalKeyboardKey.arrowDown) {
        ctl.moveMention(1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        ctl.moveMention(-1);
        return KeyEventResult.handled;
      }
      if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab) && ctl.mentionItems.isNotEmpty) {
        ctl.pickMention();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        ctl.closeMention();
        return KeyEventResult.handled;
      }
    }
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && !keys.isShiftPressed) {
      ctl.sendComposer();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && ctl.input.text.isEmpty && ctl.editLast()) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.keyV && (keys.isControlPressed || keys.isMetaPressed) && !keys.isShiftPressed) {
      _paste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ctrl+V：截图、从资源管理器复制的文件变成附件；很长的文字变成文本附件；普通文字照常粘贴
  Future<void> _paste() async {
    final ctl = _ctl!;
    final text = await readClipboardText();
    // 从 Excel、Word 复制的内容同时带文字和图片，按文字处理
    if (text == null || text.isEmpty) {
      final files = await readClipboardFiles();
      for (final f in files) {
        ctl.addFile(f.bytes, f.name, screenshot: f.name.isEmpty);
      }
      return;
    }
    if (text.length > ChatController.longPaste) return ctl.addPastedText(text);
    ctl.insertText(text);
  }

  // ---------- 附件、语音、技能 ----------
  Future<void> _pick(Future<List<PickedFile>> Function() picker) async {
    try {
      for (final f in await picker()) {
        _ctl!.addFile(f.bytes, f.name);
      }
    } catch (e) {
      if (mounted) showToast(context, '没能选择文件：可能是没有给相册或相机权限');
    }
  }

  Future<void> _toggleVoice() async {
    final s = NetbarScope.read(context);
    if (_recording) return s.dictation.stop();
    setState(() {
      _recording = true;
      _interim = '正在打开麦克风…';
    });
    await s.dictation.start(
      onPartial: (t) => setState(() => _interim = t),
      onFinal: (t) {
        if (t.isNotEmpty) _ctl!.insertText(t);
        setState(() => _interim = '');
      },
      onEnd: (err) {
        if (!mounted) return;
        setState(() {
          _recording = false;
          _interim = '';
        });
        if (err != null) showToast(context, err);
      },
    );
  }

  Future<void> _skillMenu() async {
    final ctl = _ctl!;
    List<SkillItem> list;
    try {
      list = (await loadSkills(ctl)).where((x) => x.enabled).toList();
    } catch (e) {
      if (mounted) showToast(context, e.toString());
      return;
    }
    if (!mounted) return;
    RelativeRect? anchor;
    final box = _skillKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box != null && overlay != null) {
      final p = box.localToGlobal(Offset.zero, ancestor: overlay);
      anchor = RelativeRect.fromLTRB(p.dx, p.dy - 8 - 48.0 * (list.length + 1), overlay.size.width - p.dx - box.size.width, overlay.size.height - p.dy);
    }
    final r = await actionSheet<String>(context, title: '选择要运行的技能', anchor: anchor, message: list.isEmpty ? '还没有可用的技能' : '输入框里的内容会作为补充说明一起发送', actions: [
      for (final x in list) SheetAction(x.name, x.id, icon: Icons.auto_awesome_outlined, subtitle: x.description),
      const SheetAction('管理技能…', '', icon: Icons.tune),
    ]);
    if (r == null || !mounted) return;
    if (r.isEmpty) return openSkillsPanel(context);
    ctl.runSkill(list.firstWhere((x) => x.id == r));
  }

  /// 手机上的“＋”菜单
  Future<void> _plusMenu() async {
    final ctl = _ctl!;
    final r = await actionSheet<String>(context, actions: [
      const SheetAction('拍照', 'camera', icon: Icons.photo_camera_outlined),
      const SheetAction('从相册选择', 'gallery', icon: Icons.photo_library_outlined),
      const SheetAction('选择文件', 'file', icon: Icons.attach_file),
      const SheetAction('推荐知识库内容或技能（@）', 'at', icon: Icons.alternate_email),
      const SheetAction('运行技能…', 'skill', icon: Icons.auto_awesome_outlined),
      SheetAction('总结经验到知识库', 'summarize', icon: Icons.summarize_outlined, enabled: ctl.sessionId != null && !ctl.busy),
    ]);
    if (!mounted) return;
    switch (r) {
      case 'camera':
        _pick(() => pickImages(camera: true));
      case 'gallery':
        _pick(() => pickImages(camera: false));
      case 'file':
        _pick(pickFiles);
      case 'at':
        ctl.insertAt();
        _focus.requestFocus();
      case 'skill':
        _skillMenu();
      case 'summarize':
        ctl.summarize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final extras = <Widget>[
      if (ctl.quote.isNotEmpty) _QuoteBox(ctl),
      if (ctl.skill != null || ctl.refs.isNotEmpty) _RefChips(ctl),
      if (ctl.files.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: [for (final f in ctl.files) PendingFileCard(f, key: ValueKey(f.key))]),
      if (_recording)
        Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: NetbarColors.danger, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(_interim.isEmpty ? '正在听，请说话…' : _interim, style: TextStyle(fontSize: 12.5, color: c.muted))),
        ]),
    ];
    final top = <Widget>[
      if (ctl.queue.isNotEmpty) _QueueBox(ctl),
      if (ctl.mentionOpen) _MentionList(ctl),
    ];
    return s.isDesktop ? _desktop(context, ctl, extras, top) : _mobile(context, ctl, extras, top);
  }

  Widget _contentInsert(Widget Function(ContentInsertionConfiguration) build) => build(ContentInsertionConfiguration(
        allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
        onContentInserted: (content) {
          if (content.data != null) _ctl!.addFile(content.data!, '', screenshot: true);
        },
      ));

  // ---------- 电脑 ----------
  Widget _desktop(BuildContext context, ChatController ctl, List<Widget> extras, List<Widget> top) {
    final c = NetbarColors(context);
    final field = Focus(
      onKeyEvent: _onKey,
      child: TextField(
        key: inputKey,
        controller: ctl.input,
        focusNode: _focus,
        minLines: 1,
        maxLines: 8,
        enabled: ctl.config.isValid,
        style: const TextStyle(fontSize: 14, height: 1.5),
        decoration: InputDecoration(hintText: ctl.placeholder, border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 4)),
      ),
    );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...top.map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w)),
      _FocusCard(
        focus: _focus,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          for (final w in extras) Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
          field,
          const SizedBox(height: 4),
          Row(children: [
            AIconButton(icon: Icons.attach_file, tooltip: '添加附件（图片、PDF、文本、Word/Excel/PPT）', onPressed: () => _pick(pickFiles)),
            AIconButton(
                icon: _recording ? Icons.mic : Icons.mic_none, color: _recording ? NetbarColors.danger : null, tooltip: _recording ? '停止语音输入' : '语音输入', onPressed: _toggleVoice),
            AIconButton(
                icon: Icons.alternate_email,
                tooltip: '推荐知识库里的经验、背景知识，或选一个技能运行（也可以直接输入 @）',
                onPressed: () {
                  ctl.insertAt();
                  _focus.requestFocus();
                }),
            Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 4), color: c.line),
            TextButton.icon(
                key: _skillKey,
                onPressed: _skillMenu,
                icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                label: const Text('技能'),
                style: TextButton.styleFrom(foregroundColor: c.muted, visualDensity: VisualDensity.compact)),
            TextButton.icon(
                onPressed: ctl.sessionId == null || ctl.busy ? null : ctl.summarize,
                icon: const Icon(Icons.summarize_outlined, size: 16),
                label: const Text('总结'),
                style: TextButton.styleFrom(foregroundColor: c.muted, visualDensity: VisualDensity.compact)),
            const Spacer(),
            if (ctl.busy) ...[_RoundButton(stop: true, tooltip: '停止', onPressed: ctl.stopByUser), const SizedBox(width: 6)],
            _RoundButton(tooltip: ctl.busy ? '排队发送：AI 正在处理，这一轮结束后接着处理' : '发送（Enter）', queueing: ctl.busy, onPressed: ctl.config.isValid ? ctl.sendComposer : null),
          ]),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 4, 0),
        child: Row(children: [
          if (ctl.config.barKey.isEmpty) Flexible(child: Text('网吧记忆不可用（没有网吧名称），只使用这台机器的记忆', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.warnText))),
          const Spacer(),
          Text('Enter 发送 · Shift+Enter 换行 · 输入 @ 推荐知识或技能 · 可以粘贴截图、拖入文件', style: TextStyle(fontSize: 11, color: c.faint)),
        ]),
      ),
    ]);
  }

  // ---------- 手机 ----------
  Widget _mobile(BuildContext context, ChatController ctl, List<Widget> extras, List<Widget> top) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final field = _contentInsert((cfg) => s.isCupertino
        ? CupertinoTextField(
            key: inputKey,
            controller: ctl.input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            enabled: ctl.config.isValid,
            placeholder: ctl.placeholder,
            contentInsertionConfiguration: cfg,
            textInputAction: TextInputAction.newline,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(color: CupertinoColors.tertiarySystemFill.resolveFrom(context), borderRadius: BorderRadius.circular(20)),
          )
        : TextField(
            key: inputKey,
            controller: ctl.input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            enabled: ctl.config.isValid,
            contentInsertionConfiguration: cfg,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: ctl.placeholder,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          ));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...top.map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w)),
      for (final w in extras) Padding(padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4), child: w),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: ctl.input,
        builder: (context, value, _) {
          final hasContent = value.text.trim().isNotEmpty || ctl.files.isNotEmpty || ctl.skill != null;
          return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _CircleIcon(icon: s.isCupertino ? CupertinoIcons.add : Icons.add, tooltip: '添加', onPressed: ctl.config.isValid ? _plusMenu : null, filled: true),
            const SizedBox(width: 8),
            Expanded(child: field),
            const SizedBox(width: 8),
            if (ctl.busy) ...[_RoundButton(stop: true, tooltip: '停止', onPressed: ctl.stopByUser, size: 38), if (hasContent) const SizedBox(width: 6)],
            if (hasContent)
              _RoundButton(tooltip: ctl.busy ? '排队发送' : '发送', queueing: ctl.busy, onPressed: ctl.sendComposer, size: 38)
            else if (!ctl.busy)
              _CircleIcon(
                  icon: _recording ? Icons.stop : (s.isCupertino ? CupertinoIcons.mic : Icons.mic_none),
                  tooltip: _recording ? '停止语音输入' : '语音输入',
                  color: _recording ? NetbarColors.danger : c.muted,
                  onPressed: ctl.config.isValid ? _toggleVoice : null),
          ]);
        },
      ),
    ]);
  }
}

/// 输入卡片：点进去整张卡片高亮
class _FocusCard extends StatefulWidget {
  const _FocusCard({required this.focus, required this.child});
  final FocusNode focus;
  final Widget child;
  @override
  State<_FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<_FocusCard> {
  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_r);
  }

  void _r() => setState(() {});
  @override
  void dispose() {
    widget.focus.removeListener(_r);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final on = widget.focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
      decoration: BoxDecoration(
        color: c.bubble,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: on ? NetbarColors.accent.withValues(alpha: .6) : c.line),
        boxShadow: on ? [BoxShadow(color: NetbarColors.accent.withValues(alpha: .15), spreadRadius: 3)] : null,
      ),
      child: widget.child,
    );
  }
}

/// 圆形的发送 / 停止按钮
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.onPressed, this.stop = false, this.queueing = false, this.size = 32});
  final String tooltip;
  final VoidCallback? onPressed;
  final bool stop, queueing;
  final double size;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final bg = stop
        ? NetbarColors.danger.withValues(alpha: .12)
        : queueing
            ? NetbarColors.accent.withValues(alpha: .14)
            : NetbarColors.accent;
    final fg = stop
        ? c.dangerText
        : queueing
            ? c.accentText
            : Colors.white;
    final icon =
        stop ? (s.isCupertino ? CupertinoIcons.stop_fill : Icons.stop_rounded) : (s.isMobile ? (s.isCupertino ? CupertinoIcons.arrow_up : Icons.arrow_upward) : Icons.send_rounded);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: onPressed == null ? bg.withValues(alpha: .35) : bg,
        shape: CircleBorder(side: stop ? BorderSide(color: NetbarColors.danger.withValues(alpha: .4)) : BorderSide.none),
        child: InkWell(customBorder: const CircleBorder(), onTap: onPressed, child: SizedBox(width: size, height: size, child: Icon(icon, size: size * .5, color: fg))),
      ),
    );
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon({required this.icon, required this.tooltip, required this.onPressed, this.color, this.filled = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? c.fill : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onPressed, child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 22, color: color ?? c.muted))),
      ),
    );
  }
}

class _QuoteBox extends StatelessWidget {
  const _QuoteBox(this.ctl);
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
          color: NetbarColors.accent.withValues(alpha: .1), borderRadius: BorderRadius.circular(6), border: const Border(left: BorderSide(color: NetbarColors.accent, width: 2))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.format_quote, size: 16, color: c.accentText),
        const SizedBox(width: 6),
        Expanded(child: Text(ctl.quote, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.text2))),
        AIconButton(icon: Icons.close, tooltip: '取消引用', size: 15, onPressed: ctl.clearQuote),
      ]),
    );
  }
}

/// @ 选中的技能和知识库条目，显示成可以删除的标签
class _RefChips extends StatelessWidget {
  const _RefChips(this.ctl);
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    Widget chip(IconData icon, String label, Color color, VoidCallback onDelete) => Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
          decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withValues(alpha: .3))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color))),
            GestureDetector(onTap: onDelete, child: Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.close, size: 14, color: color))),
          ]),
        );
    final purple = c.dark ? const Color(0xFFC084FC) : const Color(0xFF7E22CE);
    return Wrap(spacing: 4, runSpacing: 4, children: [
      if (ctl.skill != null) chip(Icons.auto_awesome_outlined, ctl.skill!.title, purple, ctl.clearSkill),
      for (final r in ctl.refs) chip(r.type == 'background' ? Icons.menu_book_outlined : Icons.lightbulb_outline, r.title, c.accentText, () => ctl.removeRef(r)),
    ]);
  }
}

/// 排队中的消息：每条可以“立即处理”或删除
class _QueueBox extends StatelessWidget {
  const _QueueBox(this.ctl);
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final s = NetbarScope.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
          color: NetbarColors.accent.withValues(alpha: .05), borderRadius: BorderRadius.circular(10), border: Border.all(color: NetbarColors.accent.withValues(alpha: .4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.schedule, size: 14, color: c.accentText),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  '排队中 ${ctl.queue.length} 条${ctl.queuePaused ? '（已暂停，点“立即处理”继续）' : ctl.busy ? '，这一轮结束后按顺序处理' : ''}',
                  style: TextStyle(fontSize: 11.5, color: c.accentText))),
        ]),
        for (var i = 0; i < ctl.queue.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
                  child: Text('${i + 1}', style: TextStyle(fontSize: 10.5, color: c.muted))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(ctl.queue[i].opts.text.isEmpty ? '（只有附件）' : ctl.queue[i].opts.text,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.text2))),
              AButton(label: '立即处理', icon: s.isCupertino ? CupertinoIcons.bolt : Icons.bolt, small: true, kind: BtnKind.primary, onPressed: () => ctl.processNow(ctl.queue[i])),
              AIconButton(icon: Icons.close, tooltip: '删除', size: 16, onPressed: () => ctl.removeQueued(ctl.queue[i])),
            ]),
          ),
      ]),
    );
  }
}

/// 输入框里打 @ 时的候选：经验、背景知识、技能三组，对上的字标亮
class _MentionList extends StatelessWidget {
  const _MentionList(this.ctl);
  final ChatController ctl;
  static const _names = {'experience': '经验', 'background': '背景知识', 'skill': '技能'};
  static const _icons = {'experience': Icons.lightbulb_outline, 'background': Icons.menu_book_outlined, 'skill': Icons.auto_awesome_outlined};

  List<TextSpan> _mark(String title, String q, Color hi) {
    q = q.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (q.isEmpty) return [TextSpan(text: title)];
    final lower = title.toLowerCase();
    final at = lower.indexOf(q);
    final bold = TextStyle(color: hi, fontWeight: FontWeight.w700);
    if (at >= 0) return [TextSpan(text: title.substring(0, at)), TextSpan(text: title.substring(at, at + q.length), style: bold), TextSpan(text: title.substring(at + q.length))];
    final hit = <int>{};
    var i = -1;
    for (final ch in q.split('')) {
      final j = lower.indexOf(ch, i + 1);
      if (j < 0) return [TextSpan(text: title)];
      hit.add(j);
      i = j;
    }
    return [for (var k = 0; k < title.length; k++) TextSpan(text: title[k], style: hit.contains(k) ? bold : null)];
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final s = NetbarScope.of(context);
    final rows = <Widget>[];
    String? last;
    for (var i = 0; i < ctl.mentionItems.length; i++) {
      final x = ctl.mentionItems[i];
      if (x.type != last) {
        last = x.type;
        rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2), child: Text(_names[x.type] ?? '', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.muted))));
      }
      rows.add(Material(
        color: i == ctl.mentionIndex && s.isDesktop ? NetbarColors.accent.withValues(alpha: .14) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => ctl.pickMention(i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: s.isMobile ? 9 : 6),
            child: Row(children: [
              Icon(_icons[x.type], size: 16, color: c.accentText),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(TextSpan(style: TextStyle(fontSize: 13, color: c.text), children: _mark(x.title, ctl.mentionQuery, c.accentText)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (ctl.mentionSnippets[i].isNotEmpty) Text(ctl.mentionSnippets[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.muted)),
              ])),
            ]),
          ),
        ),
      ));
    }
    return Container(
      constraints: BoxConstraints(maxHeight: s.isMobile ? 240 : 300),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: c.bubble,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.line),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 4))]),
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Text(ctl.mentionQuery.isEmpty ? '知识库和技能都还是空的' : '知识库和技能里都没有找到“${ctl.mentionQuery}”', style: TextStyle(fontSize: 12, color: c.muted)))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: rows)),
              if (s.isDesktop)
                Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 2), child: Text('↑↓ 选择 · Enter 确认 · Esc 关闭', style: TextStyle(fontSize: 10.5, color: c.faint))),
            ]),
    );
  }
}
