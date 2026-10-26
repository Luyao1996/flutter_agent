// 声波球：随通话状态变色、变动。为了不吃 CPU：
//  - 只用一个 AnimationController，画在一个 RepaintBoundary 里的 CustomPainter，每帧只重绘这个球，不连累气泡和整棵树；
//  - 波形和光环用数学函数算，不堆多个 widget 动画；
//  - 不需要动的状态（等确认、暂停、静音）直接停掉控制器，不空转；
//  - 收起通话界面时整个球不在控件树里（父级不构建），完全没有开销。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'voice_call.dart';

class CallOrb extends StatefulWidget {
  const CallOrb({super.key, required this.phase, required this.palette, this.size = 120});
  final VoicePhase phase;
  final OrbPalette palette;
  final double size;

  @override
  State<CallOrb> createState() => _CallOrbState();
}

class OrbPalette {
  const OrbPalette({required this.accent, required this.danger, required this.warn, required this.idle});
  final Color accent, danger, warn, idle;
}

class _CallOrbState extends State<CallOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  static const _moving = {VoicePhase.connecting, VoicePhase.listen, VoicePhase.heard, VoicePhase.think, VoicePhase.speak, VoicePhase.busy};

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(CallOrb old) {
    super.didUpdateWidget(old);
    if (old.phase != widget.phase) _sync();
  }

  // 需要动才让控制器转，否则停下，省 CPU
  void _sync() {
    final move = _moving.contains(widget.phase);
    if (move && !_c.isAnimating) {
      _c.repeat();
    } else if (!move && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _OrbPainter(widget.phase, widget.palette, _c.value),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.phase, this.pal, this.t);
  final VoicePhase phase;
  final OrbPalette pal;
  final double t; // 0..1 动画进度

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final coreR = size.width * 0.4;

    final color = switch (phase) {
      VoicePhase.listen || VoicePhase.heard => pal.danger,
      VoicePhase.approval => pal.warn,
      VoicePhase.idle || VoicePhase.muted => pal.idle,
      _ => pal.accent,
    };

    // 扩散光环（正在听/在听你说）
    if (phase == VoicePhase.listen || phase == VoicePhase.heard) {
      final p = Paint()..color = color.withValues(alpha: (1 - t) * 0.5);
      canvas.drawCircle(center, coreR + t * size.width * 0.16, p);
    }

    // 核心圆：想/连接/忙时做呼吸
    var coreAlpha = 1.0;
    if (phase == VoicePhase.think || phase == VoicePhase.connecting) {
      coreAlpha = 0.55 + 0.45 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
    } else if (phase == VoicePhase.busy) {
      coreAlpha = 0.6 + 0.4 * (0.5 - 0.5 * math.cos(t * math.pi)); // 慢一点
    }
    final glow = Paint()
      ..color = color.withValues(alpha: 0.35 * coreAlpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    if (phase != VoicePhase.idle && phase != VoicePhase.muted) canvas.drawCircle(center, coreR, glow);
    canvas.drawCircle(center, coreR, Paint()..color = color.withValues(alpha: coreAlpha));

    // 中间的 5 根竖条
    _bars(canvas, center, size, coreAlpha);
  }

  void _bars(Canvas canvas, Offset center, Size size, double coreAlpha) {
    const n = 5;
    final barW = size.width * 0.042;
    final gap = barW * 1.6;
    final totalW = n * barW + (n - 1) * gap;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: coreAlpha)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barW;
    final base = size.height * 0.12; // 最短
    final maxH = size.height * 0.30; // 最长
    for (var i = 0; i < n; i++) {
      double h;
      if (phase == VoicePhase.speak || phase == VoicePhase.heard) {
        // 波形跳动：各条错开相位
        final ph = (t + i * 0.18) * 2 * math.pi;
        h = base + (maxH - base) * (0.5 + 0.5 * math.sin(ph));
      } else if (phase == VoicePhase.listen) {
        h = base * 1.1;
      } else if (phase == VoicePhase.think || phase == VoicePhase.connecting || phase == VoicePhase.busy) {
        h = base * 0.8;
      } else {
        h = base * 0.6; // idle / muted / approval
      }
      final x = center.dx - totalW / 2 + barW / 2 + i * (barW + gap);
      canvas.drawLine(Offset(x, center.dy - h / 2), Offset(x, center.dy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.phase != phase;
}
