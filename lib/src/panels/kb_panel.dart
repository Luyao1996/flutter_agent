// 知识库：经验 / 背景知识，搜索、按网吧属性筛选、排序，查看、修改、删除、新增，背景知识可以上传 md 文件
import 'package:flutter/material.dart';

import '../api.dart';
import '../config.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart';
import '../ui/adaptive.dart';
import '../ui/markdown.dart';
import 'common.dart';

Future<void> openKbPanel(BuildContext context, {String type = 'experience', String? selectId}) =>
    pushPanel(context, title: '知识库', width: 1040, builder: (_) => KbPanel(type: type, selectId: selectId));

class KbPanel extends StatefulWidget {
  const KbPanel({super.key, this.type = 'experience', this.selectId});
  final String type;
  final String? selectId;
  @override
  State<KbPanel> createState() => _KbPanelState();
}

class _KbPanelState extends State<KbPanel> {
  List<KbItem> _items = [];
  bool _loading = true;
  String? _error;
  late String _tab = widget.type;
  String _q = '';
  final Map<String, String> _filters = {for (final k in netbarFields) k: ''};
  String _sort = 'updated';
  String? _selected;
  Map<String, dynamic>? _editing; // 宽屏时在右侧编辑
  ChatController get _ctl => NetbarScope.read(context).controller;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectId;
    _reload();
  }

  Future<void> _reload() async {
    try {
      final r = await _ctl.api.post('/api/kb/list', {'machine': _ctl.config.machineName});
      _items = asList(r['items']).map((x) => KbItem(asMap(x))).toList();
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    // 从对话里点开某条经验：手机上直接打开详情页
    if (widget.selectId != null && !isWide(context) && _selected == widget.selectId) {
      final x = _items.where((i) => i.id == widget.selectId).firstOrNull;
      _selected = null;
      if (x != null) _openDetail(x);
    }
  }

  List<KbItem> get _visible {
    final q = _q.trim().toLowerCase();
    final isExp = _tab == 'experience';
    final list = _items
        .where((x) => x.type == _tab && (q.isEmpty || '${x.title}\n${x.content}'.toLowerCase().contains(q)))
        .where((x) => !isExp || _filters.entries.every((f) => f.value.isEmpty || x.attr(f.key) == f.value))
        .toList();
    int byUpdated(KbItem a, KbItem b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
    list.sort(switch (isExp ? _sort : 'updated') {
      'ratio' => (a, b) {
          final r = (b.stats.ratio ?? -1).compareTo(a.stats.ratio ?? -1);
          return r != 0
              ? r
              : b.stats.calls != a.stats.calls
                  ? b.stats.calls - a.stats.calls
                  : byUpdated(a, b);
        },
      'calls' => (a, b) => b.stats.calls != a.stats.calls ? b.stats.calls - a.stats.calls : byUpdated(a, b),
      _ => byUpdated,
    });
    return list;
  }

  Future<void> _upload() async {
    List<({String name, String text})> files;
    try {
      files = await pickTextFiles();
    } catch (_) {
      return;
    }
    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      final title = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true).firstMatch(f.text)?.group(1) ?? f.name.replaceAll(RegExp(r'\.(md|markdown|txt)$', caseSensitive: false), '');
      try {
        final r = await _ctl.api.post('/api/kb/save', {'type': 'background', 'title': title, 'content': f.text, 'machine': _ctl.config.machineName});
        _selected = str(asMap(r['item'])['id']);
        ok++;
      } on ApiError catch (e) {
        errors.add('${f.name}：${e.message}');
      }
    }
    await _reload();
    if (mounted && files.isNotEmpty) showToast(context, '已上传 $ok 个文件${errors.isEmpty ? '' : '，${errors.length} 个失败：${errors.join('；')}'}');
  }

  Map<String, dynamic> _draftFor(KbItem? x) => x == null
      ? {'type': _tab, 'title': '', 'content': '', if (_tab == 'experience') ..._ctl.config.netbar}
      : {'id': x.id, 'type': x.type, 'title': x.title, 'content': x.content, for (final k in netbarFields) k: x.attr(k)};

  Future<void> _edit(KbItem? x) async {
    final draft = _draftFor(x);
    if (isWide(context)) return setState(() => _editing = draft);
    final saved = await pushPanel<String>(context,
        title: x == null ? '新增${kbTypeNames[_tab]}' : '修改${kbTypeNames[x.type]}', builder: (ctx) => KbEditor(draft: draft, onDone: (id) => Navigator.pop(ctx, id)));
    if (saved != null) {
      await _reload();
      if (mounted) showToast(context, '已保存');
    }
  }

  Future<bool> _delete(KbItem x) async {
    if (!await confirmDialog(context, title: '删除这条${kbTypeNames[x.type]}？', message: '确定删除“${x.title}”吗？删除后不能恢复。', ok: '删除', destructive: true)) return false;
    try {
      await _ctl.api.post('/api/kb/delete', {'id': x.id, 'machine': _ctl.config.machineName});
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
      return false;
    }
    _selected = null;
    await _reload();
    return true;
  }

  Future<void> _openDetail(KbItem x) async {
    if (isWide(context))
      return setState(() {
        _selected = x.id;
        _editing = null;
      });
    await pushPanel(context,
        title: kbTypeNames[x.type]!,
        builder: (ctx) => KbDetail(
              item: x,
              onEdit: () async {
                Navigator.pop(ctx);
                await _edit(x);
              },
              onDelete: () async {
                if (await _delete(x) && ctx.mounted) Navigator.pop(ctx);
              },
            ));
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final isExp = _tab == 'experience';
    final list = _visible;
    final count = {
      for (final t in ['experience', 'background']) t: _items.where((x) => x.type == t).length
    };
    final exps = _items.where((x) => x.isExperience);
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Center(
            child: ASegmented<String>(
                value: _tab,
                segments: {'experience': '经验 ${count['experience']}', 'background': '背景知识 ${count['background']}'},
                onChanged: (v) => setState(() {
                      _tab = v;
                      _editing = null;
                    }))),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ASearchField(placeholder: '搜索标题或内容', onChanged: (v) => setState(() => _q = v))),
      if (isExp)
        // 高度跟着内容走（系统字体放大时不会被截掉）
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(children: [
            for (final k in netbarFields)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterButton(
                    label: netbarNames[k]!,
                    value: _filters[k]!,
                    onChanged: (v) => setState(() => _filters[k] = v),
                    options: (exps.map((x) => x.attr(k)).where((v) => v.isNotEmpty).toSet().toList()..sort())),
              ),
            FilterButton(
                label: '排序',
                allLabel: '最近更新',
                value: {'ratio': '有效比从高到低', 'calls': '调用次数从多到少'}[_sort] ?? '',
                options: const ['有效比从高到低', '调用次数从多到少'],
                onChanged: (v) => setState(() => _sort = v == '有效比从高到低'
                    ? 'ratio'
                    : v == '调用次数从多到少'
                        ? 'calls'
                        : 'updated')),
          ]),
        ),
      ToolbarRow(children: [
        AButton(label: '新增', icon: Icons.add, small: true, onPressed: () => _edit(null)),
        if (!isExp) AButton(label: '上传 md 文件', icon: Icons.upload_file, small: true, onPressed: _upload),
      ]),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : list.isEmpty
                    ? EmptyHint(_q.isNotEmpty || _filters.values.any((v) => v.isNotEmpty) ? '没有找到匹配的内容' : '还没有${kbTypeNames[_tab]}')
                    : ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 12 : 0, vertical: 4), children: [
                        RowGroup(children: [
                          for (final x in list)
                            ListRow(
                              title: x.title,
                              selected: x.id == _selected,
                              onTap: () => _openDetail(x),
                              chips: isExp
                                  ? [
                                      for (final k in netbarFields)
                                        if (x.attr(k).isNotEmpty) Tag(x.attr(k))
                                    ]
                                  : const [],
                              meta: isExp
                                  ? '调用 ${x.stats.calls} · 有效 ${x.stats.effective} · 有效比 ${x.stats.ratioText}'
                                  : '${fmtTime(x.updatedAt)}${x.machine.isNotEmpty ? ' · ${x.machine}' : ''}',
                            ),
                        ]),
                      ]),
      ),
    ]);
    if (!isWide(context)) return side;
    final sel = _items.where((x) => x.id == _selected && x.type == _tab).firstOrNull;
    final detail = _editing != null
        ? KbEditor(
            key: ValueKey(_editing),
            draft: _editing!,
            onDone: (id) async {
              setState(() {
                _editing = null;
                if (id != null) _selected = id;
              });
              if (id != null) await _reload();
            })
        : sel == null
            ? EmptyHint('从列表中选择一条查看，或点“新增”', icon: Icons.menu_book_outlined)
            : KbDetail(item: sel, onEdit: () => _edit(sel), onDelete: () => _delete(sel));
    return TwoPane(side: Container(color: c.fill.withValues(alpha: .02), child: side), detail: detail);
  }
}

/// 一条知识的详情
class KbDetail extends StatelessWidget {
  const KbDetail({super.key, required this.item, required this.onEdit, required this.onDelete});
  final KbItem item;
  final VoidCallback onEdit, onDelete;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final x = item;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      Text(x.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text)),
      const SizedBox(height: 4),
      Text('${x.source == 'ai' ? 'AI 自动记录' : '手动编辑'} · 更新于 ${fmtTime(x.updatedAt)}${x.machine.isNotEmpty ? ' · 来自 ${x.machine}' : ''}',
          style: TextStyle(fontSize: 11.5, color: c.muted)),
      if (x.isExperience) ...[
        const SizedBox(height: 10),
        PropGrid([
          for (final k in netbarFields) (netbarNames[k]!, x.attr(k)),
          ('调用次数', '${x.stats.calls}'),
          ('有效次数', '${x.stats.effective}'),
          ('有效比', x.stats.ratioText),
        ]),
      ],
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        AButton(label: '修改', icon: Icons.edit_outlined, small: true, onPressed: onEdit),
        AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: onDelete),
      ]),
      Divider(height: 24, color: c.line),
      MarkdownBody(x.content),
    ]);
  }
}

/// 新增、修改一条知识
class KbEditor extends StatefulWidget {
  const KbEditor({super.key, required this.draft, required this.onDone});
  final Map<String, dynamic> draft;

  /// 保存成功传新的编号，取消传 null
  final ValueChanged<String?> onDone;
  @override
  State<KbEditor> createState() => _KbEditorState();
}

class _KbEditorState extends State<KbEditor> {
  late final _title = TextEditingController(text: str(widget.draft['title']));
  late final _content = TextEditingController(text: str(widget.draft['content']));
  late final _attrs = {for (final k in netbarFields) k: TextEditingController(text: str(widget.draft[k]))};
  bool _saving = false;
  bool get _isExp => widget.draft['type'] == 'experience';

  Future<void> _save() async {
    final ctl = NetbarScope.read(context).controller;
    setState(() => _saving = true);
    try {
      final r = await ctl.api.post('/api/kb/save', {
        'id': widget.draft['id'],
        'type': widget.draft['type'],
        'title': _title.text,
        'content': _content.text,
        'machine': ctl.config.machineName,
        if (_isExp) 'netbar': {for (final e in _attrs.entries) e.key: e.value.text},
      });
      widget.onDone(str(asMap(r['item'])['id']));
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    for (final c in _attrs.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.draft['id'] == null;
    return EditorLayout(
      top: [
        Text('${isNew ? '新增' : '修改'}${kbTypeNames[widget.draft['type']]}', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: NetbarColors(context).text)),
        const SizedBox(height: 12),
        AField(controller: _title, label: '标题', maxLength: 100, autofocus: isNew, hint: _isExp ? '例如：任务栏和桌面图标消失' : '例如：本店客户机配置和还原系统说明'),
        if (_isExp) ...[
          const SizedBox(height: 8),
          LayoutBuilder(builder: (ctx, box) {
            final w = box.maxWidth >= 600 ? (box.maxWidth - 24) / 4 : (box.maxWidth - 8) / 2;
            return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final k in netbarFields) SizedBox(width: w, child: AField(controller: _attrs[k]!, label: netbarNames[k], maxLength: 64))]);
          }),
        ],
        const SizedBox(height: 8),
      ],
      body: (expands) => AField(controller: _content, label: '内容（支持 Markdown 格式）', expands: expands, minLines: expands ? null : 8, maxLines: expands ? null : 16, mono: true),
      bottom: [
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          AButton(label: '取消', kind: BtnKind.text, onPressed: () => widget.onDone(null)),
          AButton(label: _saving ? '保存中…' : '保存', kind: BtnKind.primary, onPressed: _saving ? null : _save),
        ]),
      ],
    );
  }
}
