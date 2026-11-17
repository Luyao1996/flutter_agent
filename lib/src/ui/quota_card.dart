// AI 额度用完 / 接口出错，后台自动换 AI 时对话里的提示（和网页版 quotaCard 一致）
// retry != false：后台已经换成下一个 AI 把这一轮重做了，只留一行提示
// retry == false：这一轮没做完（已经做了一半不能从头重来，或者能用的 AI 都用不了），显示一张醒目的提示卡，
// 最显眼的是“用 xx 重试这条消息”按钮：用新的 AI 把这条消息重新发一次，失败的那一轮留在 1/2 分支里
import 'package:flutter/material.dart';

import '../harness.dart';
import '../models.dart';
import 'adaptive.dart';

String _name(String id) => harnessNames[id] ?? id;

class QuotaCard extends StatelessWidget {
  const QuotaCard(this.t, this.d, {super.key, required this.canRetry});
  final Turn t;
  final Map<String, dynamic> d;

  /// 只有当前版本的最后一轮、而且这一轮已经结束时才能重试
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    final from = str(d['from']).isEmpty ? 'AI' : _name(str(d['from']));
    final to = str(d['to']).isEmpty ? '' : _name(str(d['to']));
    final why = switch (str(d['kind'])) { 'api' => '接口出错了', 'quota' => '的额度用完了', _ => '出错了' };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: NT.warn.withValues(alpha: .08), borderRadius: BorderRadius.circular(NT.rMd), border: Border.all(color: NT.warn.withValues(alpha: .45))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.warning_amber_rounded, size: 17, color: c.warnText)),
          const SizedBox(width: 7),
          Expanded(child: Text('$from $why，这一轮没做完', style: TextStyle(fontSize: NT.fBody, fontWeight: FontWeight.w700, color: c.warnText))),
        ]),
        const SizedBox(height: 6),
        Text(to.isNotEmpty ? '已自动把 AI 换成 $to。点下面的按钮，就能用它把这条消息重新发一次，接着往下做。' : '能用的 AI 都试过了，现在都暂时用不了，过一会儿再试。',
            style: TextStyle(fontSize: NT.fSmall, height: 1.6, color: c.text2)),
        if (to.isNotEmpty && canRetry) ...[
          const SizedBox(height: 10),
          AButton(label: '用 $to 重试这条消息', icon: Icons.refresh, kind: BtnKind.primary, onPressed: ctl.busy ? null : () => ctl.regenerate(t)),
        ],
        if (str(d['reason']).isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText('$from 的报错：${str(d['reason'])}', style: TextStyle(fontSize: 11, color: c.muted)),
        ],
      ]),
    );
  }
}
