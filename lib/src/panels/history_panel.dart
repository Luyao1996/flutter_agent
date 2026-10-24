// 历史对话：这台机器以前的对话，点开接着处理；可以改名，调试模式下可以删除
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../ui/adaptive.dart';
import 'common.dart';

/// 历史对话列表（电脑上放在右侧抽屉，iOS 是整页，Android 是左侧抽屉）
class HistoryList extends StatefulWidget {
  const HistoryList({super.key, required this.onOpened});

  /// 打开了某个对话（用来关掉抽屉或返回）
  final VoidCallback onOpened;
  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  List<SessionSummary>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      _list = await NetbarScope.read(context).controller.listSessions();
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() {});
  }

  Future<void> _rename(SessionSummary x) async {
    final t = await promptText(context, title: '修改对话名称', initial: x.title, maxLength: 60, ok: '保存');
    if (t == null || t.trim().isEmpty || t.trim() == x.title || !mounted) return;
    await NetbarScope.read(context).controller.renameSession(x.id, t.trim());
    _reload();
  }

  Future<void> _delete(SessionSummary x) async {
    if (!await confirmDialog(context, title: '删除对话？', message: '确定删除对话“${x.title.isEmpty ? '(无标题)' : x.title}”吗？\n对话记录会全部删除，不能恢复；已经记进知识库的经验会保留。', ok: '删除', destructive: true))
      return;
    if (!mounted) return;
    if (await NetbarScope.read(context).controller.deleteSession(x.id)) _reload();
  }

  Future<void> _menu(SessionSummary x) async {
    final debug = NetbarScope.read(context).controller.config.isDebug;
    final r = await actionSheet<String>(context, title: x.title, actions: [
      const SheetAction('修改对话名称', 'rename', icon: Icons.edit_outlined),
      if (debug) const SheetAction('删除这个对话（调试模式）', 'delete', icon: Icons.delete_outline, destructive: true),
    ]);
    if (r == 'rename') _rename(x);
    if (r == 'delete') _delete(x);
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    if (_error != null) return EmptyHint(_error!);
    if (_list == null) return const EmptyHint('加载中…', loading: true);
    if (_list!.isEmpty) return const EmptyHint('这台机器还没有历史对话', icon: Icons.history);
    return RefreshIndicator.adaptive(
      onRefresh: _reload,
      child: ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 10 : 0, vertical: 6), children: [
        if (s.isDesktop)
          Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text('这台机器以前的对话。点开可以查看完整过程，并在原来的基础上接着处理。', style: TextStyle(fontSize: 11.5, color: c.muted))),
        RowGroup(children: [
          for (final x in _list!)
            ListRow(
              title: x.title.isEmpty ? '(无标题)' : x.title,
              meta: '${fmtTime(x.updatedAt)} · ${x.rounds} 轮提问${x.id == ctl.sessionId ? ' · 当前对话' : ''}${x.shared ? ' · 已分享' : ''}',
              selected: x.id == ctl.sessionId,
              onTap: () async {
                if (await ctl.openSession(x.id)) widget.onOpened();
              },
              onLongPress: s.isMobile ? () => _menu(x) : null,
              trailing: s.isDesktop
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      AIconButton(icon: Icons.edit_outlined, tooltip: '修改对话名称', size: 15, onPressed: () => _rename(x)),
                      if (ctl.config.isDebug) AIconButton(icon: Icons.delete_outline, tooltip: '删除这个对话（调试模式）', size: 15, color: c.dangerText, onPressed: () => _delete(x)),
                    ])
                  : null,
            ),
        ]),
        if (s.isMobile)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text('长按一个对话可以改名${ctl.config.isDebug ? '或删除' : ''}', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.faint))),
      ]),
    );
  }
}
