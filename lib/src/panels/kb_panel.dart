// 知识库：经验 | 资料库（以前的“背景知识”已经并进资料库，见 library_panel.dart）
// 经验：搜索、按分类 / 网吧 / 分组折叠，筛选（网吧属性、排序、来源、归属），查看、修改、删除、新增、置顶
// 用密码打开（列表接口回 allEnvs）时每条前面标出属于哪一套；不能改的（canEdit = false）不显示修改、删除，并说明原因
import 'package:flutter/material.dart';

import '../api.dart';
import '../config.dart';
import '../controller.dart';
import '../models.dart';
import '../ui/adaptive.dart';
import '../ui/markdown.dart';
import 'common.dart';
import 'library_panel.dart';
import 'listview.dart';

/// 打开知识库：type 是 experience（经验，默认）或 library（资料库；旧的 background 也打开资料库）；
/// selectId：直接打开这一条（资料库的是“lib:编号”或编号）
Future<void> openKbPanel(BuildContext context, {String type = 'experience', String? selectId}) {
  final h = PanelRefresh();
  return pushPanel(context, title: '知识库', width: 1100, actions: refreshActions(h), builder: (_) => KbPanel(type: type, selectId: selectId, refresh: h));
}

/// 列表接口里新加的字段
extension KbItemMore on KbItem {
  String get category => str(raw['category']);
  String get env => str(raw['env']);
  bool get canEdit => raw['canEdit'] != false;
}

const kbSourceNames = {'ai': 'AI 自动记录', 'manual': '手动编辑'};
const kbGroups = [('netbarName', '按网吧'), ('netbarGroup', '按分组'), ('category', '按分类'), ('none', '不分组')];
const kbSorts = [('updated', '最近更新'), ('ratio', '有效比从高到低'), ('calls', '调用次数从多到少')];

class KbPanel extends StatefulWidget {
  const KbPanel({super.key, this.type = 'experience', this.selectId, this.refresh});
  final String type;
  final String? selectId;
  final PanelRefresh? refresh;
  @override
  State<KbPanel> createState() => _KbPanelState();
}

class _KbPanelState extends State<KbPanel> {
  List<KbItem> _items = [];
  bool _allEnvs = false;
  bool _loading = true;
  String? _error;
  late String _tab = widget.type == 'library' || widget.type == 'background' ? 'library' : 'experience';
  String _q = '';
  final Map<String, String> _filters = {for (final k in netbarFields) k: ''};
  String _sort = 'updated', _source = 'all', _set = 'all', _group = 'netbarName';
  String? _selected;
  int? _libCount;
  final _libHook = PanelRefresh();
  Map<String, dynamic>? _editing; // 宽屏时在右侧编辑
  ChatController get _ctl => NetbarScope.read(context).controller;
  ListPrefs get _prefs => ListPrefs.instance;
  String get _listKey => 'kb-experience-$_group';
  static const _pinKey = 'kb-experience';

  @override
  void initState() {
    super.initState();
    if (_tab == 'experience') _selected = widget.selectId;
    widget.refresh
      ?..reload = () async {
        _editing = null;
        await Future.wait([_reload(), if (_libHook.reload != null) _libHook.reload!()]);
      }
      ..editing = () => _editing != null || _libHook.editing?.call() == true;
    _reload(first: true);
  }

  Future<void> _reload({bool first = false}) async {
    await _prefs.load();
    _group = _prefs.getString('kbGroup', 'netbarName');
    try {
      final r = await _ctl.api.post('/api/kb/list', {'machine': _ctl.config.machineName});
      _items = asList(r['items']).map((x) => KbItem(asMap(x))).toList();
      _allEnvs = r['allEnvs'] == true;
      _error = null;
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    // 从对话里点开某条经验：手机上直接打开详情页
    if (first && widget.selectId != null && _tab == 'experience' && !isWide(context)) {
      final x = _items.where((i) => i.id == widget.selectId).firstOrNull;
      _selected = null;
      if (x != null) _openDetail(x);
    }
  }

  Iterable<KbItem> get _exps => _items.where((x) => x.isExperience);

  List<KbItem> get _visible {
    final q = _q.trim().toLowerCase();
    final list = _exps
        .where((x) => q.isEmpty || '${x.title}\n${x.content}\n${x.category}'.toLowerCase().contains(q))
        .where((x) => _filters.entries.every((f) => f.value.isEmpty || x.attr(f.key) == f.value))
        .where((x) => _source == 'all' || (_source == 'ai') == (x.source == 'ai'))
        .where((x) => _set == 'all' || x.env == _set)
        .toList();
    int byUpdated(KbItem a, KbItem b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
    list.sort(switch (_sort) {
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

  Future<bool> _leaveEdit() async {
    if (_editing != null && !await confirmDialog(context, title: '放弃修改？', message: '正在编辑的内容还没保存，确定放弃吗？', ok: '放弃', destructive: true)) return false;
    _editing = null;
    return true;
  }

  Map<String, dynamic> _draftFor(KbItem? x) => x == null
      ? {'type': 'experience', 'title': '', 'content': '', 'category': '', ..._ctl.config.netbar}
      : {'id': x.id, 'type': x.type, 'title': x.title, 'content': x.content, 'category': x.category, for (final k in netbarFields) k: x.attr(k)};

  Future<void> _edit(KbItem? x) async {
    if (!await _leaveEdit() || !mounted) return;
    final draft = _draftFor(x);
    final cats = categoriesOf(_exps.map((e) => e.category));
    if (isWide(context)) return setState(() => _editing = draft);
    final saved = await pushPanel<String>(context, title: x == null ? '新增经验' : '修改经验', builder: (ctx) => KbEditor(draft: draft, categories: cats, onDone: (id) => Navigator.pop(ctx, id)));
    if (saved != null) await _saved(saved);
  }

  Future<void> _saved(String id) async {
    await _reload();
    final x = _items.where((i) => i.id == id).firstOrNull;
    if (x != null) _prefs.unfold(_listKey, _group == 'category' ? x.category : (_group == 'none' ? '' : x.attr(_group)));
    if (mounted) {
      setState(() => _selected = id);
      showToast(context, '已保存');
    }
  }

  Future<bool> _delete(KbItem x) async {
    if (!await confirmDialog(context, title: '删除这条经验？', message: '确定删除“${x.title}”吗？删除后不能恢复。', ok: '删除', destructive: true)) return false;
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

  void _togglePin(KbItem x) {
    final on = _prefs.togglePin(_pinKey, x.id);
    showToast(context, on ? '已置顶，只在这台设备上生效' : '已取消置顶');
    setState(() {});
  }

  Future<void> _openDetail(KbItem x) async {
    if (isWide(context)) {
      if (!await _leaveEdit()) return;
      return setState(() => _selected = x.id);
    }
    await pushPanel(context,
        title: '经验',
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setInner) => KbDetail(
                  item: x,
                  pinned: _prefs.isPinned(_pinKey, x.id),
                  onPin: () => setInner(() => _togglePin(x)),
                  onEdit: () async {
                    Navigator.pop(ctx);
                    await _edit(x);
                  },
                  onDelete: () async {
                    if (await _delete(x) && ctx.mounted) Navigator.pop(ctx);
                  },
                )));
  }

  /// 换标签页：两边的内容（包括没保存的编辑）都留着，切回来还在
  void _setTab(String t) {
    setState(() => _tab = t);
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final libSel = widget.type == 'library' || widget.type == 'background' ? widget.selectId?.replaceFirst('lib:', '') : null;
    final tabs = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Center(
          child: ASegmented<String>(value: _tab, segments: {'experience': '经验 ${_exps.length}', 'library': '资料库${_libCount == null ? '' : ' $_libCount'}'}, onChanged: _setTab)),
    );
    // 资料库一直挂着（切回来时不用重新加载，文件数也能显示在标签上）
    final lib = LibraryView(selectId: libSel, hook: _libHook, onCount: (n) => WidgetsBinding.instance.addPostFrameCallback((_) => mounted && _libCount != n ? setState(() => _libCount = n) : null));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      tabs,
      Expanded(
        child: IndexedStack(index: _tab == 'library' ? 1 : 0, sizing: StackFit.expand, children: [
          _experience(c),
          lib,
        ]),
      ),
    ]);
  }

  Widget _experience(NetbarColors c) {
    final wide = isWide(context);
    final list = _visible;
    final q = _q.trim();
    if (wide && _editing == null && list.isNotEmpty && !list.any((x) => x.id == _selected)) _selected = list.first.id;
    final exps = _exps.toList();
    final groups = [
      FilterGroup('group', '分组方式', _group, kbGroups),
      FilterGroup('sort', '排序', _sort, kbSorts),
      for (final k in netbarFields)
        FilterGroup(k, netbarNames[k]!, _filters[k]!.isEmpty ? 'all' : _filters[k]!, [
          ('all', '全部${netbarNames[k]}'),
          for (final v in exps.map((x) => x.attr(k)).where((v) => v.isNotEmpty).toSet().toList()..sort()) (v, v),
        ]),
      FilterGroup('source', '来源', _source, exps.any((x) => x.source == 'ai') && exps.any((x) => x.source != 'ai') ? const [('all', '全部'), ('manual', '手动'), ('ai', 'AI 记的')] : const []),
      FilterGroup('set', '归属', _set, envOptions(exps.map((x) => x.env))),
    ];
    final active = [
      for (final k in netbarFields)
        if (_filters[k]!.isNotEmpty) ActiveFilter('${netbarNames[k]}：${_filters[k]}', () => setState(() => _filters[k] = '')),
      if (_sort != 'updated') ActiveFilter('排序：${kbSorts.firstWhere((s) => s.$1 == _sort).$2}', () => setState(() => _sort = 'updated')),
      if (_source != 'all') ActiveFilter('来源：${_source == 'ai' ? 'AI 记的' : '手动'}', () => setState(() => _source = 'all')),
      if (_set != 'all') ActiveFilter('归属：${envNames[_set] ?? _set}', () => setState(() => _set = 'all')),
    ];
    void onFilter(String name, String v) => setState(() {
          switch (name) {
            case 'group':
              _group = v;
              _prefs.setString('kbGroup', v);
            case 'sort':
              _sort = v;
            case 'source':
              _source = v;
            case 'set':
              _set = v;
            default:
              _filters[name] = v == 'all' ? '' : v;
          }
        });
    final narrowed = q.isNotEmpty || active.isNotEmpty;
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SearchBarRow(
        placeholder: '搜索经验',
        onSearch: (v) => setState(() => _q = v),
        groups: groups,
        onFilter: onFilter,
        onCompact: () => setState(() {}),
        active: active,
        actions: [AIconButton(icon: Icons.add, tooltip: '新增经验', size: 20, onPressed: () => _edit(null))],
      ),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : CategoryList<KbItem>(
                    items: list,
                    idOf: (x) => x.id,
                    listKey: _listKey,
                    pinKey: _pinKey,
                    query: q,
                    groupOf: _group == 'none' ? null : (x) => _group == 'category' ? x.category : x.attr(_group),
                    empty: narrowed ? '没有找到匹配的内容' : '还没有经验',
                    row: (x, compact) => ListRow(
                      title: x.title,
                      query: q,
                      leading: envTag(x.env, _allEnvs),
                      selected: x.id == _selected,
                      onTap: () => _openDetail(x),
                      snippet: compact || q.isEmpty || x.title.toLowerCase().contains(q.toLowerCase()) ? null : snippetOf(x.content, q),
                      chips: compact
                          ? const []
                          : [
                              for (final k in netbarFields)
                                if (x.attr(k).isNotEmpty) Tag(x.attr(k))
                            ],
                      meta: compact ? null : '调用 ${x.stats.calls} · 有效 ${x.stats.effective} · 有效比 ${x.stats.ratioText}',
                    ),
                  ),
      ),
    ]);
    if (!wide) return side;
    final sel = _items.where((x) => x.id == _selected && x.isExperience).firstOrNull;
    final detail = _editing != null
        ? KbEditor(
            key: ValueKey(_editing),
            draft: _editing!,
            categories: categoriesOf(_exps.map((e) => e.category)),
            onDone: (id) async {
              setState(() => _editing = null);
              if (id != null) await _saved(id);
            })
        : sel == null
            ? const EmptyHint('从列表中选择一条查看，或点“+”新增', icon: Icons.menu_book_outlined)
            : KbDetail(
                item: sel,
                pinned: _prefs.isPinned(_pinKey, sel.id),
                onPin: () => _togglePin(sel),
                onEdit: () => _edit(sel),
                onDelete: () => _delete(sel));
    return TwoPane(side: side, detail: detail);
  }
}

/// 一条经验的详情
class KbDetail extends StatelessWidget {
  const KbDetail({super.key, required this.item, required this.onEdit, required this.onDelete, this.pinned = false, this.onPin});
  final KbItem item;
  final VoidCallback onEdit, onDelete;
  final bool pinned;
  final VoidCallback? onPin;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final x = item;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      Text(x.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text)),
      const SizedBox(height: 4),
      Text(
          [
            if (x.category.isNotEmpty) '分类：${x.category}',
            kbSourceNames[x.source] ?? '手动编辑',
            '更新于 ${fmtTime(x.updatedAt)}',
            if (x.machine.isNotEmpty) '来自 ${x.machine}',
            if (x.env.isNotEmpty) '属于 ${envNames[x.env] ?? x.env}',
          ].join(' · '),
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
      if (!x.canEdit) Padding(padding: const EdgeInsets.only(top: 8), child: Text(readOnlyText(x.env), style: TextStyle(fontSize: NT.fSmall, color: c.warnText))),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (x.canEdit) AButton(label: '修改', icon: Icons.edit_outlined, small: true, onPressed: onEdit),
        if (onPin != null) AButton(label: pinned ? '取消置顶' : '置顶', icon: Icons.push_pin_outlined, small: true, onPressed: onPin),
        if (x.canEdit) AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: onDelete),
      ]),
      Divider(height: 24, color: c.line),
      MarkdownBody(x.content),
    ]);
  }
}

/// 新增、修改一条经验
class KbEditor extends StatefulWidget {
  const KbEditor({super.key, required this.draft, required this.onDone, this.categories = const []});
  final Map<String, dynamic> draft;
  final List<String> categories;

  /// 保存成功传新的编号，取消传 null
  final ValueChanged<String?> onDone;
  @override
  State<KbEditor> createState() => _KbEditorState();
}

class _KbEditorState extends State<KbEditor> {
  late final _title = TextEditingController(text: str(widget.draft['title']));
  late final _category = TextEditingController(text: str(widget.draft['category']));
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
        'category': cleanCategory(_category.text),
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
    _category.dispose();
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
        Text('${isNew ? '新增' : '修改'}${kbTypeNames[widget.draft['type']] ?? '经验'}',
            style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: NetbarColors(context).text)),
        const SizedBox(height: 12),
        AField(controller: _title, label: '标题', maxLength: 100, autofocus: isNew, hint: _isExp ? '例如：任务栏和桌面图标消失' : '例如：本店客户机配置和还原系统说明'),
        const SizedBox(height: 8),
        CategoryField(controller: _category, all: widget.categories),
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
