// 分享：生成只读的快照链接；手机上用系统分享面板发出去，电脑上复制链接
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services.dart';
import '../ui/adaptive.dart';

Future<void> openSharePanel(BuildContext context) => pushPanel(context, title: '分享对话', width: 560, height: 360, builder: (_) => const SharePanel());

class SharePanel extends StatefulWidget {
  const SharePanel({super.key});
  @override
  State<SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends State<SharePanel> {
  Map<String, dynamic>? _share;
  bool _loading = true, _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ctl = NetbarScope.read(context).controller;
    try {
      final r = await ctl.api.post('/api/share/status', {'sessionId': ctl.sessionId});
      _share = r['share'] is Map ? asMap(r['share']) : null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final ctl = NetbarScope.read(context).controller;
    setState(() => _working = true);
    try {
      final r = await ctl.api.post('/api/share/create', {'sessionId': ctl.sessionId, 'path': ctl.path.map((t) => t.id).toList()});
      _share = asMap(r['share']);
      await _send();
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _delete() async {
    final ctl = NetbarScope.read(context).controller;
    if (!await confirmDialog(context, title: '取消分享？', message: '取消分享后，这个链接马上就打不开了。', ok: '取消分享', cancel: '再想想', destructive: true)) return;
    try {
      await ctl.api.post('/api/share/delete', {'sessionId': ctl.sessionId});
      _share = null;
      if (mounted) showToast(context, '已取消分享');
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    if (mounted) setState(() {});
  }

  /// 电脑上复制链接；手机上打开系统分享面板（微信、短信、复制…）
  Future<void> _send() async {
    final s = NetbarScope.read(context);
    final url = s.controller.api.shareUrl(str(_share!['id']));
    if (s.isDesktop) {
      await copyText(url);
      if (mounted) showToast(context, '链接已复制');
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    await shareText(url, subject: '远程运维对话：${s.controller.title}', origin: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    if (_loading) return const EmptyHint('加载中…', loading: true);
    if (_error != null) return EmptyHint(_error!);
    final url = _share == null ? '' : s.controller.api.shareUrl(str(_share!['id']));
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('生成一个只读链接：别人打开只能查看这次对话（当前看的这个版本），不能继续提问，也不能操作机器。链接里不包含连接机器用的地址和令牌。', style: TextStyle(fontSize: 13, color: c.muted, height: 1.5)),
      const SizedBox(height: 16),
      if (_share == null)
        Align(alignment: Alignment.centerLeft, child: AButton(label: _working ? '正在生成…' : '生成分享链接', icon: Icons.link, kind: BtnKind.primary, onPressed: _working ? null : _create))
      else ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
          child: SelectableText(url, style: const TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: 12.5)),
        ),
        const SizedBox(height: 6),
        Text('快照生成于 ${fmtTime(DateTime.tryParse(str(_share!['createdAt']))?.toLocal())}。之后对话里的新内容不会出现在链接里，点“更新快照”可以换成现在的内容（链接不变）。', style: TextStyle(fontSize: 12, color: c.muted)),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          AButton(label: s.isDesktop ? '复制链接' : '发送链接', icon: s.isDesktop ? Icons.copy_outlined : Icons.ios_share, kind: BtnKind.primary, onPressed: _send),
          AButton(label: '更新快照', icon: Icons.refresh, onPressed: _working ? null : _create),
          AButton(label: '取消分享', icon: Icons.link_off, kind: BtnKind.danger, onPressed: _delete),
        ]),
      ],
    ]);
  }
}
