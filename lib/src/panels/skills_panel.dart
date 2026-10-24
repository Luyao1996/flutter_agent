// 技能：网管自定义的标准操作流程。查看、新增、修改、删除、启用/停用、上传 md 文件（支持 Claude 技能格式）、运行
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart';
import '../ui/adaptive.dart';
import '../ui/markdown.dart';
import 'common.dart';

Future<List<SkillItem>> loadSkills(ChatController ctl) async =>
    asList((await ctl.api.post('/api/skills/list', {'machine': ctl.config.machineName}))['items']).map((x) => SkillItem(asMap(x))).toList();

Future<void> openSkillsPanel(BuildContext context, {String? selectId}) => pushPanel(context, title: '技能', width: 1040, builder: (_) => SkillsPanel(selectId: selectId));

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
  const SkillsPanel({super.key, this.selectId});
  final String? selectId;
  @override
  State<SkillsPanel> createState() => _SkillsPanelState();
}

class _SkillsPanelState extends State<SkillsPanel> {
  List<SkillItem> _items = [];
  bool _loading = true;
  String? _error, _selected;
  String _q = '';
  Map<String, dynamic>? _editing;
  ChatController get _ctl => NetbarScope.read(context).controller;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectId;
    _reload();
  }

  Future<void> _reload() async {
    try {
      _items = await loadSkills(_ctl);
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (widget.selectId != null && !isWide(context) && _selected == widget.selectId) {
      final x = _items.where((i) => i.id == widget.selectId).firstOrNull;
      _selected = null;
      if (x != null) _openDetail(x);
    }
  }

  List<SkillItem> get _visible {
    final q = _q.trim().toLowerCase();
    return _items.where((x) => q.isEmpty || '${x.name}\n${x.description}\n${x.content}'.toLowerCase().contains(q)).toList()
      ..sort((a, b) => a.enabled != b.enabled ? (a.enabled ? -1 : 1) : (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
  }

  Map<String, dynamic> _draftFor(SkillItem? x) => x == null
      ? {'name': '', 'description': '', 'content': skillTemplate, 'enabled': true}
      : {'id': x.id, 'name': x.name, 'description': x.description, 'content': x.content, 'enabled': x.enabled};

  Future<void> _edit(SkillItem? x) async {
    final draft = _draftFor(x);
    if (isWide(context)) return setState(() => _editing = draft);
    final saved = await pushPanel<String>(context, title: x == null ? '新增技能' : '修改技能', builder: (ctx) => SkillEditor(draft: draft, onDone: (id) => Navigator.pop(ctx, id)));
    if (saved != null) {
      await _reload();
      if (mounted) showToast(context, '已保存');
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
        final r = await _ctl.api.post('/api/skills/save', {'name': p.name, 'description': p.description, 'content': p.content, 'machine': _ctl.config.machineName});
        _selected = str(asMap(r['item'])['id']);
        ok++;
      } on ApiError catch (e) {
        errors.add('${f.name}：${e.message}');
      }
    }
    await _reload();
    if (mounted && files.isNotEmpty) showToast(context, '已上传 $ok 个技能${errors.isEmpty ? '' : '，${errors.length} 个失败：${errors.join('；')}'}');
  }

  Future<void> _openDetail(SkillItem x) async {
    if (isWide(context))
      return setState(() {
        _selected = x.id;
        _editing = null;
      });
    await pushPanel(context,
        title: '技能',
        builder: (ctx) => SkillDetail(
              item: x,
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
            ));
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final list = _visible;
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text('网管定义的标准操作流程，所有机器共用。AI 遇到符合“什么时候用”的情况会自动按步骤执行，也可以手动运行。', style: TextStyle(fontSize: 12, color: c.muted)),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ASearchField(placeholder: '搜索技能', onChanged: (v) => setState(() => _q = v))),
      ToolbarRow(children: [
        AButton(label: '新增', icon: Icons.add, small: true, onPressed: () => _edit(null)),
        AButton(label: '上传 md 文件', icon: Icons.upload_file, small: true, onPressed: _upload),
      ]),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : list.isEmpty
                    ? EmptyHint(_q.isNotEmpty ? '没有找到匹配的技能' : '还没有技能，点“新增”添加一个')
                    : ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 12 : 0, vertical: 4), children: [
                        RowGroup(children: [
                          for (final x in list)
                            ListRow(
                              title: x.name,
                              subtitle: x.description,
                              dimmed: !x.enabled,
                              selected: x.id == _selected,
                              onTap: () => _openDetail(x),
                              meta: '${x.enabled ? '' : '已停用 · '}使用 ${x.useCount} 次 · ${fmtTime(x.updatedAt)}',
                            ),
                        ]),
                      ]),
      ),
    ]);
    if (!isWide(context)) return side;
    final sel = _items.where((x) => x.id == _selected).firstOrNull;
    final detail = _editing != null
        ? SkillEditor(
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
            ? const EmptyHint('从列表中选择一个技能查看，或点“新增”', icon: Icons.auto_awesome_outlined)
            : SkillDetail(item: sel, onRun: () => _run(sel), onEdit: () => _edit(sel), onToggle: () => _toggle(sel), onDelete: () => _delete(sel));
    return TwoPane(side: side, detail: detail);
  }
}

class SkillDetail extends StatelessWidget {
  const SkillDetail({super.key, required this.item, required this.onRun, required this.onEdit, required this.onToggle, required this.onDelete});
  final SkillItem item;
  final VoidCallback onRun, onEdit, onToggle, onDelete;
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
      Text('使用 ${x.useCount} 次 · 更新于 ${fmtTime(x.updatedAt)}${x.machine.isNotEmpty ? ' · 来自 ${x.machine}' : ''}', style: TextStyle(fontSize: 11.5, color: c.muted)),
      const SizedBox(height: 10),
      PropGrid([('什么时候用', x.description)]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        AButton(label: '运行', icon: Icons.play_arrow_rounded, small: true, kind: BtnKind.primary, onPressed: x.enabled ? onRun : null),
        AButton(label: '修改', icon: Icons.edit_outlined, small: true, onPressed: onEdit),
        AButton(label: x.enabled ? '停用' : '启用', icon: Icons.power_settings_new, small: true, onPressed: onToggle),
        AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: onDelete),
      ]),
      Divider(height: 24, color: c.line),
      MarkdownBody(x.content),
    ]);
  }
}

class SkillEditor extends StatefulWidget {
  const SkillEditor({super.key, required this.draft, required this.onDone});
  final Map<String, dynamic> draft;
  final ValueChanged<String?> onDone;
  @override
  State<SkillEditor> createState() => _SkillEditorState();
}

class _SkillEditorState extends State<SkillEditor> {
  late final _name = TextEditingController(text: str(widget.draft['name']));
  late final _desc = TextEditingController(text: str(widget.draft['description']));
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
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AField(controller: _name, label: '名称', maxLength: 40, hint: '例如：客户机开机慢标准检查', autofocus: widget.draft['id'] == null),
        const SizedBox(height: 8),
        AField(controller: _desc, label: '什么时候用', maxLength: 300, hint: '一句话说明适用情况，AI 靠它判断要不要用，例如：客户机开机或进系统很慢时'),
        const SizedBox(height: 8),
        Expanded(child: AField(controller: _content, label: '步骤（支持 Markdown，写清楚每一步用什么工具、看什么结果）', expands: true, mono: true)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('启用（停用后 AI 不会使用，也不能手动运行）', style: TextStyle(fontSize: 13, color: NetbarColors(context).text2))),
          Switch.adaptive(value: _enabled, onChanged: (v) => setState(() => _enabled = v), activeTrackColor: s.isCupertino ? null : NetbarColors.accent),
        ]),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          AButton(label: '取消', kind: BtnKind.text, onPressed: () => widget.onDone(null)),
          const SizedBox(width: 8),
          AButton(label: _saving ? '保存中…' : '保存', kind: BtnKind.primary, onPressed: _saving ? null : _save),
        ]),
      ]),
    );
  }
}
