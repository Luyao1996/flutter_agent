// 记忆：这家网吧 / 这台机器两个范围，查看、搜索、新增、修改、删除、清空
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../ui/adaptive.dart';
import 'common.dart';

Future<void> openMemoryPanel(BuildContext context) => pushPanel(context, title: '记忆', width: 760, height: 640, builder: (_) => const MemoryPanel());

class MemoryPanel extends StatefulWidget {
  const MemoryPanel({super.key});
  @override
  State<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<MemoryPanel> {
  List<MemoryItem> _items = [];
  bool _loading = true;
  String? _error;
  late String _scope = _ctl.config.barKey.isEmpty ? 'machine' : 'bar';
  String _q = '';
  ChatController get _ctl => NetbarScope.read(context).controller;
  Map<String, dynamic> _body([Map<String, dynamic> extra = const {}]) => {'barId': _ctl.config.barKey, ...extra};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      _items = asList((await _ctl.api.post('/api/memory/list', _body()))['items']).map((x) => MemoryItem(asMap(x))).toList();
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(MemoryItem? x) async {
    final text = await promptText(context,
        title: x == null ? '新增${memoryScopeNames[_scope]}的记忆' : '修改记忆',
        initial: x?.content ?? '',
        multiline: true,
        ok: '保存',
        hint: _scope == 'bar' ? '例如：这家网吧用的是顺网计费；老板要求白天营业时间不要重启机器' : '例如：这台机器显卡驱动只能用 xx 版本；键盘 F 键坏了');
    if (text == null) return;
    try {
      await _ctl.api.post('/api/memory/save', _body({'id': x?.id, 'scope': _scope, 'content': text}));
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
      return;
    }
    await _reload();
  }

  Future<void> _delete(MemoryItem x) async {
    if (!await confirmDialog(context, title: '删除这条记忆？', message: x.content, ok: '删除', destructive: true)) return;
    try {
      await _ctl.api.post('/api/memory/delete', _body({'id': x.id}));
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    await _reload();
  }

  Future<void> _clear() async {
    final name = memoryScopeNames[_scope];
    if (!await confirmDialog(context, title: '清空$name的记忆？', message: '确定清空$name的全部记忆吗？清空后不能恢复。', ok: '清空', destructive: true)) return;
    try {
      await _ctl.api.post('/api/memory/clear', _body({'scope': _scope}));
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final cfg = _ctl.config;
    final barOk = cfg.barKey.isNotEmpty;
    final unavailable = _scope == 'bar' && !barOk;
    final count = {
      for (final sc in ['bar', 'machine']) sc: _items.where((x) => x.scope == sc).length
    };
    final q = _q.trim().toLowerCase();
    final list = _items.where((x) => x.scope == _scope && (q.isEmpty || x.content.toLowerCase().contains(q))).toList()
      ..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text('只对这家网吧或这台机器生效的事实和要求，AI 每次对话都会参考。通用的处理经验请放知识库。', style: TextStyle(fontSize: 12, color: c.muted)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Center(
            child: ASegmented<String>(value: _scope, onChanged: (v) => setState(() => _scope = v), segments: {
          'bar': barOk ? '这家网吧（${cfg.barName}）${count['bar']}' : '这家网吧（不可用）',
          'machine': '这台机器 ${count['machine']}',
        })),
      ),
      if (!barOk)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: NetbarColors.warn.withValues(alpha: .08), border: Border.all(color: NetbarColors.warn.withValues(alpha: .3)), borderRadius: BorderRadius.circular(8)),
          child: Text('网吧记忆不可用：没有网吧名称，现在只能使用这台机器的记忆。', style: TextStyle(fontSize: 12, color: c.warnText)),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(children: [
          Expanded(child: ASearchField(placeholder: '搜索记忆', onChanged: (v) => setState(() => _q = v))),
          const SizedBox(width: 8),
          AButton(label: '新增', icon: Icons.add, small: true, onPressed: unavailable ? null : () => _edit(null)),
          const SizedBox(width: 6),
          AButton(label: '清空', icon: Icons.delete_sweep_outlined, small: true, kind: BtnKind.danger, onPressed: unavailable || count[_scope] == 0 ? null : _clear),
        ]),
      ),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : unavailable
                    ? const EmptyHint('没有网吧名称，看不到这家网吧的记忆')
                    : list.isEmpty
                        ? EmptyHint(q.isNotEmpty ? '没有找到匹配的记忆' : '还没有${memoryScopeNames[_scope]}的记忆', icon: Icons.sticky_note_2_outlined)
                        : ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 16 : 0, vertical: 4), children: [
                            RowGroup(children: [
                              for (final x in list)
                                ListRow(
                                  title: x.content, meta: '${x.byAi ? 'AI 自动记下' : '手动添加'} · ${fmtTime(x.updatedAt)}',
                                  // 手机上点一下弹出“修改 / 删除”；电脑上直接给两个按钮
                                  onTap: () async {
                                    if (s.isDesktop) return _edit(x);
                                    final r = await actionSheet<String>(context, message: x.content, actions: const [
                                      SheetAction('修改', 'edit', icon: Icons.edit_outlined),
                                      SheetAction('删除', 'delete', icon: Icons.delete_outline, destructive: true),
                                    ]);
                                    if (r == 'edit') _edit(x);
                                    if (r == 'delete') _delete(x);
                                  },
                                  trailing: s.isDesktop
                                      ? Row(mainAxisSize: MainAxisSize.min, children: [
                                          AIconButton(icon: Icons.edit_outlined, tooltip: '修改', onPressed: () => _edit(x)),
                                          AIconButton(icon: Icons.delete_outline, tooltip: '删除', onPressed: () => _delete(x)),
                                        ])
                                      : null,
                                ),
                            ]),
                          ]),
      ),
    ]);
  }
}
