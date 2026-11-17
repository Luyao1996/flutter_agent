// 技能：网管自定义的标准操作流程。查看、新增、修改、删除、启用/停用、上传 md 文件（支持 Claude 技能格式，上传前先选分类）、运行
// 列表按分类折叠、可置顶、筛选（排序、归属）；用密码打开时每条标出属于哪一套，不能改的不显示修改、停用、删除
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart';
import '../ui/adaptive.dart';
import '../ui/markdown.dart';
import 'common.dart';
import 'listview.dart';

Future<List<SkillItem>> loadSkills(ChatController ctl) async =>
    asList((await ctl.api.post('/api/skills/list', {'machine': ctl.config.machineName}))['items']).map((x) => SkillItem(asMap(x))).toList();

Future<void> openSkillsPanel(BuildContext context, {String? selectId}) {
  final h = PanelRefresh();
  return pushPanel(context, title: '技能', width: 1040, actions: refreshActions(h), builder: (_) => SkillsPanel(selectId: selectId, refresh: h));
}

/// 列表接口里新加的字段
extension SkillItemMore on SkillItem {
  String get category => str(raw['category']);
  String get env => str(raw['env']);
  bool get canEdit => raw['canEdit'] != false;
}

const skillTemplate = '## 步骤\n1. 用 get_system_info 了解机器情况\n2. ……\n\n## 判断标准\n- ……\n\n## 注意事项\n- ……';

/// 上传 md：开头 --- 之间写 name、description（Claude 技能格式），否则名称取第一个标题或文件名
({String name, String description, String content}) parseSkillFile(String text, String filename) {
  var body = text, name = '', description = '';
  final fm = RegExp(r'^﻿?---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
  if (fm != null) {
    body = text.substring(fm.end);
    String field(String k) => (RegExp('^$k\\s*:\\s*(.+)\$', multiLine: true).firstMatch(fm.group(1)!)?.group(1) ?? '').trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    name = field('name');
    description = field('description');
  }
  if (name.isEmpty) {
    name = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true).firstMatch(body)?.group(1) ??
        filename.replaceAll(RegExp(r'\.(md|markdown|txt)$', caseSensitive: false), '').replaceAll(RegExp(r'^SKILL$', caseSensitive: false), '');
  }
  return (name: name.trim(), description: description, content: body.trim());
}

class SkillsPanel extends StatefulWidget {
  const SkillsPanel({super.key, this.selectId, this.refresh});
  final String? selectId;
  final PanelRefresh? refresh;
  @override
  State<SkillsPanel> createState() => _SkillsPanelState();
}

class _SkillsPanelState extends State<SkillsPanel> {
  List<SkillItem> _items = [];
  bool _loading = true;
  String? _error, _selected;
  String _q = '', _sort = 'updated', _set = 'all';
  bool _allEnvs = false;
  Map<String, dynamic>? _editing;
  ChatController get _ctl => NetbarScope.read(context).controller;
  ListPrefs get _prefs => ListPrefs.instance;
  static const _listKey = 'skills';

  @override
  void initState() {
    super.initState();
    _selected = widget.selectId;
    widget.refresh
      ?..reload = () {
        _editing = null;
        return _reload();
      }
      ..editing = () => _editing != null;
    _reload(first: true);
  }

  Future<void> _reload({bool first = false}) async {
    await _prefs.load();
    try {
      final r = await _ctl.api.post('/api/skills/list', {'machine': _ctl.config.machineName});
      _items = asList(r['items']).map((x) => SkillItem(asMap(x))).toList();
      _allEnvs = r['allEnvs'] == true;
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (first && widget.selectId != null && !isWide(context) && _selected == widget.selectId) {
      final x = _items.where((i) => i.id == widget.selectId).firstOrNull;
      _selected = null;
      if (x != null) _openDetail(x);
    }
  }

  List<SkillItem> get _visible {
    final q = _q.trim().toLowerCase();
    int by(SkillItem a, SkillItem b) => switch (_sort) {
          'uses' => b.useCount != a.useCount ? b.useCount - a.useCount : (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
          'name' => a.name.compareTo(b.name),
          _ => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
        };
    // 停用的排在后面
    return _items
        .where((x) => q.isEmpty || '${x.name}\n${x.description}\n${x.content}\n${x.category}'.toLowerCase().contains(q))
        .where((x) => _set == 'all' || x.env == _set)
        .toList()
      ..sort((a, b) => a.enabled != b.enabled ? (a.enabled ? -1 : 1) : by(a, b));
  }

  Future<bool> _leaveEdit() async {
    if (_editing != null && !await confirmDialog(context, title: '放弃修改？', message: '正在编辑的内容还没保存，确定放弃吗？', ok: '放弃', destructive: true)) return false;
    _editing = null;
    return true;
  }

  void _togglePin(SkillItem x) {
    final on = _prefs.togglePin(_listKey, x.id);
    showToast(context, on ? '已置顶，只在这台设备上生效' : '已取消置顶');
    setState(() {});
  }

  Map<String, dynamic> _draftFor(SkillItem? x) => x == null
      ? {'name': '', 'description': '', 'content': skillTemplate, 'enabled': true, 'category': ''}
      : {'id': x.id, 'name': x.name, 'description': x.description, 'content': x.content, 'enabled': x.enabled, 'category': x.category};

  List<String> get _categories => categoriesOf(_items.map((x) => x.category));

  Future<void> _edit(SkillItem? x) async {
    if (!await _leaveEdit() || !mounted) return;
    final draft = _draftFor(x);
    if (isWide(context)) return setState(() => _editing = draft);
    final saved = await pushPanel<String>(context,
        title: x == null ? '新增技能' : '修改技能', builder: (ctx) => SkillEditor(draft: draft, categories: _categories, onDone: (id) => Navigator.pop(ctx, id)));
    if (saved != null) await _saved(saved);
  }

  Future<void> _saved(String id) async {
    await _reload();
    final x = _items.where((i) => i.id == id).firstOrNull;
    if (x != null) _prefs.unfold(_listKey, x.category);
    if (mounted) {
      setState(() => _selected = id);
      showToast(context, '已保存');
    }
  }

  Future<void> _toggle(SkillItem x) async {
    try {
      await _ctl.api.post('/api/skills/toggle', {'id': x.id, 'enabled': !x.enabled, 'machine': _ctl.config.machineName});
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    }
    await _reload();
  }

  Future<bool> _delete(SkillItem x) async {
    if (!await confirmDialog(context, title: '删除技能？', message: '确定删除技能“${x.name}”吗？删除后不能恢复。', ok: '删除', destructive: true)) return false;
    try {
      await _ctl.api.post('/api/skills/delete', {'id': x.id, 'machine': _ctl.config.machineName});
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
      return false;
    }
    _selected = null;
    await _reload();
    return true;
  }

  /// 运行：关掉技能面板，回到对话里执行（输入框里的内容作为补充说明）
  void _run(SkillItem x) {
    final ctl = _ctl;
    Navigator.of(context).maybePop();
    ctl.runSkill(x);
  }

  Future<void> _upload() async {
    final category = await pickCategory(context, title: '上传 md 文件：先选分类', hint: '这次选的所有文件都放进这个分类；不填就放在“未分类”。', all: _categories);
    if (category == null) return;
    List<({String name, String text})> files;
    try {
      files = await pickTextFiles();
    } catch (_) {
      return;
    }
    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      final p = parseSkillFile(f.text, f.name);
      if (p.description.isEmpty) {
        errors.add('${f.name}：文件里没有写“什么时候用”（description），请上传后在页面上补充，或者用“新增”手动填写');
        continue;
      }
      try {
        final r = await _ctl.api.post('/api/skills/save', {'name': p.name, 'description': p.description, 'content': p.content, 'category': category, 'machine': _ctl.config.machineName});
        _selected = str(asMap(r['item'])['id']);
        ok++;
      } on ApiError catch (e) {
        errors.add('${f.name}：${e.message}');
      }
    }
    _prefs.unfold(_listKey, category);
    await _reload();
    if (mounted && files.isNotEmpty) {
      final msg = '已上传 $ok 个技能${category.isNotEmpty ? '，放在“$category”分类下' : ''}';
      errors.isEmpty ? showToast(context, msg) : await showAlert(context, '$msg，${errors.length} 个失败：\n${errors.join('\n')}');
    }
  }

  Future<void> _openDetail(SkillItem x) async {
    if (isWide(context)) {
      if (!await _leaveEdit()) return;
      return setState(() => _selected = x.id);
    }
    await pushPanel(context,
        title: '技能',
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setInner) => SkillDetail(
              item: x,
              pinned: _prefs.isPinned(_listKey, x.id),
              onPin: () => setInner(() => _togglePin(x)),
              onRun: () {
                Navigator.pop(ctx);
                _run(x);
              },
              onEdit: () async {
                Navigator.pop(ctx);
                await _edit(x);
              },
              onToggle: () async {
                Navigator.pop(ctx);
                await _toggle(x);
              },
              onDelete: () async {
                if (await _delete(x) && ctx.mounted) Navigator.pop(ctx);
              },
            )));
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final wide = isWide(context);
    final list = _visible;
    final q = _q.trim();
    if (wide && _editing == null && list.isNotEmpty && !list.any((x) => x.id == _selected)) _selected = list.first.id;
    const sorts = [('updated', '最近更新'), ('uses', '常用'), ('name', '名称')];
    final active = [
      if (_sort != 'updated') ActiveFilter('排序：${sorts.firstWhere((x) => x.$1 == _sort).$2}', () => setState(() => _sort = 'updated')),
      if (_set != 'all') ActiveFilter('归属：${envNames[_set] ?? _set}', () => setState(() => _set = 'all')),
    ];
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Text('网管定义的标准操作流程，同一类远程方式打开的所有机器共用。AI 遇到符合“什么时候用”的情况会自动按步骤执行，也可以手动运行。', style: TextStyle(fontSize: 12, color: c.muted)),
      ),
      SearchBarRow(
        placeholder: '搜索技能',
        onSearch: (v) => setState(() => _q = v),
        groups: [FilterGroup('sort', '排序', _sort, sorts), FilterGroup('set', '归属', _set, envOptions(_items.map((x) => x.env)))],
        onFilter: (name, v) => setState(() => name == 'sort' ? _sort = v : _set = v),
        onCompact: () => setState(() {}),
        active: active,
        actions: [
          AIconButton(icon: Icons.upload_file, tooltip: '上传 md 文件', size: 20, onPressed: _upload),
          AIconButton(icon: Icons.add, tooltip: '新增技能', size: 20, onPressed: () => _edit(null)),
        ],
      ),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : CategoryList<SkillItem>(
                    items: list,
                    idOf: (x) => x.id,
                    groupOf: (x) => x.category,
                    listKey: _listKey,
                    query: q,
                    empty: q.isNotEmpty || _set != 'all' ? '没有找到匹配的技能' : '还没有技能，点“+”添加一个',
                    row: (x, compact) => ListRow(
                      title: x.name,
                      query: q,
                      leading: envTag(x.env, _allEnvs),
                      subtitle: compact ? null : x.description,
                      snippet: compact || q.isEmpty || '${x.name}${x.description}'.toLowerCase().contains(q.toLowerCase()) ? null : snippetOf(x.content, q),
                      dimmed: !x.enabled,
                      selected: x.id == _selected,
                      onTap: () => _openDetail(x),
                      meta: compact ? null : '${x.enabled ? '' : '已停用 · '}使用 ${x.useCount} 次 · ${fmtTime(x.updatedAt)}',
                    ),
                  ),
      ),
    ]);
    if (!wide) return side;
    final sel = _items.where((x) => x.id == _selected).firstOrNull;
    final detail = _editing != null
        ? SkillEditor(
            key: ValueKey(_editing),
            draft: _editing!,
            categories: _categories,
            onDone: (id) async {
              setState(() => _editing = null);
              if (id != null) await _saved(id);
            })
        : sel == null
            ? const EmptyHint('从列表中选择一个技能查看，或点“+”新增', icon: Icons.auto_awesome_outlined)
            : SkillDetail(
                item: sel,
                pinned: _prefs.isPinned(_listKey, sel.id),
                onPin: () => _togglePin(sel),
                onRun: () => _run(sel),
                onEdit: () => _edit(sel),
                onToggle: () => _toggle(sel),
                onDelete: () => _delete(sel));
    return TwoPane(side: side, detail: detail);
  }
}

class SkillDetail extends StatelessWidget {
  const SkillDetail(
      {super.key, required this.item, required this.onRun, required this.onEdit, required this.onToggle, required this.onDelete, this.pinned = false, this.onPin});
  final SkillItem item;
  final VoidCallback onRun, onEdit, onToggle, onDelete;
  final bool pinned;
  final VoidCallback? onPin;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final x = item;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(x.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text)),
        if (!x.enabled) Tag('已停用', color: c.warnText),
      ]),
      const SizedBox(height: 4),
      Text(
          [
            if (x.category.isNotEmpty) '分类：${x.category}',
            '使用 ${x.useCount} 次',
            '更新于 ${fmtTime(x.updatedAt)}',
            if (x.machine.isNotEmpty) '来自 ${x.machine}',
            if (x.env.isNotEmpty) '属于 ${envNames[x.env] ?? x.env}',
          ].join(' · '),
          style: TextStyle(fontSize: 11.5, color: c.muted)),
      const SizedBox(height: 10),
      PropGrid([('什么时候用', x.description)]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AButton(label: '运行', icon: Icons.play_arrow_rounded, small: true, kind: BtnKind.primary, onPressed: x.enabled ? onRun : null),
        if (onPin != null) AButton(label: pinned ? '取消置顶' : '置顶', icon: Icons.push_pin_outlined, small: true, onPressed: onPin),
        if (x.canEdit) ...[
          AButton(label: '修改', icon: Icons.edit_outlined, small: true, onPressed: onEdit),
          AButton(label: x.enabled ? '停用' : '启用', icon: Icons.power_settings_new, small: true, onPressed: onToggle),
          AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: onDelete),
        ],
      ]),
      if (!x.canEdit) Padding(padding: const EdgeInsets.only(top: 8), child: Text(readOnlyText(x.env, usable: true), style: TextStyle(fontSize: NT.fSmall, color: c.warnText))),
      Divider(height: 24, color: c.line),
      MarkdownBody(x.content),
    ]);
  }
}

class SkillEditor extends StatefulWidget {
  const SkillEditor({super.key, required this.draft, required this.onDone, this.categories = const []});
  final Map<String, dynamic> draft;
  final List<String> categories;
  final ValueChanged<String?> onDone;
  @override
  State<SkillEditor> createState() => _SkillEditorState();
}

class _SkillEditorState extends State<SkillEditor> {
  late final _name = TextEditingController(text: str(widget.draft['name']));
  late final _desc = TextEditingController(text: str(widget.draft['description']));
  late final _category = TextEditingController(text: str(widget.draft['category']));
  late final _content = TextEditingController(text: str(widget.draft['content']));
  late bool _enabled = widget.draft['enabled'] != false;
  bool _saving = false;

  Future<void> _save() async {
    final ctl = NetbarScope.read(context).controller;
    setState(() => _saving = true);
    try {
      final r = await ctl.api.post('/api/skills/save', {
        'id': widget.draft['id'],
        'name': _name.text,
        'description': _desc.text,
        'content': _content.text,
        'enabled': _enabled,
        'category': cleanCategory(_category.text),
        'machine': ctl.config.machineName,
      });
      widget.onDone(str(asMap(r['item'])['id']));
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _category.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    return EditorLayout(
      top: [
        AField(controller: _name, label: '名称', maxLength: 40, hint: '例如：客户机开机慢标准检查', autofocus: widget.draft['id'] == null),
        const SizedBox(height: 8),
        CategoryField(controller: _category, all: widget.categories),
        const SizedBox(height: 8),
        AField(controller: _desc, label: '什么时候用', maxLength: 300, hint: '一句话说明适用情况，AI 靠它判断要不要用，例如：客户机开机或进系统很慢时'),
        const SizedBox(height: 8),
      ],
      body: (expands) =>
          AField(controller: _content, label: '步骤（支持 Markdown，写清楚每一步用什么工具、看什么结果）', expands: expands, minLines: expands ? null : 8, maxLines: expands ? null : 16, mono: true),
      bottom: [
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('启用（停用后 AI 不会使用，也不能手动运行）', style: TextStyle(fontSize: NT.fSmall, color: NetbarColors(context).text2))),
          Switch.adaptive(value: _enabled, onChanged: (v) => setState(() => _enabled = v), activeTrackColor: s.isCupertino ? null : NT.accent),
        ]),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          AButton(label: '取消', kind: BtnKind.text, onPressed: () => widget.onDone(null)),
          AButton(label: _saving ? '保存中…' : '保存', kind: BtnKind.primary, onPressed: _saving ? null : _save),
        ]),
      ],
    );
  }
}
