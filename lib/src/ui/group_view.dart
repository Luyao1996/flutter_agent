// 多人会话的显示：头像、发言人、群聊消息（@ 标亮、@ 我的高亮）、“听到……我来处理”的自动任务卡片、顶部“几人在线”
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../group.dart';
import '../models.dart';
import '../panels/share_panel.dart';
import '../services.dart';
import 'adaptive.dart';

const _avatarColors = [Color(0xFF3B82F6), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF14B8A6), Color(0xFFF97316)];

/// 头像：名字的第一个字 + 按编号算出的颜色（和网页版同一套算法，同一个人颜色一样）
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.id, required this.name, this.size = 22});
  final String id, name;
  final double size;
  @override
  Widget build(BuildContext context) {
    var h = 0;
    for (final c in (id.isNotEmpty ? id : name).codeUnits) {
      h = (h * 31 + c) & 0xFFFFFFFF;
    }
    final first = name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _avatarColors[h % _avatarColors.length], shape: BoxShape.circle),
      child: Text(
        first,
        style: TextStyle(color: Colors.white, fontSize: size * .5, fontWeight: FontWeight.w600, height: 1),
      ),
    );
  }
}

/// 发言人一行：头像、名字、“主人”/“AI”标签，后面可以带一句灰字
class WhoLine extends StatelessWidget {
  const WhoLine(this.who, {super.key, this.hint});
  final Map<String, dynamic> who;
  final String? hint;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final id = str(who['id']);
    final tag = id == 'owner' ? '主人' : (id == 'auto' ? 'AI' : null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(id: id, name: str(who['name']), size: 20),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            str(who['name']).isEmpty ? '成员' : str(who['name']),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NT.fCaption, fontWeight: FontWeight.w600, color: c.text2),
          ),
        ),
        if (tag != null) ...[const SizedBox(width: 4), Tag(tag)],
        if (hint != null) ...[
          const SizedBox(width: 6),
          Text(
            hint!,
            style: TextStyle(fontSize: NT.fCaption, color: c.muted),
          ),
        ],
      ],
    );
  }
}

/// 叫 AI 的消息是别人（被邀请的人、根据群聊自动发起）发的：返回发言人；自己（主人）发的返回 null
Map<String, dynamic>? otherSender(Turn t) {
  final by = t.user['by'];
  if (by is! Map) return null;
  final m = asMap(by);
  return str(m['id']) == 'owner' || str(m['id']).isEmpty ? null : m;
}

/// 文字里的 @某人 标亮
List<TextSpan> markAt(String text, Color color) {
  final out = <TextSpan>[];
  var last = 0;
  for (final m in RegExp(r'@[^\s@，,。：:]{1,20}').allMatches(text)) {
    if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
    out.add(
      TextSpan(
        text: m.group(0),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
    last = m.end;
  }
  if (last < text.length) out.add(TextSpan(text: text.substring(last)));
  return out;
}

/// 群里的一句话（不交给 AI 的）：自己的靠右，别人的靠左并带名字；@ 了我的高亮；语音通话里说的前面带麦克风
class GroupChatMessage extends StatelessWidget {
  const GroupChatMessage(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final from = asMap(d['from']);
    final mine = str(from['id']) == 'owner';
    final atMe = !mine && asList(d['mentions']).any((id) => id == 'owner' || id == 'all');
    final voice = d['voice'] == true;
    final text = str(d['text']);
    final size = s.isMobile ? NT.fBodyMobile : NT.fBody;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? NT.accent.withValues(alpha: c.dark ? .22 : .12) : (atMe ? NT.warn.withValues(alpha: .12) : c.card),
        border: Border.all(color: atMe ? NT.warn.withValues(alpha: .6) : c.line),
        borderRadius: BorderRadius.circular(16).copyWith(topLeft: mine ? null : const Radius.circular(6), topRight: mine ? const Radius.circular(6) : null),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: size, height: 1.5, color: c.text),
          children: [
            if (voice)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.mic_none, size: 15, color: c.muted),
                ),
              ),
            ...markAt(text, c.accentText),
          ],
        ),
      ),
    );
    Future<void> menu() async {
      final r = await actionSheet<String>(context, actions: [const SheetAction('复制', 'copy', icon: Icons.copy_outlined)]);
      if (r == 'copy') {
        await copyText(text);
        if (context.mounted) showToast(context, '已复制');
      }
    }

    return Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (!mine) Padding(padding: const EdgeInsets.only(bottom: 4), child: WhoLine(from)),
        LayoutBuilder(
          builder: (ctx, box) => Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * (s.isMobile ? .86 : .78)),
              child: s.isMobile
                  ? GestureDetector(
                      onLongPress: () {
                        HapticFeedback.mediumImpact();
                        menu();
                      },
                      child: bubble,
                    )
                  : SelectionArea(child: bubble),
            ),
          ),
        ),
      ],
    );
  }
}

/// 根据群聊自动发起的任务：“听到……我来处理”，几秒后开始，谁都能取消
class AutoTaskCard extends StatelessWidget {
  const AutoTaskCard(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    final id = str(d['id']);
    final st = ctl.group.autoTaskStatus(id, ctl.events);
    final live = const ['pending', 'queued', 'running'].contains(st.status);
    final from = str(d['from']);
    final statusText =
        (autoTaskStatusText[st.status] ?? '') +
        (st.status == 'cancelled' && st.by.isNotEmpty ? '（${st.by} 取消的）' : '') +
        (st.status == 'failed' && st.error.isNotEmpty ? '：${st.error}' : '');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(NT.rMd),
        border: Border.all(color: NT.accent.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const WhoLine({'id': 'auto', 'name': aiName}, hint: '旁听到要处理的事'),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: TextStyle(fontSize: NT.fSmall, height: 1.5, color: c.text),
              children: [
                TextSpan(text: from.isEmpty ? '听到群里说的事，我来处理：' : '听到 '),
                if (from.isNotEmpty) ...[
                  TextSpan(
                    text: from,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: ' 说的事，我来处理：'),
                ],
                TextSpan(
                  text: str(d['task']),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (str(d['reason']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                str(d['reason']),
                style: TextStyle(fontSize: NT.fCaption, color: c.muted),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (live) ...[const ASpinner(size: 12), const SizedBox(width: 6)],
                  Flexible(
                    child: Text(
                      statusText,
                      style: TextStyle(fontSize: NT.fCaption, color: st.status == 'failed' ? c.dangerText : c.muted),
                    ),
                  ),
                ],
              ),
              if (live) _CancelButton(id),
            ],
          ),
        ],
      ),
    );
  }
}

class _CancelButton extends StatefulWidget {
  const _CancelButton(this.id);
  final String id;
  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => AButton(
    label: '取消',
    icon: Icons.close,
    small: true,
    kind: BtnKind.danger,
    onPressed: _busy
        ? null
        : () async {
            setState(() => _busy = true);
            await NetbarScope.read(context).controller.group.cancelAutoTask(widget.id);
            if (mounted) setState(() => _busy = false);
          },
  );
}

/// 顶部“几人在线”：有别人加入过或开了邀请时显示，点开分享窗口的“邀请加入”
class RoomBadge extends StatelessWidget {
  const RoomBadge(this.ctl, {super.key});
  final ChatController ctl;
  @override
  Widget build(BuildContext context) {
    final g = ctl.group;
    if (!g.showBadge) return const SizedBox.shrink();
    final c = NetbarColors(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      // 不用 Pressable：iOS 导航栏转场时这里拿不到 NetbarScope
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openSharePanel(context, tab: 'invite'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Semantics(
            button: true,
            label: '${g.onlineCount} 人在线',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: NT.ok.withValues(alpha: .12), borderRadius: BorderRadius.circular(6)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_outlined, size: 13, color: c.okText),
                  const SizedBox(width: 3),
                  Text(
                    '${g.onlineCount} 人在线',
                    style: TextStyle(fontSize: NT.fCaption, color: c.okText, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
