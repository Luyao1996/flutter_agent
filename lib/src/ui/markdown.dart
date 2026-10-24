// 简单的 Markdown 显示（和网页版规则一致）：代码块、标题、表格、列表、分隔线、行内代码、加粗
// caret：正在生成时在文字末尾显示一个闪烁的光标
import 'package:flutter/material.dart';

import 'adaptive.dart';

/// 光标占位符：先接在文字末尾一起解析，画的时候换成光标
const _caretMark = '\uE000';

class MarkdownBody extends StatelessWidget {
  const MarkdownBody(this.text, {super.key, this.fontSize = 14, this.caret = false});
  final String text;
  final double fontSize;
  final bool caret;

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final base = TextStyle(fontSize: fontSize, height: 1.65, color: c.text2);
    final blocks = <Widget>[];
    final src = caret ? '${text.trimRight()}$_caretMark' : text;
    final parts = src.split(RegExp(r'```[^\n]*\n?'));
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd) {
        blocks.add(_code(context, parts[i].replaceAll(RegExp(r'\n$'), '')));
      } else {
        blocks.addAll(_blocks(context, parts[i], base));
      }
    }
    if (blocks.isEmpty && caret) blocks.add(Text.rich(inline(context, _caretMark, base)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _spaced(blocks));
  }

  List<Widget> _spaced(List<Widget> ws) => [
        for (var i = 0; i < ws.length; i++) ...[if (i > 0) const SizedBox(height: 10), ws[i]]
      ];

  Widget _code(BuildContext context, String code) {
    final c = NetbarColors(context);
    final style = monoStyle(size: fontSize - 1.5, color: c.text2).copyWith(height: 1.55);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: c.line)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(_withCaret(code, style)),
      ),
    );
  }

  /// 把光标占位符换成闪烁的光标
  static InlineSpan _withCaret(String s, TextStyle style) {
    final i = s.indexOf(_caretMark);
    if (i < 0) return TextSpan(text: s, style: style);
    return TextSpan(style: style, children: [
      TextSpan(text: s.substring(0, i)),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: _Caret(height: (style.fontSize ?? 14) * 1.15)),
      TextSpan(text: s.substring(i + 1)),
    ]);
  }

  /// 行内：`代码`、**加粗**
  static InlineSpan inline(BuildContext context, String s, TextStyle base) {
    final c = NetbarColors(context);
    final spans = <InlineSpan>[];
    final re = RegExp(r'`([^`\n]+)`|\*\*([^*\n]+)\*\*');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(_withCaret(s.substring(last, m.start), base));
      if (m.group(1) != null) {
        // 前后加窄空格，底色不会贴着文字
        spans.add(TextSpan(
            text: ' ${m.group(1)} ',
            style: monoStyle(size: (base.fontSize ?? 14) - 1.5, color: c.accentText).copyWith(backgroundColor: c.fill, height: base.height)));
      } else {
        spans.add(_withCaret(m.group(2)!, base.copyWith(fontWeight: FontWeight.w600, color: c.text)));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(_withCaret(s.substring(last), base));
    return TextSpan(style: base, children: spans);
  }

  List<String> _cells(String line) => line.trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((x) => x.trim()).toList();

  List<Widget> _blocks(BuildContext context, String text, TextStyle base) {
    final c = NetbarColors(context);
    final scaler = MediaQuery.textScalerOf(context);
    final lines = text.split('\n');
    final out = <Widget>[];
    var para = <String>[];
    void flush() {
      if (para.isEmpty) return;
      out.add(Text.rich(inline(context, para.join('\n'), base)));
      para = [];
    }

    final listRe = RegExp(r'^\s*([-*]|\d+\.)\s+(.*)');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)').firstMatch(line);
      if (h != null) {
        flush();
        final size = [fontSize + 3, fontSize + 2, fontSize + 1, fontSize + .5, fontSize, fontSize][h.group(1)!.length - 1];
        out.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(inline(context, h.group(2)!, base.copyWith(fontSize: size, fontWeight: FontWeight.w600, color: c.text, height: 1.4))),
        ));
        continue;
      }
      if (RegExp(r'^\s*(-{3,}|\*{3,})\s*$').hasMatch(line)) {
        flush();
        out.add(Divider(height: 8, color: c.line));
        continue;
      }
      if (line.trim().startsWith('|') && i + 1 < lines.length && RegExp(r'^\s*\|?[\s:|-]+\|?\s*$').hasMatch(lines[i + 1]) && lines[i + 1].contains('-')) {
        flush();
        final head = _cells(line);
        i++;
        final rows = <List<String>>[];
        while (i + 1 < lines.length && lines[i + 1].trim().startsWith('|')) {
          rows.add(_cells(lines[++i]));
        }
        out.add(_table(context, head, rows, base));
        continue;
      }
      final m = listRe.firstMatch(line);
      if (m != null) {
        flush();
        final ordered = RegExp(r'\d').hasMatch(m.group(1)!);
        final items = [(m.group(1)!, m.group(2)!)];
        while (i + 1 < lines.length) {
          final n = listRe.firstMatch(lines[i + 1]);
          if (n == null) break;
          items.add((n.group(1)!, n.group(2)!));
          i++;
        }
        // 序号的宽度跟着系统字体大小走，两位数序号也放得下
        final markerW = scaler.scale(ordered ? fontSize * 1.9 : fontSize * 1.2);
        out.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (marker, body) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: markerW, child: Text(ordered ? marker : '•', style: base.copyWith(color: c.muted))),
                Expanded(child: Text.rich(inline(context, body, base))),
              ]),
            ),
        ]));
        continue;
      }
      para.add(line);
    }
    flush();
    return out;
  }

  Widget _table(BuildContext context, List<String> head, List<List<String>> rows, TextStyle base) {
    final c = NetbarColors(context);
    final n = head.length;
    Widget cell(String s, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text.rich(inline(context, s, base.copyWith(fontSize: fontSize - 1, height: 1.45, fontWeight: header ? FontWeight.w600 : null, color: header ? c.text : null))),
        );
    return Container(
      decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(NT.rSm)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(horizontalInside: BorderSide(color: c.line), verticalInside: BorderSide(color: c.line)),
          children: [
            TableRow(decoration: BoxDecoration(color: c.fill), children: [for (final h in head) cell(h, header: true)]),
            for (final r in rows) TableRow(children: [for (var k = 0; k < n; k++) cell(k < r.length ? r[k] : '')]),
          ],
        ),
      ),
    );
  }
}

/// 闪烁的光标
class _Caret extends StatefulWidget {
  const _Caret({required this.height});
  final double height;
  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: CurvedAnimation(parent: _a, curve: Curves.easeInOut),
        child: Container(
            margin: const EdgeInsets.only(left: 2), width: 7, height: widget.height, decoration: BoxDecoration(color: NT.accent, borderRadius: BorderRadius.circular(2))),
      );
}
