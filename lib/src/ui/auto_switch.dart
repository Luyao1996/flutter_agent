// “始终允许”开关（和网页版对话顶部的开关一致）：默认按链接（客户机链接开、其他关），离开这个对话回到默认
// 开：普通改动操作直接执行，高危操作仍要手动允许（客户机链接开着时所有操作都直接执行）；关：改动机器的操作都要你点“允许”
// 普通链接打开前先看风险说明
// 电脑：顶栏里的开关；手机：标题下面开着时有“始终允许”标记，在“更多”菜单里开关
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import 'adaptive.dart';

String autoTooltip(ChatController ctl) => ctl.autoDefault
    ? '开：所有操作（包括关机、删文件等高危操作）直接执行，不弹确认；关：改动机器的操作都要你点“允许”'
    : '开：普通改动操作直接执行，高危操作仍要你手动允许；关：改动机器的操作都要你点“允许”';

/// 切换开关：普通链接打开前先确认风险
Future<void> toggleAutoApprove(BuildContext context) async {
  final ctl = NetbarScope.read(context).controller;
  final on = !ctl.autoApprove;
  if (on && !ctl.autoDefault && !await confirmAutoApprove(context)) return;
  await ctl.setAutoApprove(on);
}

/// 开启“本次会话始终允许”的风险说明，确认返回 true
Future<bool> confirmAutoApprove(BuildContext context) {
  final c = NetbarColors(context);
  Widget li(String t, {Color? color}) => Padding(
      padding: const EdgeInsets.only(left: 4, top: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('•  ', style: TextStyle(color: color)),
        Expanded(child: Text(t, style: TextStyle(color: color))),
      ]));
  return confirmDialog(
    context,
    title: '开启“本次会话始终允许”',
    ok: '我已了解风险，开启',
    destructive: true,
    content: DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 13.5, height: 1.5),
      textAlign: TextAlign.left,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text('开启后，在这次对话结束前，AI 执行普通的改动操作将不再询问你，会直接在机器上执行，例如：'),
        li('结束进程、启动/停止/重启服务'),
        li('启动程序、运行检测工具、执行命令'),
        li('模拟鼠标点击、键盘输入，操作顾客屏幕上的窗口'),
        li('在顾客屏幕上弹出提示或提问'),
        li('调整音量、分辨率等设置'),
        const SizedBox(height: 8),
        const Text('请了解以下风险：', style: TextStyle(fontWeight: FontWeight.w600)),
        li('AI 可能判断失误，执行了不该执行的操作，打断正在上机的顾客或影响营业。', color: c.dangerText),
        li('系统只能识别常见写法的高危操作，无法保证识别出所有危险操作。比如通过模拟键盘鼠标间接完成的操作，就可能识别不到。', color: c.dangerText),
        li('已经执行的操作可能无法撤销。', color: c.dangerText),
        const SizedBox(height: 8),
        Text('关机、重启、注销、改注册表、删除文件、改系统目录、改账户密码、重置网络、卸载软件、下载并运行脚本等高危操作，仍然每次都需要你手动允许。', style: TextStyle(color: c.okText)),
        const SizedBox(height: 6),
        Text('可以随时关掉“始终允许”开关；离开这个对话后自动恢复默认。', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
      ]),
    ),
  );
}

/// 电脑顶栏里的开关：“始终允许”+ 说明（窄的时候不显示说明）；开着时整块变成醒目的黄色
class AutoSwitch extends StatelessWidget {
  const AutoSwitch(this.ctl, {super.key, this.showHint = true});
  final ChatController ctl;
  final bool showHint;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final on = ctl.autoApprove;
    return Tooltip(
      message: autoTooltip(ctl),
      child: Semantics(
        toggled: on,
        label: '始终允许',
        child: Pressable(
          onTap: () => toggleAutoApprove(context),
          radius: 999,
          child: Container(
            height: 28,
            padding: const EdgeInsets.fromLTRB(4, 0, 10, 0),
            decoration: BoxDecoration(
              color: on ? NT.warn.withValues(alpha: .12) : null,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? NT.warn.withValues(alpha: .5) : Colors.transparent),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Track(on: on),
              const SizedBox(width: 6),
              Text('始终允许', style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: on ? c.warnText : c.text2)),
              if (showHint) ...[
                const SizedBox(width: 6),
                Flexible(child: Text(ctl.autoHint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: on ? c.warnText : c.muted))),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 小开关的样子（关：灰；开：黄）
class _Track extends StatelessWidget {
  const _Track({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 32,
      height: 18,
      padding: const EdgeInsets.all(2),
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: on ? NT.warn.withValues(alpha: .3) : c.fill2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: on ? NT.warn.withValues(alpha: .6) : c.line),
      ),
      child: Container(width: 12, height: 12, decoration: BoxDecoration(color: on ? NT.warn : c.faint, shape: BoxShape.circle)),
    );
  }
}

/// 手机标题下面的标记：开着时显示“始终允许”，点一下关掉/打开
class AutoTag extends StatelessWidget {
  const AutoTag(this.ctl, {super.key});
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    if (!ctl.autoApprove) return const SizedBox.shrink();
    final c = NetbarColors(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Semantics(
        button: true,
        label: '始终允许已开启，点一下可以关掉',
        child: GestureDetector(
          onTap: () => toggleAutoApprove(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: NT.warn.withValues(alpha: .15), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(NetbarScope.of(context).isCupertino ? CupertinoIcons.bolt_fill : Icons.bolt, size: 12, color: c.warnText),
              const SizedBox(width: 2),
              Text('始终允许', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.warnText)),
            ]),
          ),
        ),
      ),
    );
  }
}
