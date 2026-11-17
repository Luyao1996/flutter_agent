// 对话里的新内容：AI 截图/工具返回的图片（tool_image）、“使用了工具”一行（tool_used）、
// AI 从电脑上取回的文件（file_shared）、语音通话记录（voice）、@ 的类型（经验、背景知识、资料、技能、工具）
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import '../services.dart';
import 'adaptive.dart';
import 'attachments.dart';
import 'messages.dart' show SysLine;

// ---------- @ 的类型 ----------
const mentionNames = {'experience': '经验', 'background': '背景知识', 'library': '资料', 'skill': '技能', 'tool': '工具'};

IconData refIcon(String type) => switch (type) {
      'background' => Icons.menu_book_outlined,
      'library' => Icons.description_outlined,
      'skill' => Icons.auto_awesome_outlined,
      'tool' => Icons.build_outlined,
      _ => Icons.lightbulb_outline,
    };

/// 工具标签的颜色（青色，和网页版一致）
Color toolColor(bool dark) => dark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E);
const toolBubbleColor = Color(0x7314B8A6);

/// @ 工具的编号是“tool:工具名”
String toolNameOfRef(String id) => id.startsWith('tool:') ? id.substring(5) : id;

// ---------- 打开工具详情 ----------
/// 点工具名：宿主（或工具面板）在 controller.onOpenTool 里接管；没接时弹一个简单的详情框兜底
void openTool(BuildContext context, String name, {String title = '', String args = '', bool? ok, String machine = ''}) {
  final ctl = NetbarScope.read(context).controller;
  if (name.isEmpty) return;
  if (ctl.onOpenTool != null) return ctl.onOpenTool!(name);
  final c = NetbarColors(context);
  final rows = <(String, String)>[
    ('名称', name),
    if (title.isNotEmpty && title != name) ('标题', title),
    if (machine.isNotEmpty) ('电脑', machine),
    if (args.isNotEmpty) ('参数', args),
    if (ok != null) ('结果', ok ? '运行成功' : '运行出错'),
  ];
  infoDialog(
    context,
    title: '工具：${title.isNotEmpty ? title : name}',
    content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 44, child: Text(r.$1, style: TextStyle(fontSize: NT.fSmall, color: c.muted))),
            Expanded(child: SelectableText(r.$2, style: monoStyle(size: NT.fSmall, color: r.$2 == '运行出错' ? c.warnText : c.text))),
          ]),
        ),
      const SizedBox(height: 4),
      Text('工具的完整设置（说明、参数、命令行）在工具库里查看和修改。', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
    ]),
  );
}

/// 只有一个“知道了”按钮的说明框
Future<void> infoDialog(BuildContext context, {required String title, required Widget content}) {
  final s = NetbarScope.read(context);
  if (s.isCupertino) {
    return showCupertinoDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => CupertinoAlertDialog(
              title: Text(title),
              content: Padding(padding: const EdgeInsets.only(top: 8), child: Material(type: MaterialType.transparency, child: s.copyWith(child: content))),
              actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
            ));
  }
  return showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => s.copyWith(
          child: AlertDialog(
            title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            scrollable: true,
            content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: content),
            actions: [AButton(label: '知道了', kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx))],
          )));
}

// ---------- “使用了工具”一行 ----------
/// AI 运行了工具库的工具：工具名（点开看详情）、参数、成功/出错
class ToolUsedLine extends StatelessWidget {
  const ToolUsedLine(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final name = str(d['name']), title = str(d['title']), args = str(d['args']), machine = str(d['machine']);
    final ok = d['ok'] != false;
    return SysLine(
      icon: Icons.build_outlined,
      text: '${machine.isNotEmpty ? '在 $machine 上' : ''}使用了工具：',
      link: title.isNotEmpty ? title : name,
      tail: args.isNotEmpty ? '（$args）' : null,
      onLink: () => openTool(context, name, title: title, args: args, ok: ok, machine: machine),
      trailing: ok ? Icon(Icons.check, size: 14, color: c.okText) : Text('运行出错', style: TextStyle(fontSize: NT.fCaption, color: c.warnText)),
    );
  }
}

// ---------- AI 截图、工具返回的图片 ----------
/// 复制附件的公网下载链接（拿到链接的人不用登录就能下载）
Future<void> copyAttachmentLink(BuildContext context, AttachmentInfo a) async {
  final ctl = NetbarScope.read(context).controller;
  try {
    final r = await ctl.api.post('/api/uploads/link', {'group': a.group, 'id': a.id});
    await copyText(ctl.config.baseUrl.replaceAll(RegExp(r'/+$'), '') + str(r['path']));
    if (context.mounted) showToast(context, '已复制下载链接，拿到链接的人不用登录就能下载');
  } on ApiError catch (e) {
    if (context.mounted) showToast(context, '没能生成下载链接：${e.message}');
  } catch (_) {
    if (context.mounted) showToast(context, '没能生成下载链接');
  }
}

/// 截图（或其他工具返回的图片）：靠左显示较大的缩略图，完整显示不裁切；点开看大图，旁边可以复制下载链接
class ToolImageBlock extends StatelessWidget {
  const ToolImageBlock(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final machine = str(d['machine']), tool = str(d['tool']);
    final what = tool == 'screenshot' ? '截图' : '${tool.isEmpty ? '工具' : tool} 返回的图片';
    final atts = asList(d['attachments']).map((a) => AttachmentInfo.fromJson(asMap(a))).toList();
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_outlined, size: 14, color: c.muted),
          const SizedBox(width: 5),
          Flexible(child: Text('${machine.isNotEmpty ? '$machine 的' : ''}$what', style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final a in atts) ToolImageThumb(a)]),
      ]),
    );
  }
}

class ToolImageThumb extends StatelessWidget {
  const ToolImageThumb(this.a, {super.key});
  final AttachmentInfo a;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final w = s.isMobile ? 240.0 : 320.0, h = s.isMobile ? 150.0 : 200.0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final thumb = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: c.fill2, borderRadius: BorderRadius.circular(NT.rSm + 2), border: Border.all(color: c.line)),
      clipBehavior: Clip.antiAlias,
      child: Builder(
        builder: (bctx) => Pressable(
          onTap: () => openAttachment(bctx, a),
          onLongPress: s.isMobile ? () => _menu(bctx) : null,
          radius: NT.rSm + 2,
          label: '查看大图：${a.name}',
          child: FutureBuilder<Uint8List>(
            future: loadAttachment(s.controller.api, a),
            builder: (ctx, snap) => snap.hasData && snap.data!.isNotEmpty
                // 只按缩略图的大小解码
                ? Image.memory(snap.data!, fit: BoxFit.contain, width: w, height: h, gaplessPlayback: true, cacheWidth: (w * dpr).round())
                : Center(child: snap.hasError ? Icon(Icons.broken_image_outlined, color: c.muted) : const ASpinner()),
          ),
        ),
      ),
    );
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      s.isDesktop ? Tooltip(message: a.name, child: thumb) : thumb,
      Builder(builder: (bctx) => AIconButton(icon: Icons.link, tooltip: '复制下载链接', size: 16, onPressed: () => copyAttachmentLink(bctx, a))),
    ]);
  }

  /// 手机上长按：看大图、复制下载链接
  Future<void> _menu(BuildContext context) async {
    final r = await actionSheet<String>(context, actions: const [
      SheetAction('查看大图', 'open', icon: Icons.zoom_in),
      SheetAction('复制下载链接', 'link', icon: Icons.link),
    ]);
    if (!context.mounted) return;
    if (r == 'open') return openAttachment(context, a);
    if (r == 'link') return copyAttachmentLink(context, a);
  }
}

// ---------- AI 从电脑上取回的文件 ----------
/// 下载链接是公开的：点卡片时才从那台电脑上取，取回后另存为（手机上用系统分享保存）
typedef LinkFetcher = Future<Uint8List> Function(String url);
LinkFetcher fetchLink = (url) async {
  final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
  if (r.statusCode != 200) throw ApiError('下载失败（${r.statusCode}），那台电脑可能已经关机');
  return r.bodyBytes;
};

class FileSharedCard extends StatefulWidget {
  const FileSharedCard(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  State<FileSharedCard> createState() => _FileSharedCardState();
}

class _FileSharedCardState extends State<FileSharedCard> {
  bool _loading = false;

  Future<void> _download() async {
    final d = widget.d;
    final origin = rectOf(context);
    setState(() => _loading = true);
    try {
      final bytes = await fetchLink(str(d['link']));
      if (!mounted) return;
      final ok = await saveFile(bytes, str(d['name']), origin: origin);
      if (ok && mounted && isDesktopPlatform) showToast(context, '已保存');
    } catch (e) {
      if (mounted) showToast(context, e is ApiError ? e.message : '下载失败，那台电脑可能已经关机');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final d = widget.d;
    final head = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.download_outlined, size: 14, color: c.muted),
      const SizedBox(width: 5),
      Flexible(child: Text('${str(d['machine'])} 上的 ${str(d['path'])}', style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
    ]);
    Widget body;
    // 老记录里存成了附件
    if (d['file'] is Map) {
      final a = AttachmentInfo.fromJson(asMap(d['file']));
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        AttachmentCard(a),
        Builder(builder: (bctx) => AIconButton(icon: Icons.link, tooltip: '复制下载链接', size: 16, onPressed: () => copyAttachmentLink(bctx, a))),
      ]);
    } else {
      final size = (d['size'] as num?)?.toInt() ?? 0;
      final card = DecoratedBox(
        decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(NT.rSm + 2)),
        child: Pressable(
          onTap: _loading ? null : _download,
          radius: NT.rSm + 2,
          label: '下载 ${str(d['name'])}',
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: c.fill2, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: _loading ? const ASpinner() : Icon(Icons.download_outlined, size: 18, color: c.text2))),
              const SizedBox(width: 8),
              Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(str(d['name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w500, color: c.text2)),
                Text(_loading ? '正在从电脑上取…' : (size > 0 ? fmtSize(size) : '点击下载'), style: TextStyle(fontSize: 11.5, color: c.muted)),
              ])),
            ]),
          ),
        ),
      );
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(message: '下载时才从电脑上取，那台电脑要开着', child: card),
        AIconButton(
            icon: Icons.link,
            tooltip: '复制下载链接',
            size: 16,
            onPressed: () async {
              await copyText(str(d['link']));
              if (context.mounted) showToast(context, '已复制下载链接，拿到链接的人不用登录就能下载');
            }),
      ]);
    }
    return Column(children: [head, const SizedBox(height: 6), body]);
  }
}

// ---------- 语音通话记录 ----------
/// 通话里的一句话：你说的靠右、AI 说的靠左
class VoiceLine extends StatelessWidget {
  const VoiceLine(this.d, {super.key});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final you = d['role'] == 'user';
    return Align(
      alignment: you ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .76,
        alignment: you ? Alignment.centerRight : Alignment.centerLeft,
        child: Align(
          alignment: you ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: you ? NT.accent : c.fill2,
              borderRadius: BorderRadius.circular(15).copyWith(
                bottomRight: you ? const Radius.circular(5) : null,
                bottomLeft: you ? null : const Radius.circular(5),
              ),
            ),
            child: Text(str(d['text']), style: TextStyle(fontSize: 14, height: 1.5, color: you ? Colors.white : c.text)),
          ),
        ),
      ),
    );
  }
}

// ---------- 确认卡片的说明 ----------
/// 确认卡片标题：后台给了 what 就用它；连接其他电脑、在其他电脑上操作、普通操作各有说法
String approvalWhat(Map<String, dynamic> a) {
  final what = str(a['what']), machine = str(a['machine']), tool = str(a['tool']);
  if (what.isNotEmpty) return what;
  if (a['connect'] == true) return 'AI 要连接本网吧的另一台电脑 $machine，连上后可以在那台电脑上查看和操作';
  if (machine.isNotEmpty) return 'AI 要在另一台电脑 $machine 上执行一个会改动机器的操作：$tool';
  return '';
}

/// 资料说明的批量确认（lib_describe）：一行一份资料（路径 → 说明），比 JSON 好看
class LibDescribeList extends StatelessWidget {
  const LibDescribeList(this.input, {super.key});
  final Map<String, dynamic> input;
  static bool handles(Map<String, dynamic> a) => str(a['tool']) == 'lib_describe' && asMap(a['input'])['说明'] is Map;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final items = asMap(input['说明']).entries.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${str(input['操作'])}${str(input['数量']).isEmpty ? '' : ' · ${str(input['数量'])}'}', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
      Container(
        margin: const EdgeInsets.only(top: 6),
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 260),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(NT.rSm)),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: items.length,
          itemBuilder: (ctx, i) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SelectableText.rich(TextSpan(children: [
              TextSpan(text: items[i].key, style: monoStyle(size: NT.fCaption, color: c.text).copyWith(fontWeight: FontWeight.w600)),
              TextSpan(text: '\n${str(items[i].value)}', style: TextStyle(fontSize: NT.fCaption, color: c.text2, height: 1.45)),
            ])),
          ),
        ),
      ),
    ]);
  }
}
