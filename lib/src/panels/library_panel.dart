// 资料库（知识库的“资料库”标签页，对应网页版 library.js）：一个文件树，交互参照禅道文件管理
//   左边只放文件夹树（层级不限），每个文件夹有“⋯”菜单（新建子文件夹、上传到这里、新建文档、重命名、编辑说明、移动、删除）；
//   右边是当前文件夹的内容（子文件夹在前、文件在后），上面是路径和按钮（上传文件、上传文件夹、上传 zip、新建文档、新建文件夹、选择）；
//   点子文件夹进入，点文件打开详情（预览、下载），“← 返回”回到列表；可以勾选多项批量移动、删除；搜索结果也显示在右边
//   窄的时候（手机、小窗口）文件夹树收进左上角的“文件夹”按钮
// 分 toolbox / 银杏 / 云启动 / 管理员几套，最外层是各套的“资料”；能不能改由后台按身份算（每个节点的 canEdit）
// 树的展开状态、置顶只存在这台设备上
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart' as services;
import '../ui/adaptive.dart';
import '../ui/markdown.dart';
import 'common.dart';
import 'listview.dart';
import 'panel_files.dart';

final libTextExts = RegExp(r'\.(txt|md|markdown|log|csv|tsv|json|ini|cfg|conf|inf|nfo|xml|ya?ml|bat|cmd|ps1|psm1|vbs|reg|sh|py|js|sql|html?|css|properties|toml|lst|diz)$', caseSensitive: false);
final libImageExts = RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false);
String libSize(int b) => b >= 1048576 ? '${(b / 1048576).toStringAsFixed(1)} MB' : (b >= 1024 ? '${(b / 1024).round()} KB' : '$b B');

/// 资料库的一个节点（文件夹或文件）
class LibNode {
  LibNode(this.raw);
  final Map<String, dynamic> raw;
  String get id => str(raw['id']);
  String get env => str(raw['env']);
  String get parentId => str(raw['parentId']);
  bool get isFolder => raw['kind'] == 'folder';
  String get name => str(raw['name']);
  String get description => str(raw['description']);
  int get size => (raw['size'] as num?)?.toInt() ?? 0;
  int get textLen => (raw['textLen'] as num?)?.toInt() ?? 0;
  String get textNote => str(raw['textNote']);
  bool get canEdit => raw['canEdit'] != false;
  DateTime? get updatedAt => parseTime(raw['updatedAt']);

  /// 它在哪个文件夹里：文件夹编号，或某一套的最外层“root:toolbox”
  String get parentKey => parentId.isEmpty ? 'root:$env' : parentId;
}

/// 资料库的树（纯数据，方便测试）
class LibTree {
  LibTree(List<Map<String, dynamic>> roots, List<Map<String, dynamic>> nodes)
      : roots = [for (final r in roots) (env: str(r['env']), name: str(r['name']), canEdit: r['canEdit'] == true)],
        nodes = nodes.map(LibNode.new).toList() {
    for (final n in this.nodes) {
      byId[n.id] = n;
      (kids[n.parentKey] ??= []).add(n);
    }
    for (final l in kids.values) {
      l.sort((a, b) => a.isFolder != b.isFolder ? (a.isFolder ? -1 : 1) : a.name.compareTo(b.name));
    }
  }
  final List<({String env, String name, bool canEdit})> roots;
  final List<LibNode> nodes;
  final byId = <String, LibNode>{};
  final kids = <String, List<LibNode>>{};

  static bool isRoot(String id) => id.startsWith('root:');
  ({String env, String name, bool canEdit})? rootOf(String env) => roots.where((r) => r.env == env).firstOrNull;
  List<LibNode> kidsOf(String key) => kids[key] ?? const [];
  bool exists(String id) => isRoot(id) ? rootOf(id.substring(5)) != null : byId.containsKey(id);

  /// 路径：[(编号, 名字)]，第一个是最外层
  List<(String, String)> path(String id) {
    if (isRoot(id)) {
      final r = rootOf(id.substring(5));
      return r == null ? [] : [(id, r.name)];
    }
    final out = <(String, String)>[];
    var n = byId[id];
    for (var i = 0; n != null && i < 40; i++) {
      out.insert(0, (n.id, n.name));
      if (n.parentId.isEmpty) {
        out.insert(0, ('root:${n.env}', rootOf(n.env)?.name ?? n.env));
        break;
      }
      n = byId[n.parentId];
    }
    return out;
  }

  String pathText(String id) => path(id).map((p) => p.$2).join(' / ');

  /// 某个文件夹（或最外层）的放置信息：上传、新建放这里
  ({String id, String parentId, String rootEnv, bool canEdit, String name})? spot(String id) {
    if (isRoot(id)) {
      final r = rootOf(id.substring(5));
      return r == null ? null : (id: id, parentId: '', rootEnv: r.env, canEdit: r.canEdit, name: r.name);
    }
    final f = byId[id];
    return f == null || !f.isFolder ? null : (id: id, parentId: f.id, rootEnv: f.env, canEdit: f.canEdit, name: f.name);
  }

  int fileCount(String id) => kidsOf(id).fold(0, (s, k) => s + (k.isFolder ? fileCount(k.id) : 1));

  /// 移动时能选的位置：自己能改的每一套的最外层和它下面的文件夹，不含要移动的文件夹自己和它里面的
  List<({String id, String env, String label, bool root})> moveTargets(List<LibNode> moving) {
    final banned = <String>{};
    void ban(String id) {
      banned.add(id);
      for (final k in kidsOf(id)) {
        ban(k.id);
      }
    }

    for (final n in moving) {
      n.isFolder ? ban(n.id) : banned.add(n.id);
    }
    final out = <({String id, String env, String label, bool root})>[];
    void walk(String key, int depth) {
      for (final k in kidsOf(key).where((k) => k.isFolder && !banned.contains(k.id))) {
        out.add((id: k.id, env: k.env, label: '${'　' * depth}${k.name}', root: false));
        walk(k.id, depth + 1);
      }
    }

    for (final r in roots.where((r) => r.canEdit)) {
      out.add((id: 'root:${r.env}', env: r.env, label: '▣ ${r.name}', root: true));
      walk('root:${r.env}', 1);
    }
    return out;
  }
}

class LibraryView extends StatefulWidget {
  const LibraryView({super.key, this.selectId, this.hook, this.onCount});

  /// 打开后直接选中这个文件或文件夹（输入框 @ 推荐的资料、旧链接）
  final String? selectId;

  /// 知识库面板的刷新按钮、切换标签页时用：重新载入、有没有没保存的文档
  final PanelRefresh? hook;

  /// 文件总数（标签页上显示）
  final ValueChanged<int>? onCount;
  @override
  State<LibraryView> createState() => _LibraryViewState();
}

typedef LibEditing = ({String? id, String parentId, String rootEnv, String where, String name, String content});

class _LibraryViewState extends State<LibraryView> {
  LibTree? _tree;
  String? _error;
  String _folder = '', _file = '';
  final _checked = <String>{};
  bool _selecting = false;
  LibEditing? _editing;
  String _query = '', _jump = '', _jumpFile = '';
  List<Map<String, dynamic>>? _results;
  int _searchSeq = 0;
  Timer? _searchTimer;
  String? _progress;
  bool _dragging = false;
  final _search = TextEditingController();
  ChatController get _ctl => NetbarScope.read(context).controller;
  ListPrefs get _prefs => ListPrefs.instance;

  @override
  void initState() {
    super.initState();
    widget.hook
      ?..reload = _reload
      ..editing = () => _editing != null;
    _start();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    await _reload();
    final id = widget.selectId;
    if (id != null && mounted && _tree != null && _tree!.exists(id)) setState(() => _select(id));
  }

  Future<void> _reload() async {
    await _prefs.load();
    try {
      final r = await _ctl.api.post('/api/lib/tree');
      final t = LibTree(asList(r['roots']).map(asMap).toList(), asList(r['nodes']).map(asMap).toList());
      _tree = t;
      _error = null;
      if (_folder.isEmpty || (_folder != 'pins' && !t.exists(_folder))) _folder = t.roots.isEmpty ? '' : 'root:${t.roots.first.env}';
      if (_file.isNotEmpty && !t.byId.containsKey(_file)) _file = '';
      _checked.removeWhere((id) => !t.byId.containsKey(id));
      _editing = null;
      widget.onCount?.call(t.nodes.where((n) => !n.isFolder).length);
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() {});
  }

  // ---------- 展开状态 ----------
  Set<String> get _open {
    final s = _prefs.getSet('libOpen');
    return s.isEmpty && _tree != null ? {for (final r in _tree!.roots) 'root:${r.env}'} : s;
  }

  void _setOpen(Set<String> s) => _prefs.setSet('libOpen', s);

  /// 打开：文件夹 → 看它的列表；文件 → 打开文件详情（左边选中它所在的文件夹）
  void _select(String id) {
    final t = _tree!;
    final n = t.byId[id];
    _editing = null;
    _checked.clear();
    _selecting = false;
    if (n != null && !n.isFolder) {
      _folder = n.parentKey;
      _file = n.id;
    } else {
      _folder = id;
      _file = '';
    }
    final open = _open;
    for (final p in t.path(_folder).take(t.path(_folder).length - 1)) {
      open.add(p.$1);
    }
    _setOpen(open);
  }

  Future<bool> leaveEdit() async {
    if (_editing != null && !await confirmDialog(context, title: '放弃修改？', message: '正在编辑的文档还没保存，确定放弃吗？', ok: '放弃', destructive: true)) return false;
    _editing = null;
    return true;
  }

  Future<void> _go(String id) async {
    if (!await leaveEdit()) return;
    _clearSearch();
    setState(() => _select(id));
  }

  void _clearSearch() {
    _search.clear();
    _query = '';
    _results = null;
  }

  void _onSearch(String v) {
    final q = v.trim();
    _searchTimer?.cancel();
    setState(() {
      _query = q;
      _results = null;
    });
    if (q.isEmpty) return;
    final seq = ++_searchSeq;
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      List<Map<String, dynamic>> hits;
      try {
        hits = asList((await _ctl.api.post('/api/lib/search', {'q': q}))['hits']).map(asMap).toList();
      } on ApiError catch (e) {
        hits = [];
        if (mounted) showToast(context, e.message);
      }
      if (seq == _searchSeq && mounted) setState(() => _results = hits);
    });
  }

  // ---------- 操作 ----------
  Future<Map<String, dynamic>?> _do(String path, Map<String, dynamic> body, [String? ok]) async {
    try {
      final r = await _ctl.api.post(path, body);
      if (ok != null && mounted) showToast(context, ok);
      await _reload();
      return r;
    } on ApiError catch (e) {
      if (mounted) await showAlert(context, e.message);
      return null;
    }
  }

  Future<void> _download(LibNode n, [BuildContext? from]) async {
    final origin = from == null ? null : rectOf(from);
    try {
      final bytes = await _ctl.api.postBytes('/api/lib/download', {'id': n.id});
      await services.saveFile(bytes, n.name, origin: origin);
    } on ApiError catch (e) {
      if (mounted) await showAlert(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, '保存失败，请再试一次');
    }
  }

  /// 对某一个文件或文件夹的操作（列表每行、文件详情、树的菜单都走这里）
  Future<void> _act(String act, LibNode n, [BuildContext? from]) async {
    switch (act) {
      case 'download':
        return _download(n, from);
      case 'pin':
        final on = _prefs.togglePin('lib', n.id);
        showToast(context, on ? '已置顶，只在这台设备上生效' : '已取消置顶');
        return setState(() {});
      case 'edit':
        Map<String, dynamic> r;
        try {
          r = await _ctl.api.post('/api/lib/file', {'id': n.id});
        } on ApiError catch (e) {
          if (mounted) await showAlert(context, e.message);
          return;
        }
        final text = str(r['text']);
        if (((r['total'] as num?) ?? 0) > text.length) {
          if (mounted) await showAlert(context, '文件太长了，不能在这里编辑，请下载后修改再上传（同名会覆盖）');
          return;
        }
        return _openEditor((id: n.id, parentId: n.parentId, rootEnv: n.env, where: '', name: n.name, content: text));
      case 'rename':
        final name = await promptText(context, title: '重命名${n.isFolder ? '文件夹' : '文件'}', initial: n.name, maxLength: 120);
        if (name != null && name.trim().isNotEmpty && name.trim() != n.name) await _do('/api/lib/rename', {'id': n.id, 'name': name}, '已重命名');
        return;
      case 'describe':
        final d = await promptText(context,
            title: '“${n.name}”的说明',
            initial: n.description,
            maxLength: 300,
            multiline: true,
            hint: n.isFolder ? '例如：云启动服务端各模块的日志格式和错误码说明（AI 看目录时能看到）' : '一句话说明这个文件是什么、什么时候用');
        if (d != null) await _do('/api/lib/describe', {'id': n.id, 'description': d}, '说明已保存');
        return;
      case 'move':
        return _move([n]);
      case 'delete':
        return _delete([n]);
    }
  }

  Future<void> _delete(List<LibNode> list) async {
    if (list.isEmpty) return;
    final t = _tree!;
    final files = list.fold(0, (s, n) => s + (n.isFolder ? t.fileCount(n.id) : 1));
    final msg = list.length == 1
        ? (list.first.isFolder ? '确定删除文件夹“${list.first.name}”吗？里面的 $files 个文件会一起删掉，删除后不能恢复。' : '确定删除“${list.first.name}”吗？删除后不能恢复。')
        : '确定删除选中的 ${list.length} 项吗？一共 $files 个文件，删除后不能恢复。';
    if (!await confirmDialog(context, title: '删除？', message: msg, ok: '删除', destructive: true)) return;
    // 删的是当前文件夹或打开的文件：回到它的上一层；否则留在当前文件夹
    final gone = list.map((n) => n.id).toSet();
    final stay = gone.contains(_folder) || gone.contains(_file) ? list.first.parentKey : _folder;
    for (final n in list) {
      try {
        await _ctl.api.post('/api/lib/delete', {'id': n.id});
      } on ApiError catch (e) {
        if (mounted) await showAlert(context, '${n.name}：${e.message}');
        break;
      }
    }
    if (mounted) showToast(context, '已删除');
    await _reload();
    if (mounted && _tree != null) setState(() => _select(_tree!.exists(stay) ? stay : (_tree!.roots.isEmpty ? '' : 'root:${_tree!.roots.first.env}')));
  }

  /// 移动：可以移到任何一个文件夹，也可以直接移到最外层（另一套资料里）；移到另一套之前先提醒
  Future<void> _move(List<LibNode> list) async {
    if (list.isEmpty) return;
    final t = _tree!;
    final opts = t.moveTargets(list);
    final cur = list.first.parentKey;
    final to = await actionSheet<String>(context,
        title: '把${list.length == 1 ? '“${list.first.name}”' : '选中的 ${list.length} 项'}移到',
        message: '可以移到任何一个文件夹，也可以直接移到最外层（▣ 开头的${t.roots.where((r) => r.canEdit).length > 1 ? '，比如移到另一套资料里' : ''}）',
        actions: [for (final o in opts) SheetAction(o.label, o.id, checked: o.id == cur)]);
    if (to == null || !mounted) return;
    final opt = opts.firstWhere((o) => o.id == to);
    if (list.any((n) => n.env != opt.env) &&
        !await confirmDialog(context,
            title: '移到另一套资料？',
            message: '要移到“${t.rootOf(opt.env)?.name ?? opt.env}”这一套里，移过去以后只有那一套的人（和管理员）能看到、AI 也只在那一套里查得到。确定吗？',
            ok: '移过去')) return;
    var ok = 0;
    for (final n in list) {
      if (n.parentKey == to) continue;
      try {
        await _ctl.api.post('/api/lib/move', {'id': n.id, 'parentId': LibTree.isRoot(to) ? '' : to, 'rootEnv': opt.env});
        ok++;
      } on ApiError catch (e) {
        if (mounted) await showAlert(context, '${n.name}：${e.message}');
        break;
      }
    }
    if (ok > 0 && mounted) showToast(context, '已移动 $ok 项到“${t.pathText(to)}”');
    _checked.clear();
    _selecting = false;
    await _reload();
  }

  Future<void> _mkdir(String at) async {
    final spot = _tree?.spot(at);
    if (spot == null || !spot.canEdit) return;
    final name = await promptText(context, title: '在“${_tree!.pathText(spot.id)}”里新建文件夹', hint: '文件夹名字', maxLength: 120);
    if (name == null || name.trim().isEmpty) return;
    final r = await _do('/api/lib/mkdir', {'parentId': spot.parentId, 'rootEnv': spot.rootEnv, 'name': name}, '已新建文件夹');
    if (r != null && mounted) setState(() => _select(str(asMap(r['node'])['id'])));
  }

  Future<void> _newDoc(String at) async {
    final spot = _tree?.spot(at);
    if (spot == null || !spot.canEdit) return;
    await _openEditor((id: null, parentId: spot.parentId, rootEnv: spot.rootEnv, where: _tree!.pathText(spot.id), name: '', content: ''));
  }

  Future<void> _openEditor(LibEditing e) async {
    if (isWide(context)) return setState(() => _editing = e);
    final id = await pushPanel<String>(context, title: e.id == null ? '新建文档' : '编辑文档', builder: (ctx) => LibDocEditor(editing: e, onDone: (id) => Navigator.pop(ctx, id)));
    if (id != null) _afterSave(id);
  }

  Future<void> _afterSave(String id) async {
    await _reload();
    if (mounted && _tree!.exists(id)) setState(() => _select(id));
    if (mounted) showToast(context, '已保存');
  }

  // ---------- 上传（放到当前文件夹） ----------
  Future<void> _pickAndUpload(String kind, [String? at]) async {
    if (at != null && at != _folder) setState(() => _select(at));
    List<PanelFile> files;
    try {
      files = switch (kind) {
        'dir' => await pickPanelFolder(),
        'zip' => await pickPanelFiles(extensions: const ['zip'], multiple: false),
        _ => await pickPanelFiles(),
      };
    } catch (_) {
      if (mounted) showToast(context, '没有选到文件');
      return;
    }
    if (files.isEmpty || !mounted) return;
    if (kind == 'dir' && files.length > 300 && !await confirmDialog(context, title: '上传整个文件夹？', message: '这个文件夹里有 ${files.length} 个文件，确定都传上来吗？', ok: '上传')) return;
    // 选文件、拖进来的 zip 自动展开（保留里面的文件夹）；上传文件夹时夹带的 zip 原样保存
    await _upload([for (final f in files) (file: f, unzip: kind == 'zip' || (kind == 'files' && f.isZip))]);
  }

  Future<void> _upload(List<({PanelFile file, bool unzip})> items) async {
    final spot = _tree?.spot(_folder);
    if (spot == null || !spot.canEdit) return showToast(context, '这里是只读的，不能上传');
    final big = items.where((x) => x.file.size > (x.unzip ? 200 : 50) * 1024 * 1024).firstOrNull;
    if (big != null) return showAlert(context, '“${big.file.name}”太大了，${big.unzip ? 'zip 不能超过 200MB' : '单个文件不能超过 50MB'}');
    var added = 0, updated = 0;
    final errors = <String>[];
    for (var i = 0; i < items.length; i++) {
      final (:file, :unzip) = items[i];
      if (mounted) setState(() => _progress = '正在${unzip ? '上传并解压' : '上传'}到“${spot.name}”：${i + 1} / ${items.length} ${file.name}');
      try {
        final r = await uploadRaw(_ctl.api, '/api/lib/upload', file, {
          'X-Lib-Parent': Uri.encodeComponent(spot.parentId),
          'X-Lib-Root': Uri.encodeComponent(spot.rootEnv),
          'X-Lib-Path': Uri.encodeComponent(file.relPath),
          'X-Lib-Unzip': unzip ? '1' : '',
        });
        added += (r['added'] as num?)?.toInt() ?? 0;
        updated += (r['updated'] as num?)?.toInt() ?? 0;
        errors.addAll(asList(r['errors']).map(str));
      } on ApiError catch (e) {
        errors.add('${file.relPath}：${e.message}');
      } catch (_) {
        errors.add('${file.relPath}：读取失败，可能是没有权限');
      }
    }
    _progress = null;
    await _reload();
    if (!mounted) return;
    setState(() {
      _setOpen(_open..add(spot.id));
      _file = '';
    });
    final msg = '上传到“${_tree!.pathText(spot.id)}”：新增 $added 个文件${updated > 0 ? '，覆盖 $updated 个同名文件' : ''}';
    if (errors.isNotEmpty) {
      await showAlert(context, '$msg\n${errors.length} 个没传上：\n${errors.take(20).join('\n')}${errors.length > 20 ? '\n……' : ''}');
    } else {
      showToast(context, msg);
    }
  }

  /// 电脑上把文件（或文件夹）拖进来
  Future<void> _drop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    final items = <({PanelFile file, bool unzip})>[];
    for (final x in d.files) {
      final p = x.path;
      if (!kIsWeb && p.isNotEmpty && Directory(p).existsSync()) {
        items.addAll(listFolder(Directory(p)).map((f) => (file: f, unzip: false)));
        continue;
      }
      try {
        final f = PanelFile(name: x.name, size: await x.length(), path: p.isEmpty ? null : p, bytes: p.isEmpty ? await x.readAsBytes() : null);
        items.add((file: f, unzip: f.isZip));
      } catch (_) {}
    }
    if (items.isNotEmpty) await _upload(items);
  }

  // ---------- 界面 ----------
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final wide = isWide(context);
    if (_error != null && _tree == null) return EmptyHint(_error!);
    if (_tree == null) return const EmptyHint('加载中…', loading: true);
    final search = SearchBarRow(
      placeholder: '搜索文件名和内容',
      controller: _search,
      onSearch: _onSearch,
      leading: wide
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AIconButton(icon: Icons.folder_open_outlined, tooltip: '文件夹', size: 20, onPressed: _openTreeSheet),
            ),
    );
    Widget main = _main();
    final spot = _tree!.spot(_folder);
    if (s.isDesktop && !kIsWeb && spot != null && spot.canEdit && _editing == null) {
      main = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _drop,
        child: Stack(children: [
          Positioned.fill(child: main),
          if (_dragging)
            Positioned.fill(
                child: IgnorePointer(
                    child: Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: NT.accent.withValues(alpha: .1), borderRadius: BorderRadius.circular(NT.rLg), border: Border.all(color: NT.accent.withValues(alpha: .7), width: 2)),
                        child: Center(child: Text('松开就上传到“${spot.name}”', style: TextStyle(fontSize: NT.fTitle, color: NetbarColors(context).accentText)))))),
        ]),
      );
    }
    if (!wide) {
      // 手机上的返回键 / 返回手势：先回到文件夹列表
      return PopScope(
        canPop: _file.isEmpty && _query.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          setState(() {
            if (_query.isNotEmpty) {
              _clearSearch();
            } else {
              _file = '';
            }
          });
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [search, Expanded(child: main)]),
      );
    }
    return TwoPane(
        side: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [search, Expanded(child: _treeView(null))]), detail: main);
  }

  /// 窄的时候：文件夹树从“文件夹”按钮打开，选好自动收起
  Future<void> _openTreeSheet() async {
    final id = await pushPanel<String>(context, title: '文件夹', builder: (ctx) => _TreeHost(build: (setOuter) => _treeView((id) => Navigator.pop(ctx, id), setOuter)));
    if (id != null) await _go(id);
  }

  /// 文件夹树；onPick 不为空时（抽屉里）点文件夹名就交出去
  Widget _treeView(ValueChanged<String>? onPick, [StateSetter? setOuter]) {
    final t = _tree!;
    final open = _open;
    final rows = <Widget>[];
    void refresh() {
      setState(() {});
      setOuter?.call(() {});
    }

    Widget row(String id, String name, int depth, {bool hasSub = false, bool readOnly = false, bool menu = false, String count = '', String desc = '', IconData icon = Icons.folder_outlined}) {
      final isOpen = open.contains(id);
      return _TreeRow(
        name: name,
        depth: depth,
        icon: icon,
        count: count,
        readOnly: readOnly,
        tooltip: desc,
        active: id == _folder && _query.isEmpty,
        arrow: hasSub ? (isOpen ? 1 : 0) : -1,
        onArrow: () {
          isOpen ? open.remove(id) : open.add(id);
          _setOpen(open);
          refresh();
        },
        onTap: () {
          _setOpen(open..add(id));
          onPick != null ? onPick(id) : _go(id);
        },
        onMenu: menu ? (b) => _treeMenu(b, id, onPick) : null,
      );
    }

    final pins = t.nodes.where((n) => !n.isFolder && _prefs.isPinned('lib', n.id)).toList();
    if (pins.isNotEmpty) rows.add(row('pins', '置顶的文件', 0, count: '${pins.length}', icon: Icons.push_pin_outlined));
    void walk(String key, int depth) {
      for (final n in t.kidsOf(key).where((k) => k.isFolder)) {
        rows.add(row(n.id, n.name, depth,
            hasSub: t.kidsOf(n.id).any((k) => k.isFolder), menu: n.canEdit, count: '${t.fileCount(n.id)}', desc: n.description));
        if (open.contains(n.id)) walk(n.id, depth + 1);
      }
    }

    for (final r in t.roots) {
      final id = 'root:${r.env}';
      rows.add(row(id, r.name, 0, hasSub: t.kidsOf(id).any((k) => k.isFolder), readOnly: !r.canEdit, menu: r.canEdit, count: '${t.fileCount(id)}', desc: r.canEdit ? '' : '只能看，不能改'));
      if (open.contains(id)) walk(id, 1);
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: rows);
  }

  /// 树上的“⋯”菜单
  Future<void> _treeMenu(BuildContext b, String id, ValueChanged<String>? onPick) async {
    final t = _tree!;
    final spot = t.spot(id);
    if (spot == null || !spot.canEdit) return;
    final n = t.byId[id];
    final a = await actionSheet<String>(b, title: n?.name ?? spot.name, anchor: rectOf(b), actions: [
      const SheetAction('新建子文件夹', 'mkdir', icon: Icons.create_new_folder_outlined),
      const SheetAction('上传文件到这里', 'upload', icon: Icons.upload_file),
      const SheetAction('在这里新建文档', 'newdoc', icon: Icons.note_add_outlined),
      if (n != null) ...[
        const SheetAction('重命名', 'rename', icon: Icons.drive_file_rename_outline),
        const SheetAction('编辑说明', 'describe', icon: Icons.notes),
        const SheetAction('移动', 'move', icon: Icons.drive_file_move_outline),
        const SheetAction('删除', 'delete', icon: Icons.delete_outline, destructive: true),
      ],
    ]);
    if (a == null || !mounted) return;
    // 菜单里的操作都针对这个文件夹：先进入它（抽屉里的先收起）
    if (onPick != null) onPick(id);
    if (!await leaveEdit()) return;
    _clearSearch();
    if (_folder != id || _file.isNotEmpty) setState(() => _select(id));
    switch (a) {
      case 'mkdir':
        await _mkdir(id);
      case 'upload':
        await _pickAndUpload('files');
      case 'newdoc':
        await _newDoc(id);
      default:
        if (n != null) await _act(a, n);
    }
  }

  Widget _main() {
    final t = _tree!;
    if (_editing != null) {
      return LibDocEditor(
          key: ValueKey(_editing),
          editing: _editing!,
          onDone: (id) {
            setState(() => _editing = null);
            if (id != null) _afterSave(id);
          });
    }
    if (_query.isNotEmpty) return _resultsView();
    if (_file.isNotEmpty && t.byId.containsKey(_file)) return _fileView(t.byId[_file]!);
    if (_folder == 'pins') return _listView(null);
    final spot = t.spot(_folder);
    if (spot == null) return const EmptyHint('从左边选择一个文件夹', icon: Icons.folder_outlined);
    return _listView(spot);
  }

  Widget _crumbs(String id, {String? tail, VoidCallback? back}) {
    final c = NetbarColors(context);
    final parts = _tree!.path(id);
    final link = TextStyle(fontSize: NT.fCaption, color: c.accentText);
    final plain = TextStyle(fontSize: NT.fCaption, color: c.muted);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 2, children: [
      if (back != null) ...[_Link('← 返回', back), Text(' · ', style: plain)],
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) Text(' / ', style: plain),
        i < parts.length - 1 || tail != null ? _Link(parts[i].$2, () => _go(parts[i].$1)) : Text(parts[i].$2, style: plain.copyWith(color: c.text2)),
      ],
      if (tail != null) ...[Text(' / ', style: plain), Text(tail, style: plain.copyWith(color: c.text2))],
      if (parts.isEmpty && tail == null) Text('', style: link),
    ]);
  }

  /// 文件夹的内容列表（spot 为空 = 置顶的文件）
  Widget _listView(({String id, String parentId, String rootEnv, bool canEdit, String name})? spot) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final t = _tree!;
    final pins = spot == null;
    final n = spot == null ? null : t.byId[spot.id];
    final items = pins ? t.nodes.where((x) => !x.isFolder && _prefs.isPinned('lib', x.id)).toList() : t.kidsOf(spot.id);
    final canEdit = !pins && spot.canEdit;
    final checked = items.where((x) => _checked.contains(x.id) && x.canEdit).toList();
    final head = <Widget>[
      pins ? Text('置顶的文件（只在这台设备上）', style: TextStyle(fontSize: NT.fCaption, color: c.muted)) : _crumbs(spot.id),
      const SizedBox(height: 6),
      Row(children: [
        Icon(pins ? Icons.push_pin_outlined : Icons.folder_outlined, size: 20, color: c.text2),
        const SizedBox(width: 6),
        Flexible(child: Text(pins ? '置顶的文件' : spot.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: c.text))),
        const SizedBox(width: 8),
        Text('${pins ? items.length : t.fileCount(spot.id)} 个文件${canEdit || pins ? '' : ' · 只读'}', style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
      ]),
      if (n != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
            Text(n.description.isEmpty ? '没有说明' : n.description, style: TextStyle(fontSize: NT.fSmall, color: n.description.isEmpty ? c.muted : c.text2)),
            if (canEdit) _Link('编辑说明', () => _act('describe', n)),
          ]),
        ),
      if (canEdit)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (_selecting) ...[
              Text('已选 ${checked.length} 项', style: TextStyle(fontSize: NT.fSmall, color: c.text2)),
              AButton(label: '移动', icon: Icons.drive_file_move_outline, small: true, onPressed: checked.isEmpty ? null : () => _move(checked)),
              AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: checked.isEmpty ? null : () => _delete(checked)),
              AButton(
                  label: checked.length == items.where((x) => x.canEdit).length && checked.isNotEmpty ? '全不选' : '全选',
                  small: true,
                  kind: BtnKind.text,
                  onPressed: () => setState(() {
                        final all = items.where((x) => x.canEdit).map((x) => x.id);
                        checked.length == all.length ? _checked.removeAll(all) : _checked.addAll(all);
                      })),
              AButton(
                  label: '取消选择',
                  small: true,
                  kind: BtnKind.text,
                  onPressed: () => setState(() {
                        _checked.clear();
                        _selecting = false;
                      })),
            ] else ...[
              AButton(label: '上传文件', icon: Icons.upload_file, small: true, kind: BtnKind.primary, onPressed: _progress == null ? () => _pickAndUpload('files') : null),
              if (canPickFolder) AButton(label: '上传文件夹', icon: Icons.drive_folder_upload_outlined, small: true, onPressed: _progress == null ? () => _pickAndUpload('dir') : null),
              AButton(label: '上传 zip', icon: Icons.folder_zip_outlined, small: true, onPressed: _progress == null ? () => _pickAndUpload('zip') : null),
              AButton(label: '新建文档', icon: Icons.note_add_outlined, small: true, onPressed: () => _newDoc(spot.id)),
              AButton(label: '新建文件夹', icon: Icons.create_new_folder_outlined, small: true, onPressed: () => _mkdir(spot.id)),
              if (items.any((x) => x.canEdit)) AButton(label: '选择', icon: Icons.checklist, small: true, kind: BtnKind.text, onPressed: () => setState(() => _selecting = true)),
            ],
          ]),
        ),
      if (_progress != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            const ASpinner(),
            const SizedBox(width: 8),
            Expanded(child: Text(_progress!, style: TextStyle(fontSize: NT.fSmall, color: c.muted))),
          ]),
        ),
    ];
    return ListView(padding: EdgeInsets.fromLTRB(s.isDesktop ? 16 : 0, 12, s.isDesktop ? 16 : 0, 24), children: [
      Padding(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 4 : 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: head)),
      const SizedBox(height: 8),
      if (items.isEmpty)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
                pins
                    ? '还没有置顶的文件：打开文件后点“置顶”'
                    : canEdit
                        ? '这个文件夹是空的：点上面的“上传文件”${s.isDesktop ? '，或者直接把文件拖到这里' : ''}'
                        : '这个文件夹是空的',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, fontSize: NT.fSmall)))
      else
        RowGroup(children: [
          for (final x in items)
            ListRow(
              title: x.name,
              leading: Icon(x.isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16, color: x.isFolder ? NT.warn : c.muted),
              subtitle: x.description,
              meta: [x.isFolder ? '${t.fileCount(x.id)} 个文件' : libSize(x.size), fmtTime(x.updatedAt), if (pins) t.pathText(x.parentKey)].where((v) => v.isNotEmpty).join(' · '),
              selected: _checked.contains(x.id),
              onTap: () {
                if (_selecting && x.canEdit) return setState(() => _checked.contains(x.id) ? _checked.remove(x.id) : _checked.add(x.id));
                _go(x.id);
              },
              onLongPress: () => _rowMenu(context, x),
              trailing: _selecting
                  ? (x.canEdit
                      ? Checkbox.adaptive(value: _checked.contains(x.id), onChanged: (v) => setState(() => v == true ? _checked.add(x.id) : _checked.remove(x.id)))
                      : const SizedBox(width: 44))
                  : Builder(builder: (b) => AIconButton(icon: Icons.more_horiz, tooltip: '更多操作', onPressed: () => _rowMenu(b, x))),
            ),
        ]),
    ]);
  }

  Future<void> _rowMenu(BuildContext b, LibNode x) async {
    final a = await actionSheet<String>(b, title: x.name, anchor: rectOf(b), actions: [
      SheetAction(x.isFolder ? '打开' : '查看', 'open', icon: Icons.open_in_new),
      if (!x.isFolder) const SheetAction('下载', 'download', icon: Icons.download_outlined),
      if (!x.isFolder) SheetAction(_prefs.isPinned('lib', x.id) ? '取消置顶' : '置顶', 'pin', icon: Icons.push_pin_outlined),
      if (x.canEdit) ...[
        const SheetAction('重命名', 'rename', icon: Icons.drive_file_rename_outline),
        const SheetAction('编辑说明', 'describe', icon: Icons.notes),
        const SheetAction('移动', 'move', icon: Icons.drive_file_move_outline),
        const SheetAction('删除', 'delete', icon: Icons.delete_outline, destructive: true),
      ],
    ]);
    if (a == null || !mounted) return;
    if (a == 'open') return _go(x.id);
    await _act(a, x, b.mounted ? b : null);
  }

  /// 搜索结果：名字匹配的 + 内容命中的（显示命中的那一句，点开自动标出来）
  Widget _resultsView() {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final t = _tree!;
    final q = _query;
    final hits = _results;
    final hitIds = {for (final h in hits ?? const <Map<String, dynamic>>[]) str(h['id'])};
    final byName = t.nodes.where((n) => n.name.toLowerCase().contains(q.toLowerCase()) && !hitIds.contains(n.id)).take(30).toList();
    final head = Padding(
      padding: EdgeInsets.fromLTRB(s.isDesktop ? 20 : 16, 12, 16, 8),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        Text('搜索“$q”', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: c.text)),
        _Link('清除搜索', () => setState(_clearSearch)),
      ]),
    );
    if (hits == null && byName.isEmpty) return Column(children: [head, const Expanded(child: EmptyHint('搜索中…', loading: true))]);
    final rows = <Widget>[
      for (final n in byName)
        ListRow(
          title: n.name,
          query: q,
          leading: Icon(n.isFolder ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16, color: n.isFolder ? NT.warn : c.muted),
          subtitle: t.pathText(n.parentKey),
          meta: '名称匹配',
          onTap: () => _go(n.id),
        ),
      for (final h in hits ?? const <Map<String, dynamic>>[])
        if (t.byId[str(h['id'])] case final n?)
          ListRow(
            title: n.name,
            query: q,
            leading: Icon(Icons.insert_drive_file_outlined, size: 16, color: c.muted),
            subtitle: t.pathText(n.parentKey),
            snippet: snippetOf(str(h['snippet']), q, width: 60) ?? (str(h['snippet']), '', ''),
            onTap: () {
              _jump = q;
              _jumpFile = n.id;
              _go(n.id);
            },
          ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      Expanded(
          child: rows.isEmpty
              ? const EmptyHint('没有找到匹配的文件或文件夹')
              : ListView(padding: EdgeInsets.symmetric(horizontal: s.isDesktop ? 16 : 0), children: [RowGroup(children: rows)])),
    ]);
  }

  Widget _fileView(LibNode n) {
    final c = NetbarColors(context);
    final editable = n.canEdit && libTextExts.hasMatch(n.name);
    final pinned = _prefs.isPinned('lib', n.id);
    // 从搜索结果点进来的：标出命中的地方
    final jump = _jumpFile == n.id ? _jump : '';
    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
      _crumbs(n.parentKey, tail: n.name, back: () => _go(n.parentKey)),
      const SizedBox(height: 8),
      Row(children: [
        Icon(Icons.insert_drive_file_outlined, size: 20, color: c.text2),
        const SizedBox(width: 6),
        Expanded(child: Text(n.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text))),
      ]),
      const SizedBox(height: 4),
      Text(
          [
            libSize(n.size),
            '更新于 ${fmtTime(n.updatedAt)}',
            if (n.textLen > 0) '读出 ${n.textLen} 字',
            if (n.textNote.isNotEmpty) n.textNote,
            if (!n.canEdit) '只读',
          ].join(' · '),
          style: TextStyle(fontSize: 11.5, color: c.muted)),
      const SizedBox(height: 6),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
        Text(n.description.isEmpty ? '没有说明（AI 搜到、浏览到这个文件时能看到说明）' : n.description,
            style: TextStyle(fontSize: NT.fSmall, color: n.description.isEmpty ? c.muted : c.text2)),
        if (n.canEdit) _Link('编辑说明', () => _act('describe', n)),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (editable) AButton(label: '编辑', icon: Icons.edit_outlined, small: true, onPressed: () => _act('edit', n)),
        Builder(builder: (b) => AButton(label: '下载', icon: Icons.download_outlined, small: true, onPressed: () => _act('download', n, b))),
        AButton(label: pinned ? '取消置顶' : '置顶', icon: Icons.push_pin_outlined, small: true, onPressed: () => _act('pin', n)),
        if (n.canEdit) ...[
          AButton(label: '重命名', icon: Icons.drive_file_rename_outline, small: true, onPressed: () => _act('rename', n)),
          AButton(label: '移动', icon: Icons.drive_file_move_outline, small: true, onPressed: () => _act('move', n)),
          AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: () => _act('delete', n)),
        ],
      ]),
      Divider(height: 24, color: c.line),
      LibPreview(key: ValueKey('${n.id}@${n.raw['updatedAt']}'), node: n, jump: jump),
    ]);
  }
}

class _Link extends StatelessWidget {
  const _Link(this.text, this.onTap);
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
      onTap: onTap,
      label: text,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1), child: Text(text, style: TextStyle(fontSize: NT.fCaption + 0.5, color: NetbarColors(context).accentText))));
}

/// 抽屉里的文件夹树：展开、收起时自己也要重画
class _TreeHost extends StatefulWidget {
  const _TreeHost({required this.build});
  final Widget Function(StateSetter setOuter) build;
  @override
  State<_TreeHost> createState() => _TreeHostState();
}

class _TreeHostState extends State<_TreeHost> {
  @override
  Widget build(BuildContext context) => widget.build(setState);
}

class _TreeRow extends StatelessWidget {
  const _TreeRow(
      {required this.name,
      required this.depth,
      required this.icon,
      required this.count,
      required this.readOnly,
      required this.tooltip,
      required this.active,
      required this.arrow,
      required this.onArrow,
      required this.onTap,
      this.onMenu});
  final String name, count, tooltip;
  final int depth;

  /// -1 没有子文件夹；0 收起；1 展开
  final int arrow;
  final IconData icon;
  final bool readOnly, active;
  final VoidCallback onArrow, onTap;
  final void Function(BuildContext)? onMenu;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final row = Container(
      color: active ? NT.accent.withValues(alpha: .1) : null,
      padding: EdgeInsets.only(left: 6 + depth * 14.0, right: 4),
      constraints: BoxConstraints(minHeight: s.isMobile ? 44 : 32),
      child: Row(children: [
        SizedBox(
            width: 26,
            child: arrow < 0
                ? null
                : Pressable(
                    onTap: onArrow, label: arrow == 1 ? '收起' : '展开', child: Icon(arrow == 1 ? Icons.expand_more : Icons.chevron_right, size: 18, color: c.muted))),
        Icon(icon, size: 17, color: active ? c.accentText : NT.warn),
        const SizedBox(width: 6),
        Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: s.isMobile ? NT.fBody : NT.fSmall, color: active ? c.accentText : c.text, fontWeight: active ? FontWeight.w600 : null))),
        if (count.isNotEmpty) Text(count, style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
        if (readOnly) const Padding(padding: EdgeInsets.only(left: 4), child: Tag('只读')),
        if (onMenu != null) Builder(builder: (b) => AIconButton(icon: Icons.more_horiz, tooltip: '更多操作', size: 16, onPressed: () => onMenu!(b))) else const SizedBox(width: 6),
      ]),
    );
    final tapped = Pressable(onTap: onTap, label: name, child: row);
    return tooltip.isEmpty || s.isMobile ? tapped : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 600), child: tapped);
  }
}

/// 文件预览：图片直接显示；能读出文字的显示文字（md 按格式显示；PDF、Word、Excel 显示读出的文字）；从搜索点进来时标出命中的地方
class LibPreview extends StatefulWidget {
  const LibPreview({super.key, required this.node, this.jump = ''});
  final LibNode node;
  final String jump;
  @override
  State<LibPreview> createState() => _LibPreviewState();
}

class _LibPreviewState extends State<LibPreview> {
  Uint8List? _image;
  String? _text, _error;
  int _total = 0;
  bool _loading = true;
  LibNode get n => widget.node;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = NetbarScope.read(context).controller.api;
    try {
      if (libImageExts.hasMatch(n.name) && n.size <= 10 * 1024 * 1024) {
        _image = await api.postBytes('/api/lib/download', {'id': n.id});
      } else {
        final r = await api.post('/api/lib/file', {'id': n.id});
        _text = str(r['text']);
        _total = (r['total'] as num?)?.toInt() ?? 0;
      }
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    if (_loading) return const Padding(padding: EdgeInsets.all(20), child: Center(child: ASpinner(size: 18)));
    if (_error != null) return Text(_error!, style: TextStyle(color: c.muted, fontSize: NT.fSmall));
    if (_image != null) {
      return Align(
          alignment: Alignment.topLeft,
          child: Image.memory(_image!, fit: BoxFit.contain, errorBuilder: (_, _, _) => Text('图片显示不了，可以下载查看', style: TextStyle(color: c.muted))));
    }
    final text = _text ?? '';
    if (_total == 0) return EmptyHint('${n.textNote.isNotEmpty ? n.textNote : '这个文件没有文字内容'}，可以下载查看');
    final ext = RegExp(r'\.([a-z0-9]+)$', caseSensitive: false).firstMatch(n.name)?.group(1)?.toLowerCase() ?? '';
    final md = ext == 'md' || ext == 'markdown';
    final jump = _jumpTerm(text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (jump != null)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: NT.warn.withValues(alpha: .08), borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: NT.warn.withValues(alpha: .35))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('搜索命中的地方', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.warnText)),
            const SizedBox(height: 4),
            SnippetLine(snippetOf(text, jump, width: 120)!, maxLines: 6),
          ]),
        ),
      if (const ['pdf', 'docx', 'xlsx', 'pptx'].contains(ext))
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('下面是从文件里读出的文字（AI 看到的就是这些）：', style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
      if (md)
        MarkdownBody(text)
      else
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(NT.rSm)),
          child: SelectableText.rich(TextSpan(children: highlightAll(text, jump ?? '', markColor(context))), style: monoStyle(size: 12.5, color: c.text)),
        ),
      if (_total > text.length)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('文件很长，这里只显示前 ${text.length} 字，完整内容请下载', style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
    ]);
  }

  /// 搜索词能在文字里找到的那一段（整句找不到就找其中一个词）
  String? _jumpTerm(String text) {
    final q = widget.jump.trim();
    if (q.isEmpty) return null;
    final lower = text.toLowerCase();
    for (final t in [q, ...q.split(RegExp(r'\s+'))].where((t) => t.length >= 2)) {
      if (lower.contains(t.toLowerCase())) return t;
    }
    return null;
  }
}

/// 把所有命中的地方都标出来
List<InlineSpan> highlightAll(String text, String q, Color mark) {
  if (q.isEmpty) return [TextSpan(text: text)];
  final out = <InlineSpan>[];
  final lower = text.toLowerCase(), ql = q.toLowerCase();
  var i = 0;
  while (true) {
    final j = lower.indexOf(ql, i);
    if (j < 0) break;
    out
      ..add(TextSpan(text: text.substring(i, j)))
      ..add(TextSpan(text: text.substring(j, j + q.length), style: TextStyle(backgroundColor: mark)));
    i = j + q.length;
  }
  out.add(TextSpan(text: text.substring(i)));
  return out;
}

/// 新建、编辑文档
class LibDocEditor extends StatefulWidget {
  const LibDocEditor({super.key, required this.editing, required this.onDone});
  final LibEditing editing;

  /// 保存成功传文件编号，取消传 null
  final ValueChanged<String?> onDone;
  @override
  State<LibDocEditor> createState() => _LibDocEditorState();
}

class _LibDocEditorState extends State<LibDocEditor> {
  late final _name = TextEditingController(text: widget.editing.name);
  late final _content = TextEditingController(text: widget.editing.content);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.editing;
    setState(() => _saving = true);
    try {
      final r = await NetbarScope.read(context).controller.api.post('/api/lib/save-text', {
        'id': e.id,
        'parentId': e.parentId,
        'rootEnv': e.rootEnv,
        'name': _name.text,
        'content': _content.text,
      });
      widget.onDone(str(asMap(r['node'])['id']));
    } on ApiError catch (er) {
      if (mounted) {
        setState(() => _saving = false);
        await showAlert(context, er.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final e = widget.editing;
    return EditorLayout(
      top: [
        Text(e.id == null ? '新建文档' : '编辑：${e.name}', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: c.text)),
        if (e.id == null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('放在：${e.where}', style: TextStyle(fontSize: NT.fCaption, color: c.muted))),
        const SizedBox(height: 12),
        AField(controller: _name, label: '文件名', hint: '例如：计费系统说明.md（不写扩展名就是 .md）', maxLength: 120, autofocus: e.id == null),
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
