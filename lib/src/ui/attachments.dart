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
/// 下载失败的记住 30 秒：列表每次刷新都会重建缩略图，不记住的话会一直重复下载
final Map<String, Future<Uint8List>> _cache = {};
final Map<String, DateTime> _failedAt = {};
Future<Uint8List> loadAttachment(NetbarApi api, AttachmentInfo a, {bool retry = false}) {
  final failed = _failedAt[a.key];
  if (failed != null && (retry || DateTime.now().difference(failed) > const Duration(seconds: 30))) {
    _cache.remove(a.key);
    _failedAt.remove(a.key);
  }
  return _cache[a.key] ??= api.download(a).catchError((Object e) {
    _failedAt[a.key] = DateTime.now();
    throw e;
  });
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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget body;
    if (a.isImage) {
      body = SizedBox(
        width: s.isMobile ? 104 : 120,
        height: s.isMobile ? 78 : 90,
        child: FutureBuilder<Uint8List>(
          future: loadAttachment(s.controller.api, a),
          builder: (ctx, snap) => snap.hasData && snap.data!.isNotEmpty
              // 只按缩略图的大小解码，几张大截图不会占满内存
              ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: ((s.isMobile ? 104 : 120) * dpr).round())
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
            Text(a.pasted ? '粘贴的文本' : a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w500, color: fg)),
            Text(a.pasted ? '点开查看' : fmtSize(a.size), style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: .75))),
          ])),
        ]),
      );
    }
    final card = DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(NT.rSm + 2)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NT.rSm + 2),
        child: Builder(builder: (bctx) => Pressable(onTap: () => openAttachment(bctx, a), radius: NT.rSm + 2, label: a.name, child: body)),
      ),
    );
    return s.isDesktop ? Tooltip(message: a.name, child: card) : card;
  }
}

/// 点开附件：图片看大图，粘贴的文本直接看，其他文件保存（手机上用系统分享保存）
Future<void> openAttachment(BuildContext context, AttachmentInfo a) async {
  final s = NetbarScope.read(context);
  Uint8List bytes;
  final origin = rectOf(context);
  try {
    bytes = await loadAttachment(s.controller.api, a, retry: true);
    if (bytes.isEmpty) throw ApiError('附件打不开');
  } catch (e) {
    if (context.mounted) showToast(context, '附件打不开：$e');
    return;
  }
  if (!context.mounted) return;
  if (a.isImage) return showImageViewer(context, bytes, a.name);
  if (a.pasted) return showTextViewer(context, '粘贴的文本', utf8.decode(bytes, allowMalformed: true));
  await _save(context, bytes, a.name, origin);
}

/// origin：iPad 上分享面板从哪里弹出来（不给会直接报错）
Future<void> _save(BuildContext context, Uint8List bytes, String name, [Rect? origin]) async {
  try {
    final ok = await saveFile(bytes, name, origin: origin ?? rectOf(context));
    if (ok && context.mounted && isDesktopPlatform) showToast(context, '已保存');
  } catch (_) {
    if (context.mounted) showToast(context, '保存失败');
  }
}

/// 看大图：可以双指缩放、拖动；iOS 是黑底全屏页（导航栏“完成”），安卓是黑底全屏页（返回箭头），电脑上是对话框
/// 都在组件自己的导航里打开，不会盖住宿主应用的其他区域
Future<void> showImageViewer(BuildContext context, Uint8List bytes, String name) {
  final s = NetbarScope.read(context);
  final viewer = InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes, gaplessPlayback: true)));
  if (s.isDesktop) {
    return showDialog(
        context: context,
        useRootNavigator: false,
        barrierColor: Colors.black54,
        builder: (ctx) => Dialog(
              insetPadding: const EdgeInsets.all(24),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NT.rLg)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Builder(builder: (b) => AButton(label: '另存为', icon: Icons.download_outlined, small: true, onPressed: () => _save(b, bytes, name))),
                    const SizedBox(width: 4),
                    AIconButton(icon: Icons.close, tooltip: '关闭', onPressed: () => Navigator.pop(ctx)),
                  ]),
                ),
                const Divider(height: 1),
                Flexible(child: ColoredBox(color: const Color(0xFF111111), child: viewer)),
              ]),
            ));
  }
  final Widget page;
  if (s.isCupertino) {
    page = Builder(
        builder: (ctx) => CupertinoPageScaffold(
              backgroundColor: CupertinoColors.black,
              navigationBar: CupertinoNavigationBar(
                backgroundColor: const Color(0xCC000000),
                border: null,
                brightness: Brightness.dark,
                leading: CupertinoButton(padding: EdgeInsets.zero, onPressed: () => Navigator.pop(ctx), child: const Text('完成', style: TextStyle(color: CupertinoColors.white))),
                middle: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: CupertinoColors.white)),
                trailing: Builder(
                    builder: (b) => CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _save(b, bytes, name),
                        child: const Icon(CupertinoIcons.share, color: CupertinoColors.white, semanticLabel: '保存'))),
              ),
              child: SafeArea(child: viewer),
            ));
  } else {
    page = Builder(
        builder: (ctx) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                title: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                actions: [Builder(builder: (b) => IconButton(tooltip: '保存', icon: const Icon(Icons.share_outlined), onPressed: () => _save(b, bytes, name)))],
              ),
              body: SafeArea(child: viewer),
            ));
  }
  return Navigator.of(context).push(s.isCupertino ? CupertinoPageRoute(fullscreenDialog: true, builder: (_) => page) : MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));
}

/// 看粘贴的长文字
Future<void> showTextViewer(BuildContext context, String title, String text) => pushPanel(
      context,
      title: title,
      width: 760,
      height: 620,
      builder: (ctx) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(text, style: monoStyle(size: 13, color: NetbarColors(ctx).text2).copyWith(height: 1.55))),
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
        color: err ? NT.danger.withValues(alpha: .07) : c.card,
        border: Border.all(color: err ? NT.danger.withValues(alpha: .5) : c.line),
        borderRadius: BorderRadius.circular(NT.rSm + 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (isImg)
          Positioned.fill(child: Image.memory(f.preview!, fit: BoxFit.cover, cacheWidth: (64 * MediaQuery.devicePixelRatioOf(context)).round(), opacity: AlwaysStoppedAnimation(f.status == 'uploading' ? .6 : 1)))
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: (err ? NT.danger : NT.accent).withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
              child: Icon(err ? Icons.error_outline : _kindIcon(f.kind), size: 18, color: err ? c.dangerText : c.accentText),
            ),
            const SizedBox(width: 8),
            Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(f.pasted ? '粘贴的文本' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w500, color: c.text2)),
              Text(
                  err
                      ? f.error
                      : f.pasted
                          ? '${f.text?.length ?? ''} 字 · 点开查看'
                          : fmtSize(f.size),
                  maxLines: err ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: err ? c.dangerText : c.muted)),
            ])),
          ]),
        if (f.status == 'uploading')
          Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: f.progress, minHeight: 3, color: NT.accent, backgroundColor: c.fill)),
      ]),
    );
    return Stack(clipBehavior: Clip.none, children: [
      GestureDetector(
        onTap: () {
          if (isImg) showImageViewer(context, f.preview!, f.name);
          if (f.pasted && f.text != null) showTextViewer(context, '粘贴的文本', f.text!);
        },
        child: s.isDesktop ? Tooltip(message: err ? '${f.name}：${f.error}' : f.name, child: card) : card,
      ),
      // 删除按钮：看起来是个小圆点，手机上能点的区域有 32
      Positioned(
        top: s.isMobile ? -6 : 3,
        right: s.isMobile ? -6 : 3,
        child: Semantics(
          button: true,
          label: '删除附件${f.name}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => s.controller.removeFile(f),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: s.isMobile ? 32 : 18,
                height: s.isMobile ? 32 : 18,
                alignment: Alignment.center,
                child: Container(
                  width: s.isMobile ? 20 : 18,
                  height: s.isMobile ? 20 : 18,
                  decoration: const BoxDecoration(color: Color(0xAA000000), shape: BoxShape.circle),
                  child: Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
