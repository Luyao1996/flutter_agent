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
        _addPicked(f, screenshot: f.name.isEmpty);
      }
      return;
    }
    if (text.length > ChatController.longPaste) return ctl.addPastedText(text);
    ctl.insertText(text);
  }

  // ---------- 附件、语音、技能、AI ----------
  /// 选好的文件加进附件；太大没读进来的显示成失败卡片
  void _addPicked(PickedFile f, {bool screenshot = false}) {
    final b = f.bytes;
    if (b == null) return _ctl!.addOversized(f.name, f.size);
    _ctl!.addFile(b, f.name, screenshot: screenshot);
  }

  Future<void> _pick(Future<List<PickedFile>> Function() picker) async {
    try {
      for (final f in await picker()) {
        if (!mounted) return;
        _addPicked(f);
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
      onPartial: (t) {
        if (mounted) setState(() => _interim = t);
      },
      onFinal: (t) {
        if (!mounted) return;
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

  Future<void> _skillMenu([Rect? anchor]) async {
    final ctl = _ctl!;
    List<SkillItem> list;
    try {
      list = (await loadSkills(ctl)).where((x) => x.enabled).toList();
    } catch (e) {
      if (mounted) showToast(context, e.toString());
      return;
    }
    if (!mounted) return;
    final r = await actionSheet<String>(context, title: '选择要运行的技能', anchor: anchor, message: list.isEmpty ? '还没有可用的技能' : '输入框里的内容会作为补充说明一起发送', actions: [
      for (final x in list) SheetAction(x.name, x.id, icon: Icons.auto_awesome_outlined, subtitle: x.description.isEmpty ? null : x.description),
      const SheetAction('管理技能…', '', icon: Icons.tune),
    ]);
    if (r == null || !mounted) return;
    if (r.isEmpty) return openSkillsPanel(context);
    ctl.runSkill(list.firstWhere((x) => x.id == r));
  }

  /// 切换处理问题的 AI（Claude / Codex / DeepSeek），下一条消息开始生效
  Future<void> _harnessMenu([Rect? anchor]) async {
    final ctl = _ctl!;
    if (ctl.harnesses.isEmpty) await ctl.loadHarnesses();
    if (!mounted) return;
    if (ctl.harnesses.isEmpty) return showToast(context, '没有取到可用的 AI 列表，请稍后再试');
    final r = await actionSheet<String>(context, title: '处理问题的 AI', message: '切换后从下一条消息开始生效', anchor: anchor, actions: [
      for (final h in ctl.harnesses)
        SheetAction(h.name, h.id, enabled: h.available, checked: h.id == ctl.harnessId, subtitle: h.available ? h.desc : '这台服务器上没有安装或没有登录'),
    ]);
    if (r != null && mounted) ctl.setHarness(r);
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
      if (ctl.harnesses.length > 1) SheetAction('切换 AI（现在是 ${ctl.harness?.name ?? '默认'}）', 'harness', icon: Icons.swap_horiz),
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
      case 'harness':
        _harnessMenu();
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
          const _RecDot(),
          const SizedBox(width: 8),
          Expanded(child: Text(_interim.isEmpty ? '正在听，请说话…' : _interim, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: c.muted))),
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
    // 明确写出每一种边框，宿主应用的输入框主题（外框、底色、内边距）不会漏进来
    const none = InputBorder.none;
    final field = Focus(
      onKeyEvent: _onKey,
      child: TextField(
        key: inputKey,
        controller: ctl.input,
        focusNode: _focus,
        minLines: 1,
        maxLines: 8,
        enabled: ctl.config.isValid,
        style: TextStyle(fontSize: NT.fBody, height: 1.5, color: c.text),
        cursorColor: NT.accent,
        decoration: InputDecoration(
          hintText: ctl.placeholder,
          hintStyle: TextStyle(color: c.muted, fontSize: NT.fBody),
          hintMaxLines: 2,
          filled: false,
          isDense: true,
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          border: none,
          enabledBorder: none,
          focusedBorder: none,
          disabledBorder: none,
          errorBorder: none,
          focusedErrorBorder: none,
        ),
      ),
    );
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      // 窄的时候“技能”“总结”“AI”只留图标，底部提示只留最重要的一句
      final compact = w < 640;
      final h = ctl.harness;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...top.map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w)),
        _FocusCard(
          focus: _focus,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            for (final w in extras) Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
            field,
            const SizedBox(height: 6),
            Row(children: [
              AIconButton(icon: Icons.attach_file, tooltip: '添加附件（图片、PDF、文本、Word/Excel/PPT）', onPressed: ctl.config.isValid ? () => _pick(pickFiles) : null),
              AIconButton(
                  icon: _recording ? Icons.mic : Icons.mic_none, color: _recording ? NT.danger : null, tooltip: _recording ? '停止语音输入' : '语音输入', onPressed: _toggleVoice),
              AIconButton(
                  icon: Icons.alternate_email,
                  tooltip: '推荐知识库里的经验、背景知识，或选一个技能运行（也可以直接输入 @）',
                  onPressed: () {
                    ctl.insertAt();
                    _focus.requestFocus();
                  }),
              Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 6), color: c.line),
              Builder(
                  builder: (bctx) => _ToolButton(
                      icon: Icons.auto_awesome_outlined, label: '技能', compact: compact, tooltip: '选一个技能运行', onPressed: () => _skillMenu(rectOf(bctx)))),
              _ToolButton(
                  icon: Icons.summarize_outlined,
                  label: '总结',
                  compact: compact,
                  tooltip: '把这次的处理经验总结到知识库',
                  onPressed: ctl.sessionId == null || ctl.busy ? null : ctl.summarize),
              const Spacer(),
              if (ctl.harnesses.isNotEmpty)
                Builder(
                    builder: (bctx) => _ToolButton(
                        icon: Icons.memory_outlined,
                        label: h?.name ?? 'AI',
                        trailing: Icons.expand_more,
                        compact: compact && w < 400,
                        tooltip: '切换处理问题的 AI',
                        onPressed: () => _harnessMenu(rectOf(bctx)))),
              const SizedBox(width: 6),
              if (ctl.busy) ...[_RoundButton(stop: true, tooltip: '停止', onPressed: ctl.stopByUser), const SizedBox(width: 6)],
              _RoundButton(
                  tooltip: ctl.busy ? '排队发送：AI 正在处理，这一轮结束后接着处理' : '发送（Enter）', queueing: ctl.busy, onPressed: ctl.config.isValid ? ctl.sendComposer : null),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          child: Row(children: [
            if (ctl.config.barKey.isEmpty) ...[
              Icon(Icons.info_outline, size: 12, color: c.warnText),
              const SizedBox(width: 4),
              Flexible(
                  child: Text(compact ? '只使用这台机器的记忆' : '网吧记忆不可用（没有网吧名称），只使用这台机器的记忆',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.warnText))),
              const SizedBox(width: 12),
            ] else
              const Spacer(),
            Flexible(
              child: Text(compact ? 'Enter 发送 · Shift+Enter 换行' : 'Enter 发送 · Shift+Enter 换行 · @ 推荐知识或技能 · 可粘贴截图、拖入文件',
                  textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.faint)),
            ),
          ]),
        ),
      ]);
    });
  }

  // ---------- 手机 ----------
  Widget _mobile(BuildContext context, ChatController ctl, List<Widget> extras, List<Widget> top) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final textStyle = TextStyle(fontSize: NT.fBodyMobile + 1, height: 1.35, color: c.text);
    final field = _contentInsert((cfg) => s.isCupertino
        ? CupertinoTextField(
            key: inputKey,
            controller: ctl.input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            enabled: ctl.config.isValid,
            placeholder: _shortHint(ctl.placeholder),
            placeholderStyle: TextStyle(fontSize: NT.fBodyMobile + 1, color: CupertinoColors.placeholderText.resolveFrom(context)),
            style: textStyle,
            contentInsertionConfiguration: cfg,
            textInputAction: TextInputAction.newline,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: c.card,
              border: Border.all(color: CupertinoColors.separator.resolveFrom(context)),
              borderRadius: BorderRadius.circular(20),
            ),
          )
        : TextField(
            key: inputKey,
            controller: ctl.input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            enabled: ctl.config.isValid,
            style: textStyle,
            contentInsertionConfiguration: cfg,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: _shortHint(ctl.placeholder),
              hintStyle: TextStyle(color: c.muted),
              hintMaxLines: 1,
              filled: true,
              fillColor: c.fill2,
              isDense: true,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: NT.accent.withValues(alpha: .6), width: 1.5)),
            ),
          ));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...top.map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w)),
      for (final w in extras) Padding(padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4), child: w),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: ctl.input,
        builder: (context, value, _) {
          final hasContent = value.text.trim().isNotEmpty || ctl.files.isNotEmpty || ctl.skill != null;
          return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _CircleIcon(icon: s.isCupertino ? CupertinoIcons.add_circled : Icons.add_circle_outline, tooltip: '添加附件、技能、总结', onPressed: ctl.config.isValid ? _plusMenu : null),
            const SizedBox(width: 4),
            Expanded(child: field),
            const SizedBox(width: 4),
            if (ctl.busy) _RoundButton(stop: true, tooltip: '停止', onPressed: ctl.stopByUser, size: 34),
            if (hasContent)
              _RoundButton(tooltip: ctl.busy ? '排队发送' : '发送', queueing: ctl.busy, onPressed: ctl.sendComposer, size: 34)
            else if (!ctl.busy)
              _CircleIcon(
                  icon: _recording ? (s.isCupertino ? CupertinoIcons.stop_circle : Icons.stop_circle_outlined) : (s.isCupertino ? CupertinoIcons.mic : Icons.mic_none),
                  tooltip: _recording ? '停止语音输入' : '语音输入',
                  color: _recording ? NT.danger : null,
                  onPressed: ctl.config.isValid ? _toggleVoice : null),
          ]);
        },
      ),
    ]);
  }
}

/// 手机输入框很窄：提示只留前半句（“描述遇到的问题，例如：……” → “描述遇到的问题”）
String _shortHint(String s) => s.split(RegExp(r'[，,]\s*例如')).first;

/// 录音中的红点（一闪一闪）
class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
      opacity: Tween(begin: .35, end: 1.0).animate(_a),
      child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: NT.danger, shape: BoxShape.circle)));
}

/// 输入卡片工具栏里带文字的小按钮（窄的时候只显示图标）
class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, required this.tooltip, required this.onPressed, this.compact = false, this.trailing});
  final IconData icon;
  final IconData? trailing;
  final String label, tooltip;
  final VoidCallback? onPressed;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final col = onPressed == null ? c.faint : c.muted;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onPressed,
        radius: 6,
        label: compact ? label : null,
        child: Container(
          height: 30,
          constraints: const BoxConstraints(minWidth: 30, maxWidth: 160),
          padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: col),
            if (!compact) ...[
              const SizedBox(width: 4),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: col))),
            ],
            if (trailing != null) Icon(trailing, size: 14, color: col),
          ]),
        ),
      ),
    );
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
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(NT.rLg),
        border: Border.all(color: on ? NT.accent.withValues(alpha: .65) : c.line),
        boxShadow: [
          if (on) BoxShadow(color: NT.accent.withValues(alpha: .14), spreadRadius: 3) else BoxShadow(color: Colors.black.withValues(alpha: c.dark ? .25 : .05), blurRadius: 12, offset: const Offset(0, 2)),
        ],
      ),
      child: widget.child,
    );
  }
}

/// 圆形的发送 / 停止按钮：手机上点击区域 44（图标本身小一些），iOS 按下变淡，没有水波纹
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
        ? NT.danger.withValues(alpha: .12)
        : queueing
            ? NT.accent.withValues(alpha: .16)
            : NT.accent;
    final fg = stop
        ? c.dangerText
        : queueing
            ? c.accentText
            : Colors.white;
    final icon = stop
        ? (s.isCupertino ? CupertinoIcons.stop_fill : Icons.stop_rounded)
        : queueing
            ? (s.isCupertino ? CupertinoIcons.text_badge_plus : Icons.playlist_add)
            : (s.isMobile ? (s.isCupertino ? CupertinoIcons.arrow_up : Icons.arrow_upward) : Icons.arrow_upward_rounded);
    final disabled = onPressed == null;
    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: disabled ? c.fill : bg,
        shape: BoxShape.circle,
        border: stop ? Border.all(color: NT.danger.withValues(alpha: .4)) : null,
      ),
      child: Icon(icon, size: size * .55, color: disabled ? c.faint : fg),
    );
    final box = s.isMobile ? 44.0 : size;
    if (s.isCupertino) {
      return Semantics(
          button: true,
          label: tooltip,
          child: CupertinoButton(padding: EdgeInsets.zero, minimumSize: Size(box, box), onPressed: onPressed, child: circle));
    }
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: box,
        height: box,
        child: Center(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              mouseCursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
              child: circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// 手机输入框两边的图标按钮（＋、麦克风），点击区域 44
class _CircleIcon extends StatelessWidget {
  const _CircleIcon({required this.icon, required this.tooltip, required this.onPressed, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final col = onPressed == null ? c.faint : (color ?? c.muted);
    if (s.isCupertino) {
      return Semantics(
          button: true,
          label: tooltip,
          child: CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size(44, 44), onPressed: onPressed, child: Icon(icon, size: 26, color: col)));
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 24, color: col),
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(44, 44)),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          color: NT.accent.withValues(alpha: .08), borderRadius: BorderRadius.circular(NT.rSm), border: const Border(left: BorderSide(color: NT.accent, width: 3))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.format_quote, size: 16, color: c.accentText),
        const SizedBox(width: 6),
        Expanded(child: Text(ctl.quote, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: c.text2))),
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
    final mobile = NetbarScope.of(context).isMobile;
    Widget chip(IconData icon, String label, Color color, VoidCallback onDelete) => Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: EdgeInsets.fromLTRB(8, mobile ? 6 : 3, 4, mobile ? 6 : 3),
          decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withValues(alpha: .3))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: color))),
            Semantics(
              button: true,
              label: '移除$label',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDelete,
                child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(padding: EdgeInsets.fromLTRB(4, 0, mobile ? 6 : 2, 0), child: Icon(Icons.close, size: mobile ? 16 : 14, color: color))),
              ),
            ),
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
          color: Color.alphaBlend(NT.accent.withValues(alpha: .05), c.card), borderRadius: BorderRadius.circular(NT.rMd), border: Border.all(color: NT.accent.withValues(alpha: .35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.schedule, size: 14, color: c.accentText),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  '排队中 ${ctl.queue.length} 条${ctl.queuePaused ? '（已暂停，点“立即处理”继续）' : ctl.busy ? '，这一轮结束后按顺序处理' : ''}',
                  style: TextStyle(fontSize: NT.fCaption, color: c.accentText))),
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
                  child: Text('${i + 1}', style: TextStyle(fontSize: 11, color: c.muted))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(ctl.queue[i].opts.text.isEmpty ? '（只有附件）' : ctl.queue[i].opts.text,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: c.text2))),
              const SizedBox(width: 6),
              AButton(label: s.isMobile && MediaQuery.sizeOf(context).width < 360 ? '立即' : '立即处理', icon: s.isCupertino ? CupertinoIcons.bolt : Icons.bolt, small: true, kind: BtnKind.primary, onPressed: () => ctl.processNow(ctl.queue[i])),
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
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2), child: Text(_names[x.type] ?? '', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.muted))));
      }
      rows.add(DecoratedBox(
        decoration: BoxDecoration(color: i == ctl.mentionIndex && s.isDesktop ? NT.accent.withValues(alpha: .14) : Colors.transparent, borderRadius: BorderRadius.circular(NT.rSm)),
        child: Pressable(
          radius: NT.rSm,
          label: x.title,
          onTap: () => ctl.pickMention(i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: s.isMobile ? 9 : 6),
            child: Row(children: [
              Icon(_icons[x.type], size: 16, color: c.accentText),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.rich(TextSpan(style: TextStyle(fontSize: s.isMobile ? NT.fBody : NT.fSmall, color: c.text), children: _mark(x.title, ctl.mentionQuery, c.accentText)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (ctl.mentionSnippets[i].isNotEmpty) Text(ctl.mentionSnippets[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
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
          color: c.card,
          borderRadius: BorderRadius.circular(NT.rMd),
          border: Border.all(color: c.line),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: c.dark ? .4 : .12), blurRadius: 18, offset: const Offset(0, 6))]),
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Text(ctl.mentionQuery.isEmpty ? '知识库和技能都还是空的' : '知识库和技能里都没有找到“${ctl.mentionQuery}”', style: TextStyle(fontSize: NT.fCaption, color: c.muted)))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: rows)),
              if (s.isDesktop)
                Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 2), child: Text('↑↓ 选择 · Enter 确认 · Esc 关闭', style: TextStyle(fontSize: 11, color: c.faint))),
            ]),
    );
  }
}
