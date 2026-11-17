// 目标模式的界面：输入框上方的目标栏（目标、状态、进度，暂停/继续/再做几轮/修改/清除），设定或修改目标的窗口
// 对话里的提示：目标状态变化的一句话（完成、卡住、暂停、轮数用完）
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../goal.dart';
import 'adaptive.dart';

const _violet = Color(0xFF8B5CF6);

IconData goalIcon(BuildContext context) => NetbarScope.of(context).isCupertino ? CupertinoIcons.scope : Icons.track_changes;

class GoalBar extends StatelessWidget {
  const GoalBar(this.ctl, {super.key});
  final ChatController ctl;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final gs = ctl.goal;
    final g = gs.goal!;
    final running = ctl.busy;
    final (Color accent, Color border) = switch (g.status) {
      'complete' => (NT.ok, NT.ok.withValues(alpha: .4)),
      'blocked' || 'budget_limited' => (NT.warn, NT.warn.withValues(alpha: .45)),
      'paused' => (_violet, _violet.withValues(alpha: .2)),
      _ => (_violet, _violet.withValues(alpha: .35)),
    };
    final mins = (g.timeUsedMs / 60000).round();
    final progress = '${running ? '正在做第 ${g.turnsUsed + 1} 轮' : '已做 ${g.turnsUsed} 轮'}，最多 ${g.maxTurns} 轮${mins > 0 ? ' · 用时约 $mins 分钟' : ''}';
    final status = gs.counting
        ? '${gs.left} 秒后自动继续'
        : g.active && !running && gs.hold
            ? '等你点“继续推进”'
            : goalStatusNames[g.status] ?? g.status;
    final sub = g.status == 'complete' ? g.summary : (!g.active ? g.reason : '');
    final buttons = <Widget>[
      if (g.active && !running && !gs.counting) AButton(label: '继续推进', icon: Icons.play_arrow, small: true, kind: BtnKind.primary, onPressed: gs.continueNow),
      if (g.active) AButton(label: '暂停', icon: Icons.pause, small: true, onPressed: gs.pause),
      if (g.status == 'paused' || g.status == 'blocked') AButton(label: '继续', icon: Icons.play_arrow, small: true, kind: BtnKind.primary, onPressed: gs.resume),
      if (g.status == 'budget_limited')
        AButton(label: '再做 $goalDefaultTurns 轮', icon: Icons.add, small: true, kind: BtnKind.primary, onPressed: () => gs.resume(extend: true)),
      AIconButton(icon: Icons.edit_outlined, tooltip: '修改目标', size: 16, onPressed: () => openGoalDialog(context)),
      AIconButton(icon: Icons.close, tooltip: '清除目标', size: 16, onPressed: () => _clear(context)),
    ];
    final statusChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: c.fill2, borderRadius: BorderRadius.circular(999)),
      child: Text(status, style: TextStyle(fontSize: 11, color: c.muted)),
    );
    return LayoutBuilder(builder: (context, box) {
      // 宽的时候按钮和目标在同一行，窄的时候放到下面一行
      final wide = s.isDesktop && box.maxWidth >= 560;
      return Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(color: accent.withValues(alpha: .06), borderRadius: BorderRadius.circular(10), border: Border.all(color: border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(goalIcon(context), size: 15, color: accent),
            const SizedBox(width: 6),
            Text('目标', style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.text)),
            const SizedBox(width: 8),
            Expanded(
                child: Tooltip(
                    message: g.objective, child: Text(g.objective, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: c.text2)))),
            const SizedBox(width: 6),
            statusChip,
            if (wide) ...[const SizedBox(width: 4), ...buttons],
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 21, top: 2),
            child: Text('$progress${sub.isNotEmpty ? ' · $sub' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.muted)),
          ),
          if (!wide) Padding(padding: const EdgeInsets.only(left: 16, top: 2), child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: buttons)),
        ]),
      );
    });
  }

  Future<void> _clear(BuildContext context) async {
    if (await confirmDialog(context, title: '清除这个目标？', message: 'AI 不会再自动接着做，对话记录不受影响。', ok: '清除', destructive: true)) await ctl.goal.clear();
  }
}

/// 设定或修改目标的窗口：没有目标（或已完成）时是设定，输入框里写了字就带进来；有没完成的目标时是修改
Future<void> openGoalDialog(BuildContext context) async {
  final s = NetbarScope.read(context);
  final ctl = s.controller;
  final editing = ctl.goal.unfinished;
  final text = TextEditingController(text: editing ? ctl.goal.goal!.objective : ctl.input.text.trim());
  var turns = goalDefaultTurns;
  final title = editing ? '修改目标' : '设定目标';
  const hint = '写清楚最后要达到什么结果。AI 会一轮接一轮自动做下去：每做完一轮自动接着做，直到它逐条核对、确认真的做到了才停；卡住需要你帮忙、或者用完轮数也会停下。需要你允许的操作照常会弹窗确认。';
  Widget body(BuildContext ctx, StateSetter setState) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(hint, style: TextStyle(fontSize: NT.fCaption, color: NetbarColors(ctx).muted, height: 1.5)),
        const SizedBox(height: 10),
        AField(controller: text, hint: '例如：12号机开机后游戏菜单打不开，修好它，并确认菜单能正常打开、能进游戏', minLines: 4, maxLines: 8, maxLength: 2000, autofocus: true),
        if (!editing) ...[
          const SizedBox(height: 10),
          Text('最多自动做几轮', style: TextStyle(fontSize: NT.fCaption, color: NetbarColors(ctx).muted)),
          const SizedBox(height: 6),
          ASegmented<int>(value: turns, segments: {for (final n in goalTurnChoices) n: '$n'}, onChanged: (v) => setState(() => turns = v)),
        ],
      ]);
  void ok(BuildContext ctx) {
    if (text.text.trim().isEmpty) return showToast(ctx, '请写下要达成的目标');
    Navigator.pop(ctx);
    ctl.goal.submit(text.text, maxTurns: turns);
  }

  if (s.isCupertino) {
    await showCupertinoDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setState) => CupertinoAlertDialog(
                  title: Text(title),
                  content: Material(type: MaterialType.transparency, child: Padding(padding: const EdgeInsets.only(top: 8), child: body(ctx, setState))),
                  actions: [
                    CupertinoDialogAction(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                    CupertinoDialogAction(isDefaultAction: true, onPressed: () => ok(ctx), child: Text(editing ? '保存' : '开始')),
                  ],
                )));
  } else {
    await showDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => s.copyWith(
            child: StatefulBuilder(
                builder: (ctx, setState) => AlertDialog(
                      title: Row(children: [Icon(goalIcon(ctx), size: 20, color: _violet), const SizedBox(width: 8), Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))]),
                      scrollable: true,
                      content: SizedBox(width: 480, child: body(ctx, setState)),
                      actions: [
                        AButton(label: '取消', kind: BtnKind.text, onPressed: () => Navigator.pop(ctx)),
                        AButton(label: editing ? '保存' : '开始', icon: Icons.play_arrow, kind: BtnKind.primary, onPressed: () => ok(ctx)),
                      ],
                    ))));
  }
  text.dispose();
}
