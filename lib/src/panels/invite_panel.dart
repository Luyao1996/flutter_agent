// 分享窗口里的“邀请加入”（多人会话）：生成邀请链接（1 天 / 7 天 / 永久）、重新生成、关闭邀请，
// 改自己在群里的名字，看群成员（在线/不在线）、移出成员。有人进出时成员列表实时刷新
import 'package:flutter/material.dart';

import '../api.dart';
import '../group.dart';
import '../models.dart';
import '../services.dart';
import '../ui/adaptive.dart';
import '../ui/group_view.dart';

class InvitePanel extends StatefulWidget {
  const InvitePanel({super.key});
  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  bool _loading = true, _working = false;
  String? _error;
  String _expires = '7d';
  final _name = TextEditingController();

  GroupRoom get _group => NetbarScope.read(context).controller.group;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 口令远程打开的不能邀请别人（和网页版一致）
    if (NetbarScope.read(context).controller.config.isPass) {
      setState(() {
        _loading = false;
        _error = '口令远程方式打开的页面不能邀请别人。';
      });
      return;
    }
    try {
      await _group.refresh();
      _name.text = _group.info?.ownerName ?? defaultOwnerName;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _working = true);
    try {
      await f();
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _create({bool again = false}) async {
    if (again && !await confirmDialog(context, title: '重新生成邀请链接？', message: '重新生成后，旧链接马上就打不开了；已经进来的人不受影响。', ok: '重新生成')) {
      return;
    }
    await _run(() => _group.createInvite(_expires));
    // 第一次生成：马上复制（手机上打开系统分享面板）
    if (!again) await _send();
  }

  Future<void> _close() async {
    if (!await confirmDialog(context, title: '关闭邀请？', message: '关闭邀请后，链接马上失效，已经进来的人也都会被移出。', ok: '关闭邀请', destructive: true)) return;
    await _run(_group.closeInvite);
  }

  Future<void> _kick(RoomMember m) async {
    if (!await confirmDialog(context, title: '移出成员', message: '确定把“${m.name}”移出这个会话吗？', ok: '移出', destructive: true)) return;
    await _run(() => _group.kick(m.id));
  }

  Future<void> _rename() async {
    await _run(() async {
      final name = await _group.rename(_name.text);
      _name.text = name;
      if (mounted) showToast(context, '已改名为 $name');
    });
  }

  /// 电脑上复制链接；手机上打开系统分享面板
  Future<void> _send() async {
    final inv = _group.info?.invite;
    if (inv == null || !mounted) return;
    final s = NetbarScope.read(context);
    final url = _group.inviteUrl(inv.code);
    if (s.isDesktop) {
      await copyText(url);
      if (mounted) showToast(context, '邀请链接已复制');
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    try {
      await shareText(url, subject: '邀请你加入远程运维对话：${s.controller.title}', origin: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
    } catch (_) {
      // 系统分享面板打不开：改成复制链接
      await copyText(url);
      if (mounted) showToast(context, '邀请链接已复制');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const EmptyHint('加载中…', loading: true);
    if (_error != null) return EmptyHint(_error!);
    return ListenableBuilder(listenable: _group, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final info = _group.info;
    final inv = info?.invite;
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        t,
        style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.text2),
      ),
    );
    final expires = ASegmented<String>(value: _expires, segments: inviteExpires, onChanged: (v) => setState(() => _expires = v));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('把邀请链接发给别人，对方打开后填个名字就能进来：能看到这个对话的全部记录，可以和大家聊天，也可以叫 AI 干活（要不要点“允许”和你一样）。你不在线时，会话会自动关闭。', style: TextStyle(fontSize: 13, color: c.muted, height: 1.5)),
        const SizedBox(height: 16),
        if (inv == null) ...[
          Text(
            '链接的有效期',
            style: TextStyle(fontSize: NT.fCaption, color: c.muted),
          ),
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerLeft, child: expires),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AButton(label: _working ? '正在生成…' : '生成邀请链接', icon: Icons.person_add_alt, kind: BtnKind.primary, onPressed: _working ? null : () => _create()),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.line),
            ),
            child: SelectableText(
              _group.inviteUrl(inv.code),
              style: const TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 6),
          Text(inv.expiresAt > 0 ? '有效期到 ${fmtTime(DateTime.fromMillisecondsSinceEpoch(inv.expiresAt))}' : '永久有效', style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AButton(label: s.isDesktop ? '复制链接' : '发送链接', icon: s.isDesktop ? Icons.copy_outlined : Icons.ios_share, kind: BtnKind.primary, onPressed: _send),
              AButton(label: '关闭邀请', icon: Icons.link_off, kind: BtnKind.danger, onPressed: _working ? null : _close),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '重新生成（旧链接马上失效），新链接的有效期：',
            style: TextStyle(fontSize: NT.fCaption, color: c.muted),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              expires,
              AButton(label: '重新生成', icon: Icons.refresh, onPressed: _working ? null : () => _create(again: true)),
            ],
          ),
        ],
        label('你在群里的名字'),
        Row(
          children: [
            Expanded(
              child: AField(controller: _name, hint: defaultOwnerName, maxLength: 20, onSubmitted: (_) => _rename()),
            ),
            const SizedBox(width: 8),
            AButton(label: '保存', onPressed: _working ? null : _rename),
          ],
        ),
        if (info != null) ...[
          label('群成员（${info.members.length}）'),
          for (final m in info.members)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Avatar(id: m.id, name: m.name, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.text))),
                        if (m.owner) ...[const SizedBox(width: 6), const Tag('主人')],
                        const SizedBox(width: 10),
                        Icon(Icons.circle, size: 8, color: m.online ? NT.ok : c.faint),
                        const SizedBox(width: 4),
                        Text(m.online ? '在线' : '不在线', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
                      ],
                    ),
                  ),
                  if (!m.owner) AButton(label: '移出', small: true, kind: BtnKind.text, onPressed: _working ? null : () => _kick(m)),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
