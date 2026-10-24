// 简单的 Markdown 显示（和网页版规则一致）：代码块、标题、表格、列表、分隔线、行内代码、加粗
import 'package:flutter/material.dart';

import 'adaptive.dart';

class MarkdownBody extends StatelessWidget {
  const MarkdownBody(this.text, {super.key, this.fontSize = 14});
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final base = TextStyle(fontSize: fontSize, height: 1.6, color: c.text2);
    final blocks = <Widget>[];
    final parts = text.split(RegExp(r'```[^\n]*\n?'));
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd) {
        blocks.add(_code(context, parts[i].replaceAll(RegExp(r'\n$'), '')));
      } else {
        blocks.addAll(_blocks(context, parts[i], base));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _spaced(blocks));
  }

  List<Widget> _spaced(List<Widget> ws) => [
        for (var i = 0; i < ws.length; i++) ...[if (i > 0) const SizedBox(height: 8), ws[i]]
      ];

  Widget _code(BuildContext context, String code) {
    final c = NetbarColors(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(code, style: TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: fontSize - 1.5, height: 1.5, color: c.text2)),
      ),
    );
  }

  /// 行内：`代码`、**加粗**
  static InlineSpan inline(BuildContext context, String s, TextStyle base) {
    final c = NetbarColors(context);
    final spans = <InlineSpan>[];
    final re = RegExp(r'`([^`\n]+)`|\*\*([^*\n]+)\*\*');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(
            text: m.group(1),
            style: TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: (base.fontSize ?? 14) - 1.5, color: c.accentText, backgroundColor: c.fill)));
      } else {
        spans.add(TextSpan(text: m.group(2), style: TextStyle(fontWeight: FontWeight.w600, color: c.text)));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return TextSpan(style: base, children: spans);
  }

  List<String> _cells(String line) => line.trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((x) => x.trim()).toList();

  List<Widget> _blocks(BuildContext context, String text, TextStyle base) {
    final c = NetbarColors(context);
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
        out.add(Text.rich(inline(context, h.group(2)!, base.copyWith(fontSize: size, fontWeight: FontWeight.w600, color: c.text))));
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
        final items = [m.group(2)!];
        while (i + 1 < lines.length) {
          final n = listRe.firstMatch(lines[i + 1]);
          if (n == null) break;
          items.add(n.group(2)!);
          i++;
        }
        out.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var k = 0; k < items.length; k++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: ordered ? 24 : 16, child: Text(ordered ? '${k + 1}.' : '•', style: base.copyWith(color: c.muted))),
                Expanded(child: Text.rich(inline(context, items[k], base))),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text.rich(inline(context, s, base.copyWith(fontSize: fontSize - 1, fontWeight: header ? FontWeight.w600 : null, color: header ? c.muted : null))),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(horizontalInside: BorderSide(color: c.line), bottom: BorderSide(color: c.line)),
        children: [
          TableRow(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))), children: [for (final h in head) cell(h, header: true)]),
          for (final r in rows) TableRow(children: [for (var k = 0; k < n; k++) cell(k < r.length ? r[k] : '')]),
        ],
      ),
    );
  }
}
