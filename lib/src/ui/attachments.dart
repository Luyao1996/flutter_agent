// 附件：消息里的附件卡片、发送前的预览卡片、看大图、看粘贴的文字、保存
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart';
import 'adaptive.dart';

/// 附件文件按需下载，同一个只下载一次
final Map<String, Future<Uint8List>> _cache = {};
Future<Uint8List> loadAttachment(NetbarApi api, AttachmentInfo a) {
  final f = _cache[a.key] ??= api.download(a);
  f.catchError((_) {
    _cache.remove(a.key);
    return Uint8List(0);
  });
  return f;
}

IconData _kindIcon(String kind) => kind == 'image'
    ? Icons.image_outlined
    : kind == 'pdf'
        ? Icons.picture_as_pdf_outlined
        : Icons.description_outlined;

/// 消息气泡里的附件：图片显示缩略图，其他显示图标、文件名、大小；点开看大图或保存
class AttachmentCard extends StatelessWidget {
  const AttachmentCard(this.a, {super.key, this.onBubble = false});
  final AttachmentInfo a;
  final bool onBubble;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final fg = onBubble ? Colors.white : c.text2;
    final bg = onBubble ? Colors.white.withValues(alpha: .14) : c.fill;
    final radius = BorderRadius.circular(10);
    Widget body;
    if (a.isImage) {
      body = SizedBox(
        width: s.isMobile ? 104 : 120,
        height: s.isMobile ? 78 : 90,
        child: FutureBuilder<Uint8List>(
          future: loadAttachment(s.controller.api, a),
          builder: (ctx, snap) => snap.hasData && snap.data!.isNotEmpty
              ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
              : Center(child: snap.hasError ? Icon(Icons.broken_image_outlined, color: fg) : const ASpinner()),
        ),
      );
    } else {
      body = Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 34, height: 34, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)), child: Icon(_kindIcon(a.kind), size: 18, color: fg)),
          const SizedBox(width: 8),
          Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(a.pasted ? '粘贴的文本' : a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: fg)),
            Text(a.pasted ? '点开查看' : fmtSize(a.size), style: TextStyle(fontSize: 11, color: fg.withValues(alpha: .7))),
          ])),
        ]),
      );
    }
    return Semantics(
      button: true,
      label: a.name,
      child: Material(
        color: bg,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: () => openAttachment(context, a), child: Tooltip(message: a.name, child: body)),
      ),
    );
  }
}

/// 点开附件：图片看大图，粘贴的文本直接看，其他文件保存（手机上用系统分享保存）
Future<void> openAttachment(BuildContext context, AttachmentInfo a) async {
  final s = NetbarScope.read(context);
  Uint8List bytes;
  try {
    bytes = await loadAttachment(s.controller.api, a);
    if (bytes.isEmpty) throw ApiError('附件打不开');
  } catch (e) {
    if (context.mounted) showToast(context, '附件打不开：$e');
    return;
  }
  if (!context.mounted) return;
  if (a.isImage) return showImageViewer(context, bytes, a.name);
  if (a.pasted) return showTextViewer(context, '粘贴的文本', utf8.decode(bytes, allowMalformed: true));
  await _save(context, bytes, a.name);
}

Future<void> _save(BuildContext context, Uint8List bytes, String name) async {
  try {
    final ok = await saveFile(bytes, name);
    if (ok && context.mounted && isDesktopPlatform) showToast(context, '已保存');
  } catch (_) {
    if (context.mounted) showToast(context, '保存失败');
  }
}

/// 看大图：可以双指缩放、拖动；手机上是黑底全屏页，电脑上是对话框
Future<void> showImageViewer(BuildContext context, Uint8List bytes, String name) {
  final s = NetbarScope.read(context);
  final viewer = InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes)));
  if (s.isDesktop) {
    return showDialog(
        context: context,
        builder: (ctx) => Dialog(
              insetPadding: const EdgeInsets.all(24),
              clipBehavior: Clip.antiAlias,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                  child: Row(children: [
                    Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                    TextButton(onPressed: () => _save(ctx, bytes, name), child: const Text('另存为')),
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
                  ]),
                ),
                Flexible(child: viewer),
              ]),
            ));
  }
  final page = Builder(
      builder: (ctx) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(name, style: const TextStyle(fontSize: 15)),
              leading: s.isCupertino ? CupertinoButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成', style: TextStyle(color: Colors.white))) : null,
              leadingWidth: s.isCupertino ? 72 : null,
              actions: [IconButton(tooltip: '保存', icon: Icon(s.isCupertino ? CupertinoIcons.share : Icons.share_outlined), onPressed: () => _save(ctx, bytes, name))],
            ),
            body: SafeArea(child: viewer),
          ));
  return Navigator.of(context, rootNavigator: true)
      .push(s.isCupertino ? CupertinoPageRoute(fullscreenDialog: true, builder: (_) => page) : MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));
}

/// 看粘贴的长文字
Future<void> showTextViewer(BuildContext context, String title, String text) => pushPanel(
      context,
      title: title,
      width: 760,
      height: 620,
      builder: (ctx) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(text, style: const TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: 13, height: 1.5))),
    );

/// 发送前的附件卡片：缩略图或图标，上传进度，失败原因，删除按钮
class PendingFileCard extends StatelessWidget {
  const PendingFileCard(this.f, {super.key});
  final PendingFile f;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final err = f.status == 'error';
    final isImg = f.kind == 'image' && f.preview != null && !err;
    final card = Container(
      height: isImg ? 64 : null,
      width: isImg ? 64 : null,
      constraints: BoxConstraints(maxWidth: err ? 300 : 230, minHeight: 50),
      padding: isImg ? null : const EdgeInsets.fromLTRB(6, 6, 26, 6),
      decoration: BoxDecoration(
        color: err ? NetbarColors.danger.withValues(alpha: .07) : c.bubble,
        border: Border.all(color: err ? NetbarColors.danger.withValues(alpha: .5) : c.line),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (isImg)
          Positioned.fill(child: Image.memory(f.preview!, fit: BoxFit.cover, opacity: AlwaysStoppedAnimation(f.status == 'uploading' ? .6 : 1)))
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: (err ? NetbarColors.danger : NetbarColors.accent).withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
              child: Icon(err ? Icons.error_outline : _kindIcon(f.kind), size: 18, color: err ? c.dangerText : c.accentText),
            ),
            const SizedBox(width: 8),
            Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(f.pasted ? '粘贴的文本' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.text2)),
              Text(
                  err
                      ? f.error
                      : f.pasted
                          ? '${f.text?.length ?? ''} 字 · 点开查看'
                          : fmtSize(f.size),
                  maxLines: err ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: err ? c.dangerText : c.muted)),
            ])),
          ]),
        if (f.status == 'uploading')
          Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: f.progress, minHeight: 3, color: NetbarColors.accent, backgroundColor: c.fill)),
      ]),
    );
    return Stack(clipBehavior: Clip.none, children: [
      GestureDetector(
        onTap: () {
          if (isImg) showImageViewer(context, f.preview!, f.name);
          if (f.pasted && f.text != null) showTextViewer(context, '粘贴的文本', f.text!);
        },
        child: Tooltip(message: err ? '${f.name}：${f.error}' : f.name, child: card),
      ),
      Positioned(
        top: 3,
        right: 3,
        child: Semantics(
          button: true,
          label: '删除附件',
          child: GestureDetector(
            onTap: () => s.controller.removeFile(f),
            child: Container(
              width: s.isMobile ? 22 : 18,
              height: s.isMobile ? 22 : 18,
              decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
              child: Icon(Icons.close, size: s.isMobile ? 14 : 12, color: Colors.white),
            ),
          ),
        ),
      ),
    ]);
  }
}
