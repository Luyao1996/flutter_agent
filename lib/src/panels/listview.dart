// 知识库、技能、工具三个面板共用的列表（对应网页版 listview.js）：
//   按分类折叠分组（最多两级“云启动/日志”，分组后面显示条数）、置顶、搜索时标出命中的字和内容里命中的那一句、
//   搜索框 + “筛选”（排序、归属等收进筛选面板，用了的条件以小标签显示在搜索框下面）、紧凑模式、选分类、刷新按钮
// 折叠、置顶、紧凑模式只存在这台设备上（SharedPreferences，键名 netbar_ops.lv.…），不影响别人
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../ui/adaptive.dart';
import 'common.dart';
import 'tool_args.dart' show cleanCategoryText;

const uncategorized = '未分类';

/// 和后台 data-env.cleanCategory 一样：最多两级，每级最多 30 字
String cleanCategory(String v) => cleanCategoryText(v);

/// 已有的分类（含一级），给选分类用
List<String> categoriesOf(Iterable<String> cats) {
  final s = <String>{};
  for (final raw in cats) {
    final c = cleanCategory(raw);
    if (c.isEmpty) continue;
    s.add(c);
    s.add(c.split('/').first);
  }
  return s.toList()..sort();
}

// ---------- 数据属于哪一套（toolbox / 银杏 / 云启动 / 管理员） ----------
const envNames = {'toolbox': 'toolbox', 'yx': '银杏', 'cloud': '云启动', 'admin': '管理员'};
const envOrder = ['toolbox', 'yx', 'cloud', 'admin'];

/// 标出这条属于哪一套：用密码打开（列表接口回 allEnvs，几套都显示）时都标；登录用户只标管理员建的（只能看、不能改）
Widget? envTag(String env, bool allEnvs) => env.isNotEmpty && (allEnvs || env == 'admin') ? Tag(envNames[env] ?? env, color: const Color(0xFF8B5CF6)) : null;

/// 不能改时的说明
String readOnlyText(String env, {bool usable = false}) =>
    '${env == 'admin' ? '这是管理员建的，只有用管理密码打开的页面能修改、删除' : '这属于${envNames[env] ?? env}那边，你不能修改、删除'}；你可以查看${usable ? '、使用' : ''}。';

/// 筛选里的“归属”：几套里实际有内容的（只有一套时不显示）
List<(String, String)> envOptions(Iterable<String> envs) {
  final have = envs.where((e) => e.isNotEmpty).toSet();
  return have.length < 2 ? const [] : [('all', '全部'), for (final e in envOrder) if (have.contains(e)) (e, envNames[e]!)];
}

// ---------- 存在本机的列表设置 ----------
class ListPrefs {
  ListPrefs._();
  static final instance = ListPrefs._();
  SharedPreferences? _p;

  /// 用之前先读一次（每次打开面板时）
  Future<void> load() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {}
  }

  static String _k(String k) => 'netbar_ops.lv.$k';
  List<String> _list(String k) => _p?.getStringList(_k(k)) ?? const [];
  void _setList(String k, Iterable<String> v) => _p?.setStringList(_k(k), v.toList());

  Set<String> pins(String key) => _list('pin:$key').toSet();
  bool isPinned(String key, String id) => pins(key).contains(id);

  /// 置顶 / 取消置顶，返回现在是不是置顶
  bool togglePin(String key, String id) {
    final s = _list('pin:$key').toList();
    final on = !s.remove(id);
    if (on) s.add(id);
    _setList('pin:$key', s.length > 200 ? s.sublist(s.length - 200) : s);
    return on;
  }

  Set<String> folds(String key) => _list('fold:$key').toSet();
  void setFolded(String key, String path, bool folded) {
    final f = folds(key);
    folded ? f.add(path) : f.remove(path);
    _setList('fold:$key', f);
  }

  /// 展开这个分类所在的分组（新建、上传后要能看到它）
  void unfold(String key, String category) {
    final c = cleanCategory(category).isEmpty ? uncategorized : cleanCategory(category);
    final f = folds(key)
      ..remove(c.split('/').first)
      ..remove(c);
    _setList('fold:$key', f);
  }

  bool get compact => _p?.getBool(_k('compact')) ?? false;
  set compact(bool v) => _p?.setBool(_k('compact'), v);

  String getString(String k, String def) => _p?.getString(_k(k)) ?? def;
  void setString(String k, String v) => _p?.setString(_k(k), v);
  Set<String> getSet(String k) => _list(k).toSet();
  void setSet(String k, Set<String> v) => _setList(k, v.length > 500 ? v.toList().sublist(v.length - 500) : v);
}

// ---------- 搜索命中 ----------
/// 内容里命中的那一句：（前文，命中的字，后文）；没命中返回 null
(String, String, String)? snippetOf(String text, String q, {int width = 22}) {
  if (q.isEmpty) return null;
  final t = text.replaceAll(RegExp(r'\s+'), ' ');
  final i = t.toLowerCase().indexOf(q.toLowerCase());
  if (i < 0) return null;
  final s = (i - width).clamp(0, t.length), e = (i + q.length + width).clamp(0, t.length);
  return ('${s > 0 ? '…' : ''}${t.substring(s, i)}', t.substring(i, i + q.length), '${t.substring(i + q.length, e)}${e < t.length ? '…' : ''}');
}

/// 把命中的字标出来
List<InlineSpan> highlightSpans(String text, String q, Color mark) {
  final i = q.isEmpty ? -1 : text.toLowerCase().indexOf(q.toLowerCase());
  if (i < 0) return [TextSpan(text: text)];
  return [
    TextSpan(text: text.substring(0, i)),
    TextSpan(text: text.substring(i, i + q.length), style: TextStyle(backgroundColor: mark)),
    TextSpan(text: text.substring(i + q.length)),
  ];
}

Color markColor(BuildContext context) => NT.warn.withValues(alpha: NetbarColors(context).dark ? .45 : .35);

/// 一行带高亮的小字（内容里命中的那一句）
class SnippetLine extends StatelessWidget {
  const SnippetLine(this.parts, {super.key, this.maxLines = 1});
  final (String, String, String) parts;
  final int maxLines;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Text.rich(
        TextSpan(style: TextStyle(fontSize: 12, color: c.muted), children: [
          TextSpan(text: parts.$1),
          TextSpan(text: parts.$2, style: TextStyle(backgroundColor: markColor(context), color: c.text)),
          TextSpan(text: parts.$3),
        ]),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis);
  }
}

// ---------- 按分类折叠的列表 ----------
/// items 已经筛好、排好序；groupOf 为空就不分组；row 画一条（compact：紧凑模式）
/// 有搜索词时分组全部展开；置顶的放在最上面“★ 置顶”里；只有一个“未分类”时不显示分组头
class CategoryList<T> extends StatefulWidget {
  const CategoryList(
      {super.key,
      required this.items,
      required this.idOf,
      required this.row,
      required this.listKey,
      String? pinKey,
      this.groupOf,
      this.query = '',
      required this.empty})
      : pinKey = pinKey ?? listKey;
  final List<T> items;
  final String Function(T) idOf;
  final String Function(T)? groupOf;
  final Widget Function(T x, bool compact) row;
  final String listKey, pinKey, query, empty;
  @override
  State<CategoryList<T>> createState() => _CategoryListState<T>();
}

class _CategoryListState<T> extends State<CategoryList<T>> {
  ListPrefs get _prefs => ListPrefs.instance;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final w = widget;
    if (w.items.isEmpty) return EmptyHint(w.empty);
    final compact = _prefs.compact;
    final pins = _prefs.pins(w.pinKey);
    final folded = _prefs.folds(w.listKey);
    final out = <Widget>[];
    Widget rows(List<T> list) => RowGroup(children: [for (final x in list) w.row(x, compact)]);
    void group(String path, String name, int count, int depth, List<Widget> Function() body) {
      final open = w.query.isNotEmpty || !folded.contains(path);
      out.add(GroupHead(
          name: name,
          count: count,
          open: open,
          depth: depth,
          onTap: () => setState(() => _prefs.setFolded(w.listKey, path, open))));
      if (open) out.addAll(body());
    }

    final pinned = w.items.where((x) => pins.contains(w.idOf(x))).toList();
    final rest = w.items.where((x) => !pins.contains(w.idOf(x))).toList();
    if (pinned.isNotEmpty) group('\u0000pin', '★ 置顶', pinned.length, 0, () => [rows(pinned)]);
    if (w.groupOf == null) {
      if (rest.isNotEmpty) out.add(rows(rest));
    } else {
      // 两级分组：一级下面先放二级分组，再放没有二级的
      final tree = <String, ({List<T> items, Map<String, List<T>> subs})>{};
      for (final x in rest) {
        final c = cleanCategory(w.groupOf!(x));
        final parts = (c.isEmpty ? uncategorized : c).split('/');
        final t = tree.putIfAbsent(parts[0], () => (items: <T>[], subs: <String, List<T>>{}));
        parts.length > 1 ? (t.subs[parts[1]] ??= []).add(x) : t.items.add(x);
      }
      int byName(String a, String b) => a == b ? 0 : (a == uncategorized ? 1 : (b == uncategorized ? -1 : a.compareTo(b)));
      if (tree.length == 1 && tree.containsKey(uncategorized) && tree[uncategorized]!.subs.isEmpty) {
        if (rest.isNotEmpty) out.add(rows(rest));
      } else {
        for (final name in tree.keys.toList()..sort(byName)) {
          final t = tree[name]!;
          final n = t.items.length + t.subs.values.fold<int>(0, (a, l) => a + l.length);
          group(name, name, n, 0, () {
            final inner = <Widget>[];
            for (final sub in t.subs.keys.toList()..sort(byName)) {
              final path = '$name/$sub', list = t.subs[sub]!;
              final open = w.query.isNotEmpty || !folded.contains(path);
              inner.add(GroupHead(name: sub, count: list.length, open: open, depth: 1, onTap: () => setState(() => _prefs.setFolded(w.listKey, path, open))));
              if (open) inner.add(rows(list));
            }
            if (t.items.isNotEmpty) inner.add(rows(t.items));
            return inner;
          });
        }
      }
    }
    return ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 12 : 0, vertical: 4), children: out);
  }
}

/// 分组头：▸/▾ 名称 条数，点一下展开或收起
class GroupHead extends StatelessWidget {
  const GroupHead({super.key, required this.name, required this.count, required this.open, required this.onTap, this.depth = 0});
  final String name;
  final int count, depth;
  final bool open;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    return Pressable(
      onTap: onTap,
      label: '$name，$count 条，${open ? '点一下收起' : '点一下展开'}',
      child: Padding(
        padding: EdgeInsets.fromLTRB((s.isDesktop ? 2 : 16) + depth * 14.0, s.isMobile ? 10 : 6, 8, s.isMobile ? 6 : 4),
        child: Row(children: [
          Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: c.muted),
          const SizedBox(width: 2),
          Flexible(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: depth == 0 ? NT.fSmall : NT.fCaption, fontWeight: FontWeight.w600, color: depth == 0 ? c.text2 : c.muted))),
          const SizedBox(width: 6),
          Text('$count', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
        ]),
      ),
    );
  }
}

// ---------- 搜索框 + 筛选 ----------
/// 筛选面板里的一组选项（只有一个选项的组不显示）
class FilterGroup {
  const FilterGroup(this.name, this.label, this.value, this.options);
  final String name, label, value;
  final List<(String, String)> options;
  String labelOf(String v) => options.where((o) => o.$1 == v).firstOrNull?.$2 ?? v;
}

/// 已用的筛选条件（显示成小标签，点 ✕ 去掉）
class ActiveFilter {
  const ActiveFilter(this.label, this.clear);
  final String label;
  final VoidCallback clear;
}

/// 列表上方：搜索框 + “筛选”按钮（数字是用了几个条件）+ 其他按钮；下面一行是已用条件的小标签
class SearchBarRow extends StatelessWidget {
  const SearchBarRow(
      {super.key,
      required this.placeholder,
      required this.onSearch,
      this.groups = const [],
      this.onFilter,
      this.active = const [],
      this.actions = const [],
      this.leading,
      this.onCompact,
      this.controller});
  final String placeholder;
  final ValueChanged<String> onSearch;
  final List<FilterGroup> groups;
  final void Function(String name, String value)? onFilter;
  final List<ActiveFilter> active;
  final List<Widget> actions;
  final Widget? leading;

  /// 紧凑模式切换后（列表要重画）
  final VoidCallback? onCompact;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          ?leading,
          Expanded(child: _Search(placeholder: placeholder, onChanged: onSearch, controller: controller)),
          if (onFilter != null || onCompact != null)
            Builder(
                builder: (bctx) => Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Stack(clipBehavior: Clip.none, children: [
                        AIconButton(
                            icon: Icons.tune,
                            tooltip: '筛选',
                            color: active.isEmpty ? null : c.accentText,
                            onPressed: () => showFilterSheet(bctx, groups: groups, onChanged: onFilter ?? (_, _) {}, onCompact: onCompact)),
                        if (active.isNotEmpty)
                          Positioned(
                              right: 0,
                              top: 0,
                              child: IgnorePointer(
                                  child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      decoration: BoxDecoration(color: NT.accent, borderRadius: BorderRadius.circular(8)),
                                      child: Text('${active.length}', style: const TextStyle(fontSize: 10, color: Colors.white))))),
                      ]),
                    )),
          ...actions,
        ]),
        if (active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final a in active) _TagChip(label: a.label, onTap: a.clear),
              if (active.length > 1)
                _TagChip(
                    label: '全部清除',
                    plain: true,
                    onTap: () {
                      for (final a in active) {
                        a.clear();
                      }
                    }),
            ]),
          ),
      ]),
    );
  }
}

/// 搜索框：外面给了 controller 时（换标签页要清空）用它
class _Search extends StatelessWidget {
  const _Search({required this.placeholder, required this.onChanged, this.controller});
  final String placeholder;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  @override
  Widget build(BuildContext context) {
    if (controller == null) return ASearchField(placeholder: placeholder, onChanged: onChanged);
    final s = NetbarScope.of(context);
    if (s.isCupertino) return CupertinoSearchTextField(controller: controller, placeholder: placeholder, onChanged: onChanged);
    return TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: NT.fBody),
        decoration: fieldDecoration(context, hint: placeholder, dense: true, prefix: const Icon(Icons.search, size: 18)));
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.onTap, this.plain = false});
  final String label;
  final VoidCallback onTap;
  final bool plain;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return DecoratedBox(
      decoration: BoxDecoration(
          color: plain ? Colors.transparent : NT.accent.withValues(alpha: .08), borderRadius: BorderRadius.circular(999), border: Border.all(color: plain ? c.line : NT.accent.withValues(alpha: .4))),
      child: Pressable(
        radius: 999,
        onTap: onTap,
        label: plain ? label : '去掉条件：$label',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: NT.fCaption, color: plain ? c.muted : c.accentText)),
            if (!plain) ...[const SizedBox(width: 4), Icon(Icons.close, size: 12, color: c.accentText)],
          ]),
        ),
      ),
    );
  }
}

/// 筛选面板：电脑上是小窗口，手机上从底部弹出；每组一排可选的小胶囊，最后是“紧凑模式”开关
Future<void> showFilterSheet(BuildContext context, {required List<FilterGroup> groups, required void Function(String, String) onChanged, VoidCallback? onCompact}) {
  final s = NetbarScope.read(context);
  final body = _FilterBody(groups: groups.where((g) => g.options.length > 1).toList(), onChanged: onChanged, onCompact: onCompact);
  if (s.isDesktop) {
    return showDialog(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => s.copyWith(
            child: AlertDialog(
                title: const Text('筛选', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                scrollable: true,
                content: SizedBox(width: 440, child: body),
                actions: [AButton(label: '完成', kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx))])));
  }
  return showModalBottomSheet(
      context: context,
      useRootNavigator: false,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => s.copyWith(
          child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: body))));
}

class _FilterBody extends StatefulWidget {
  const _FilterBody({required this.groups, required this.onChanged, this.onCompact});
  final List<FilterGroup> groups;
  final void Function(String, String) onChanged;
  final VoidCallback? onCompact;
  @override
  State<_FilterBody> createState() => _FilterBodyState();
}

class _FilterBodyState extends State<_FilterBody> {
  late final Map<String, String> _values = {for (final g in widget.groups) g.name: g.value};
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final prefs = ListPrefs.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final g in widget.groups) ...[
        Padding(padding: const EdgeInsets.only(top: 8, bottom: 6), child: Text(g.label, style: TextStyle(fontSize: NT.fCaption, fontWeight: FontWeight.w600, color: c.muted))),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (v, label) in g.options)
            ChoicePill(
                label: label,
                selected: _values[g.name] == v,
                onTap: () {
                  setState(() => _values[g.name] = v);
                  widget.onChanged(g.name, v);
                }),
        ]),
      ],
      if (widget.onCompact != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text('紧凑模式：每条只显示一行标题，一屏能看到更多', style: TextStyle(fontSize: NT.fSmall, color: c.text2))),
          Switch.adaptive(
              value: prefs.compact,
              activeTrackColor: NetbarScope.of(context).isCupertino ? null : NT.accent,
              onChanged: (v) {
                setState(() => prefs.compact = v);
                widget.onCompact!();
              }),
        ]),
      ],
    ]);
  }
}

/// 可选的小胶囊（筛选、选分类）
class ChoicePill extends StatelessWidget {
  const ChoicePill({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    return DecoratedBox(
      decoration: BoxDecoration(
          color: selected ? NT.accent.withValues(alpha: .12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? NT.accent.withValues(alpha: .6) : c.line)),
      child: Pressable(
        radius: 999,
        onTap: onTap,
        label: label,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 11, vertical: s.isMobile ? 7 : 4),
          child: Text(label, style: TextStyle(fontSize: NT.fCaption + 0.5, color: selected ? c.accentText : c.text2)),
        ),
      ),
    );
  }
}

// ---------- 选分类 ----------
/// 选分类的小窗口：可以点已有的，也可以直接输入新的；确定返回分类（空 = 未分类），取消返回 null
Future<String?> pickCategory(BuildContext context, {required String title, String? hint, required List<String> all, String initial = '', String ok = '选好了，选文件'}) async {
  var v = initial;
  final yes = await confirmDialog(context, title: title, ok: ok, content: _CategoryPicker(initial: initial, hint: hint, all: all, onChanged: (t) => v = t));
  return yes ? cleanCategory(v) : null;
}

/// 输入框自己管 controller（对话框关闭动画里还会用到，不能一关就释放）
class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.initial, required this.all, required this.onChanged, this.hint});
  final String initial;
  final List<String> all;
  final String? hint;
  final ValueChanged<String> onChanged;
  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  late final TextEditingController _c = TextEditingController(text: widget.initial)..addListener(() => widget.onChanged(_c.text));
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return SizedBox(
      width: 420,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AField(controller: _c, hint: '例如：云启动，或 云启动/日志（最多两级）', maxLength: 61),
        if (widget.hint != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(widget.hint!, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
        if (widget.all.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final cat in widget.all) ChoicePill(label: cat, selected: cleanCategory(_c.text) == cat, onTap: () => setState(() => _c.text = cat)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// 编辑表单里的分类输入框：可以直接输入，右边按钮从已有的分类里选
class CategoryField extends StatelessWidget {
  const CategoryField({super.key, required this.controller, required this.all});
  final TextEditingController controller;
  final List<String> all;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: AField(controller: controller, label: '分类（可不填；用 / 分两级，如 硬件/硬盘）', hint: '例如：云启动，或 云启动/日志', maxLength: 61)),
        if (all.isNotEmpty)
          Builder(
              builder: (bctx) => AIconButton(
                  icon: Icons.arrow_drop_down_circle_outlined,
                  tooltip: '选已有的分类',
                  onPressed: () async {
                    final r = await actionSheet<String>(bctx, title: '选已有的分类', anchor: rectOf(bctx), actions: [for (final c in all) SheetAction(c, c, checked: c == cleanCategory(controller.text))]);
                    if (r != null) controller.text = r;
                  })),
      ]);
}

/// 表单里的选择框：显示当前选的，点开从几个选项里选（三种界面风格都用 actionSheet）
class ChoiceField<T> extends StatelessWidget {
  const ChoiceField({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.enabled = true});
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final cur = options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '$value';
    return Builder(
      builder: (bctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.only(left: 4, bottom: 4), child: Text(label, style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
        DecoratedBox(
          decoration: BoxDecoration(color: enabled ? c.card : c.fill, borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: c.line)),
          child: Pressable(
            label: '$label：$cur',
            onTap: !enabled
                ? null
                : () async {
                    final r = await actionSheet<T>(bctx, title: label, anchor: rectOf(bctx), actions: [for (final (v, l) in options) SheetAction(l, v, checked: v == value)]);
                    if (r != null) onChanged(r);
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Expanded(child: Text(cur, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fBody, color: enabled ? c.text : c.muted))),
                Icon(Icons.unfold_more, size: 16, color: c.muted),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------- 刷新按钮（面板右上角，关闭按钮左边） ----------
/// 面板和右上角刷新按钮之间的联系：面板打开后把“重新载入”“有没有没保存的修改”登记进来
class PanelRefresh {
  Future<void> Function()? reload;
  bool Function()? editing;
}

/// 给 pushPanel 的 actions 用
List<Widget> Function(BuildContext) refreshActions(PanelRefresh h) => (_) => [RefreshButton(handle: h)];

class RefreshButton extends StatefulWidget {
  const RefreshButton({super.key, required this.handle});
  final PanelRefresh handle;
  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton> {
  bool _busy = false;
  Future<void> _run() async {
    final h = widget.handle;
    if (_busy || h.reload == null) return;
    if (h.editing?.call() == true &&
        !await confirmDialog(context, title: '刷新？', message: '正在编辑的内容还没保存，刷新会丢掉这些修改，确定刷新吗？', ok: '刷新', destructive: true)) return;
    setState(() => _busy = true);
    try {
      await h.reload!();
    } catch (e) {
      if (mounted) showToast(context, e is Exception ? e.toString().replaceFirst('Exception: ', '') : '刷新失败');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => _busy
      ? const SizedBox(width: 44, height: 30, child: Center(child: ASpinner(size: 16)))
      : AIconButton(icon: Icons.refresh, tooltip: '刷新：重新载入这个窗口的数据', size: 18, onPressed: _run);
}

/// 时间：tools 列表里可能是数字（毫秒）或字符串
DateTime? parseTime(dynamic t) => t is num ? DateTime.fromMillisecondsSinceEpoch(t.toInt()).toLocal() : DateTime.tryParse(str(t))?.toLocal();

/// 只有一个“知道了”按钮的提示框（出错原因、上传结果这类要看清楚的长文字）
Future<void> showAlert(BuildContext context, String message, {String? title}) async {
  final s = NetbarScope.read(context);
  if (s.isCupertino) {
    await showCupertinoDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => CupertinoAlertDialog(
              title: title == null ? null : Text(title),
              content: Padding(padding: const EdgeInsets.only(top: 6), child: Text(message)),
              actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
            ));
    return;
  }
  await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => s.copyWith(
              child: AlertDialog(
            title: title == null ? null : Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            scrollable: true,
            content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: SelectableText(message, style: const TextStyle(fontSize: 14, height: 1.5))),
            actions: [AButton(label: '知道了', kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx))],
          )));
}
