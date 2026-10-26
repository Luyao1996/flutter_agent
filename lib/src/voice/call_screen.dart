// 全屏语音通话界面（像微信）+ 收起后的小状态条。两端（手机 / PC）共用，布局自适应。
// 收起后通话不中断，回到普通聊天界面；小状态条上的“展开”又能回到通话界面。
import 'package:flutter/material.dart';

import '../ui/adaptive.dart';
import 'call_orb.dart';
import 'voice_call.dart';

OrbPalette _palette(NetbarColors c) => OrbPalette(accent: NT.accent, danger: NT.danger, warn: NT.warn, idle: c.faint);

/// 以整页路由打开通话界面（在组件自己的 Navigator 里，返回键/返回手势 = 收起，通话继续）
Future<void> showCallScreen(BuildContext context) {
  final voice = NetbarScope.read(context).controller.voice;
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, _, _) => const CallScreen(),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  )).then((_) {
    if (voice.on) voice.minimize(); // 返回手势关掉全屏：算作收起
  });
}

/// 全屏通话界面（由上层 Stack 在 voice.on && voice.expanded 时放到最上层）
class CallScreen extends StatelessWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = NetbarScope.of(context).controller.voice;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final c = NetbarColors(context);
        final base = c.background;
        return Material(
          color: base,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(NT.accent.withValues(alpha: c.dark ? 0.16 : 0.08), base),
                  base,
                ],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(children: [
                  _top(context, voice, c),
                  Expanded(child: _Bubbles(voice: voice)),
                  _stage(voice, c),
                  const SizedBox(height: 20),
                  _controls(context, voice, c),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _top(BuildContext context, VoiceCallController voice, NetbarColors c) {
    return Row(children: [
      _roundBtn(c, Icons.keyboard_arrow_down, '收起（通话不会中断）', () => Navigator.of(context).maybePop()),
      Expanded(
        child: Column(children: [
          Text(voice.machineLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
          Text('语音通话', style: TextStyle(fontSize: 12, color: c.muted)),
        ]),
      ),
      _roundBtn(c, Icons.graphic_eq, '换一个说话的声音', () => _pickVoice(context, voice)),
    ]);
  }

  Widget _stage(VoiceCallController voice, NetbarColors c) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: voice.tapMain,
      child: Column(children: [
        CallOrb(phase: voice.phase, palette: _palette(c)),
        const SizedBox(height: 16),
        Text(voice.stateLabel, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text)),
        const SizedBox(height: 6),
        SizedBox(
          height: 18,
          child: Text(voice.phaseHint, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.muted)),
        ),
      ]),
    );
  }

  Widget _controls(BuildContext context, VoiceCallController voice, NetbarColors c) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _ctrl(c, voice.muted ? Icons.mic_off : Icons.mic, voice.muted ? '已静音' : '麦克风', voice.muted ? NT.danger : null, voice.toggleMute),
      const SizedBox(width: 56),
      _ctrl(c, Icons.call_end, '挂断', NT.danger, () {
        voice.exit();
        Navigator.of(context).maybePop();
      }, filled: true),
    ]);
  }

  Widget _ctrl(NetbarColors c, IconData icon, String label, Color? accent, VoidCallback onTap, {bool filled = false}) {
    final bg = filled ? (accent ?? NT.danger) : c.fill;
    final fg = filled ? Colors.white : (accent ?? c.text2);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: bg,
        shape: CircleBorder(side: filled ? BorderSide.none : BorderSide(color: c.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 60, height: 60, child: Icon(icon, size: 26, color: fg)),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
    ]);
  }

  Widget _roundBtn(NetbarColors c, IconData icon, String tooltip, VoidCallback onTap) {
    return Material(
      color: c.fill,
      shape: CircleBorder(side: BorderSide(color: c.line)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(message: tooltip, child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 22, color: c.text2))),
      ),
    );
  }

  Future<void> _pickVoice(BuildContext context, VoiceCallController voice) async {
    if (voice.voices.isEmpty) {
      voice.chat.toast('连上以后才能选音色');
      return;
    }
    final c = NetbarColors(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.background,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('说话的声音', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted))),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final v in voice.voices)
                  ListTile(
                    leading: Icon(v.id == voice.voiceId ? Icons.check_circle : Icons.circle_outlined, color: v.id == voice.voiceId ? NT.accent : c.faint),
                    title: Text('${v.gender} · ${v.name}', style: TextStyle(color: c.text, fontWeight: v.id == voice.voiceId ? FontWeight.w600 : FontWeight.normal)),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      voice.setVoice(v.id);
                    },
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// 气泡区：最近几句对话，显示几秒自动淡出；顶部有渐隐遮罩
class _Bubbles extends StatelessWidget {
  const _Bubbles({required this.voice});
  final VoiceCallController voice;

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final items = voice.bubbles.where((b) => !b.pending).toList();
    final column = Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in items)
          Padding(
            key: ValueKey(b.id),
            padding: const EdgeInsets.only(bottom: 10),
            child: AnimatedOpacity(
              opacity: b.gone ? 0 : 1,
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOut,
              child: Align(
                alignment: b.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: _bubble(c, b.isUser, b.text),
              ),
            ),
          ),
      ],
    );
    // 顶部渐隐，气泡多了往上淡出不突兀
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
        stops: [0.0, 0.12],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 16),
        physics: const NeverScrollableScrollPhysics(),
        child: column,
      ),
    );
  }

  Widget _bubble(NetbarColors c, bool isUser, String text) {
    final bg = isUser ? NT.accent : c.raised;
    final fg = isUser ? Colors.white : c.text;
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      margin: EdgeInsets.only(left: isUser ? 48 : 0, right: isUser ? 0 : 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 6),
          bottomRight: Radius.circular(isUser ? 6 : 18),
        ),
        border: isUser ? null : Border.all(color: c.line),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: c.dark ? 0.3 : 0.1), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Text(text, style: TextStyle(fontSize: 15, height: 1.45, color: fg)),
    );
  }
}

/// 收起后的小状态条（放在输入框上方）：状态 + 展开 + 麦克风 + 结束
class CompactVoiceBar extends StatelessWidget {
  const CompactVoiceBar({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = NetbarScope.of(context).controller.voice;
    final c = NetbarColors(context);
    final accent = switch (voice.phase) {
      VoicePhase.listen || VoicePhase.heard => NT.danger,
      VoicePhase.approval => NT.warn,
      VoicePhase.idle || VoicePhase.muted => c.faint,
      _ => NT.accent,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: NT.accent.withValues(alpha: c.dark ? 0.14 : 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NT.accent.withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(voice.stateLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
            if (voice.phaseHint.isNotEmpty)
              Text(voice.phaseHint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
          ]),
        ),
        IconButton(
            icon: const Icon(Icons.open_in_full, size: 18),
            tooltip: '展开通话界面',
            color: c.text2,
            onPressed: () {
              voice.openScreen();
              showCallScreen(context);
            }),
        IconButton(
            icon: Icon(voice.muted ? Icons.mic_off : Icons.mic, size: 18),
            tooltip: voice.muted ? '打开麦克风' : '关闭麦克风',
            color: voice.muted ? NT.danger : c.text2,
            onPressed: voice.toggleMute),
        TextButton.icon(
          onPressed: voice.exit,
          icon: const Icon(Icons.call_end, size: 16),
          label: const Text('结束'),
          style: TextButton.styleFrom(foregroundColor: NT.danger, padding: const EdgeInsets.symmetric(horizontal: 8)),
        ),
      ]),
    );
  }
}
