// 输入框上方的进度条（一行）：“Claude 正在思考 / 正在执行 PowerShell 命令 / 在等你确认”+ 最新内容 + 已用时间，
// 右边“查看详情”和“停止”；这一轮结束后变成灰色的一行，写明思考了几段、调用了几次工具
// “查看详情”打开“AI 的处理过程”：每段思考、每次调用的工具（中文名称），点开能看参数和结果；
// 处理中只追加新的步骤，已经展开的内容和滚动位置不会被打断
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../harness.dart';
import '../models.dart';
import '../progress.dart';
import 'adaptive.dart';
import 'markdown.dart';

/// 进度条显示哪一轮：处理中是正在处理的这一轮（还没开始时没有），否则是当前版本的最后一轮
Turn? progressTurn(ChatController ctl) => ctl.busy ? (ctl.liveTurn == null ? null : ctl.tree.turns[ctl.liveTurn]) : ctl.path.lastOrNull;

/// 这一轮是哪个 AI 在处理（中途自动换过 AI 的，按换后的）
String progressAi(ChatController ctl, Turn? t) {
  var id = ctl.harnessId;
  if (t != null) {
    final sw = t.events.where((e) => e.e == 'harness_switch' && str(e.d['to']).isNotEmpty).lastOrNull;
    id = sw != null ? str(sw.d['to']) : (str(t.user['harness']).isEmpty ? 'claude' : str(t.user['harness']));
  }
  return ctl.harnesses.where((h) => h.id == id).firstOrNull?.name ?? harnessNames[id] ?? 'AI';
}

List<ThinkStep> progressSteps(ChatController ctl) => thinkSteps(progressTurn(ctl), live: ctl.busy ? ctl.thinkLive : '');

class RunBar extends StatefulWidget {
  const RunBar({super.key});
  @override
  State<RunBar> createState() => _RunBarState();
}

class _RunBarState extends State<RunBar> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final running = ctl.busy;
    // 处理中每秒刷新一次用时
    if (running && _tick == null) _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    if (!running && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
    final steps = progressSteps(ctl);
    if (!running && steps.isEmpty) return const SizedBox.shrink();
    final line = progressLine(running: running, ai: progressAi(ctl, progressTurn(ctl)), steps: steps, act: ctl.act);
    final started = ctl.runStartedAt;
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 480;
      Widget btn(IconData icon, String label, VoidCallback onTap, {Color? color}) => Tooltip(
            message: label,
            child: Pressable(
              onTap: onTap,
              radius: 999,
              label: narrow ? label : null,
              child: Container(
                height: 26,
                padding: EdgeInsets.symmetric(horizontal: narrow ? 7 : 10),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: color?.withValues(alpha: .45) ?? c.line)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 14, color: color ?? c.muted),
                  if (!narrow) ...[const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: NT.fCaption, color: color ?? c.text2))],
                ]),
              ),
            ),
          );
      final n = steps.length;
      return Semantics(
        container: true,
        liveRegion: true,
        label: '${line.title} ${line.detail}',
        child: Container(
          height: s.isDesktop ? 34 : 38,
          padding: const EdgeInsets.fromLTRB(12, 0, 5, 0),
          decoration: BoxDecoration(
            color: running ? NT.accent.withValues(alpha: .08) : c.fill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: running ? NT.accent.withValues(alpha: .35) : c.line),
          ),
          child: Row(children: [
            if (running) const ASpinner(size: 12) else Icon(s.isCupertino ? CupertinoIcons.lightbulb : Icons.lightbulb_outline, size: 14, color: c.warnText),
            const SizedBox(width: 8),
            if (narrow)
              Expanded(child: _title(line.title, running, c))
            else ...[
              ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * .45), child: _title(line.title, running, c)),
              const SizedBox(width: 8),
              Expanded(child: Text(line.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
            ],
            if (running && started != null) ...[
              const SizedBox(width: 8),
              Text(fmtElapsed(DateTime.now().difference(started)), style: TextStyle(fontSize: 11, color: c.accentText, fontFeatures: const [FontFeature.tabularFigures()])),
            ],
            const SizedBox(width: 8),
            btn(s.isCupertino ? CupertinoIcons.eye : Icons.visibility_outlined, n > 0 ? '查看详情 · $n 步' : '查看详情', () => openThinkDetails(context)),
            if (running && ctl.taskId != null) ...[
              const SizedBox(width: 4),
              btn(s.isCupertino ? CupertinoIcons.stop_fill : Icons.stop_rounded, '停止', ctl.stopByUser, color: c.dangerText),
            ],
          ]),
        ),
      );
    });
  }

  Widget _title(String t, bool running, NetbarColors c) => Text(t,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: NT.fSmall, fontWeight: running ? FontWeight.w600 : FontWeight.w500, color: running ? c.text : c.muted));
}

/// “AI 的处理过程”：电脑上是居中的对话框，手机上推入整页
Future<void> openThinkDetails(BuildContext context) => pushPanel<void>(context, title: 'AI 的处理过程', width: 760, height: 680, builder: (_) => const ThinkDetails());

class ThinkDetails extends StatefulWidget {
  const ThinkDetails({super.key});
  @override
  State<ThinkDetails> createState() => _ThinkDetailsState();
}

class _ThinkDetailsState extends State<ThinkDetails> {
  final _scroll = ScrollController();
  int _count = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    final t = progressTurn(ctl);
    final steps = progressSteps(ctl);
    final running = ctl.busy;
    // 第一次打开滚到最后；之后只有原来就在最下面时，新步骤出来才跟着往下滚
    if (steps.length != _count) {
      final atEnd = _count < 0 || !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 30;
      _count = steps.length;
      if (atEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }
    final hint = steps.isNotEmpty
        ? '这一轮共 ${steps.length} 步${running ? '，AI 还在处理，会继续增加' : ''}。点工具下面的灰字能看参数和结果；思考内容是 AI 自己整理的摘要。'
        : running
            ? 'AI 刚开始处理，还没有内容。'
            : '这一轮没有记录到处理过程。';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 6), child: Text(hint, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
      Expanded(
        child: ListView.separated(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: steps.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          // 按“哪一轮第几步”保持每一步自己的展开状态：新步骤追加进来时，已经展开的不会被收起
          itemBuilder: (_, i) => _StepCard(steps[i], i, key: ValueKey('${t?.id}:$i')),
        ),
      ),
    ]);
  }
}

class _StepCard extends StatefulWidget {
  const _StepCard(this.x, this.index, {super.key});
  final ThinkStep x;
  final int index;
  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final x = widget.x;
    final idx = Text('${widget.index + 1}', style: TextStyle(fontSize: 10.5, color: c.faint));
    final box = BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: x.live ? NT.accent : c.line));
    if (x.isThink) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: box,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(s.isCupertino ? CupertinoIcons.lightbulb : Icons.lightbulb_outline, size: 14, color: c.warnText),
            const SizedBox(width: 6),
            Text(x.live ? '思考（正在想）' : '思考', style: TextStyle(fontSize: NT.fCaption, fontWeight: FontWeight.w600, color: c.muted)),
            const Spacer(),
            idx,
          ]),
          const SizedBox(height: 4),
          SelectionArea(child: MarkdownBody(x.text, fontSize: 13)),
        ]),
      );
    }
    final arg = oneLine(toolArg(x.input));
    final hasMore = arg.isNotEmpty || x.result.isNotEmpty;
    String pretty() {
      try {
        return const JsonEncoder.withIndent('  ').convert(x.input);
      } catch (_) {
        return '${x.input}';
      }
    }

    Widget pre(String t) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(6)),
          child: SingleChildScrollView(child: SelectableText(t, style: monoStyle(size: 11.5, color: c.text2))),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: box,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (x.state == 'run')
            const ASpinner(size: 12)
          else
            Icon(x.state == 'err' ? Icons.close : Icons.check, size: 14, color: x.state == 'err' ? c.dangerText : c.okText),
          const SizedBox(width: 6),
          Expanded(
              child: Row(children: [
            Flexible(child: Text(toolLabel(x.name), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.text2))),
            if (x.machine.isNotEmpty) Text('［${x.machine}］', style: monoStyle(size: 11.5, color: c.muted)),
          ])),
          idx,
        ]),
        if (hasMore)
          Pressable(
            onTap: () => setState(() => _open = !_open),
            label: _open ? '收起参数和结果' : '查看参数和结果',
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 14, color: c.muted),
                Expanded(
                    child: Text(arg.isEmpty ? '查看结果' : (arg.length > 200 ? arg.substring(0, 200) : arg),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(size: 11.5, color: c.muted))),
              ]),
            ),
          ),
        if (_open && arg.isNotEmpty) pre(pretty()),
        if (_open && x.result.isNotEmpty) ...[
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('结果', style: TextStyle(fontSize: 11, color: c.muted))),
          pre(x.result),
        ],
      ]),
    );
  }
}
