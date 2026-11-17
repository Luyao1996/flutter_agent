// 工具库（对应网页版 tools.js）：网吧电脑上的 AI 助手能用的工具（zip 程序包或 http_get 接口），存在 SFU 上，两台各存一份
// 查询、新增、修改、删除，zip 上传（带进度）和下载；参数填表（怎么传给程序、选项名、实时显示程序收到的命令行）、帮助指令、风险等中文选项
// 身份：链接里有登录令牌（后台回 hasToken）就不用密码；没有时先输入 SFU 管理密码，换回的管理凭据只记在内存里（相当于网页的当前标签页），按 SFU 分开
// 修改权限由后台按身份算（每个工具的 canEdit、owner）：只有上传那一边能改删，管理员上传的只有用管理密码打开的能改
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import '../services.dart' as services;
import '../ui/adaptive.dart';
import 'common.dart';
import 'listview.dart';
import 'panel_files.dart';
import 'tool_args.dart';

/// 打开工具库；name：直接打开这个工具的详情（消息里的工具标签、“使用了工具”一行点进来）
Future<void> openToolsPanel(BuildContext context, {String? name}) {
  final h = PanelRefresh();
  return pushPanel(context, title: '工具', width: 1100, actions: refreshActions(h), builder: (_) => ToolsPanel(selectName: name, refresh: h));
}

/// 输入过的管理凭据：只在内存里（组件关掉就没了），按 SFU 分开
final _toolKeys = Expando<Map<int, String>>('toolKeys');
Map<int, String> _keysOf(ChatController c) => _toolKeys[c] ??= {};

typedef ToolItem = Map<String, dynamic>;
String _title(ToolItem x) => str(x['title']).isEmpty ? str(x['name']) : str(x['title']);
String _owner(ToolItem x) => str(x['owner']).isEmpty ? 'admin' : str(x['owner']);
DateTime? _updated(ToolItem x) => parseTime(x['updatedAt'] ?? x['uploadedAt'] ?? x['mtime'] ?? x['time']);

class ToolsPanel extends StatefulWidget {
  const ToolsPanel({super.key, this.selectName, this.refresh});
  final String? selectName;
  final PanelRefresh? refresh;
  @override
  State<ToolsPanel> createState() => _ToolsPanelState();
}

class _ToolsPanelState extends State<ToolsPanel> {
  List<(int, String)> _sfus = [];
  int _sfu = 0;
  bool _hasToken = false;
  List<ToolItem> _items = [];
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error, _selected;
  String _q = '', _sort = 'name', _type = 'all', _ownerF = 'all';
  ({ToolForm form, bool isNew})? _editing; // 宽屏时在右侧编辑
  bool _uploading = false;
  ChatController get _ctl => NetbarScope.read(context).controller;
  String get _key => _keysOf(_ctl)[_sfu] ?? '';
  bool get _can => _hasToken || _key.isNotEmpty;
  String get _sfuName => _sfus.where((s) => s.$1 == _sfu).firstOrNull?.$2 ?? 'SFU';
  String get _listKey => 'tools-$_sfuName';
  Map<String, dynamic> _body([Map<String, dynamic> extra = const {}]) => {'sfu': _sfu, if (!_hasToken && _key.isNotEmpty) 'key': _key, ...extra};

  @override
  void initState() {
    super.initState();
    _selected = widget.selectName;
    widget.refresh
      ?..reload = _load
      ..editing = () => _editing != null;
    _start();
  }

  Future<void> _start() async {
    await ListPrefs.instance.load();
    try {
      final r = await _ctl.api.post('/api/tools/sfus', _body());
      _sfus = [for (final x in asList(r['items']).map(asMap)) ((x['id'] as num?)?.toInt() ?? 0, str(x['name']))];
      _hasToken = r['hasToken'] == true;
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
      return;
    }
    await _load();
    // 从对话里点开某个工具：手机上直接打开详情页
    if (mounted && widget.selectName != null && !isWide(context)) {
      final x = _items.where((i) => i['name'] == widget.selectName).firstOrNull;
      if (x != null) {
        _selected = null;
        _openDetail(x);
      } else if (_can && _error == null) {
        showToast(context, '工具库里没有找到“${widget.selectName}”，可能已被删除或在另一台 SFU 上');
      }
    }
  }

  Future<void> _load() async {
    await ListPrefs.instance.load();
    _editing = null;
    if (!_can) {
      setState(() {
        _items = [];
        _data = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final r = await _ctl.api.post('/api/tools/list', _body());
      _data = r;
      _items = asList(r['tools']).map(asMap).toList();
      _error = null;
    } on ApiError catch (e) {
      // 管理凭据不对了（密码改过）：清掉，重新输入
      if (!_hasToken && _key.isNotEmpty && e.message.contains('拒绝')) {
        _keysOf(_ctl).remove(_sfu);
        if (mounted) showToast(context, '管理密码已失效，请重新输入');
        return _load();
      }
      _items = [];
      _data = null;
      _error = e.message;
    }
    if (!_items.any((x) => x['name'] == _selected)) _selected = null;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _login() async {
    final pw = await _askPassword(context, '输入 $_sfuName 的管理密码');
    if (pw == null || pw.isEmpty || !mounted) return;
    try {
      final r = await _ctl.api.post('/api/tools/login', {'sfu': _sfu, 'password': pw});
      _keysOf(_ctl)[_sfu] = str(r['key']);
      if (mounted) showToast(context, '密码正确，可以管理工具了');
    } on ApiError catch (e) {
      if (mounted) await showAlert(context, e.message);
      return;
    }
    await _load();
  }

  Future<bool> _leaveEdit() async {
    if (_uploading) {
      showToast(context, '正在上传，等传完再切换');
      return false;
    }
    if (_editing != null && !await confirmDialog(context, title: '放弃修改？', message: '正在编辑的内容还没保存，确定放弃吗？', ok: '放弃', destructive: true)) return false;
    _editing = null;
    return true;
  }

  List<ToolItem> get _visible {
    final ql = _q.trim().toLowerCase();
    final list = _items
        .where((x) => ql.isEmpty || [x['name'], x['title'], x['desc'], x['category'], x['type']].map(str).join('\n').toLowerCase().contains(ql))
        .where((x) => _type == 'all' || x['type'] == _type)
        .where((x) => _ownerF == 'all' || _owner(x) == _ownerF)
        .toList();
    list.sort(_sort == 'updated' ? (a, b) => (_updated(b) ?? DateTime(0)).compareTo(_updated(a) ?? DateTime(0)) : (a, b) => _title(a).compareTo(_title(b)));
    return list;
  }

  Future<void> _edit(ToolItem? x) async {
    if (!await _leaveEdit()) return;
    final e = (form: x == null ? ToolForm() : ToolForm.of(x), isNew: x == null);
    if (!mounted) return;
    if (isWide(context)) {
      return setState(() {
        _editing = e;
        if (x == null) _selected = null;
      });
    }
    final saved = await pushPanel<String>(context, title: x == null ? '新增工具' : '修改工具', builder: (ctx) => _editor(e, (name) => Navigator.pop(ctx, name)));
    if (saved != null) {
      _selected = saved;
      await _load();
    }
  }

  Widget _editor(({ToolForm form, bool isNew}) e, ValueChanged<String?> onDone) => ToolEditor(
        key: ObjectKey(e.form),
        form: e.form,
        isNew: e.isNew,
        items: _items,
        full: _data?['full'] != false,
        upload: _upload,
        onBusy: (b) => _uploading = b,
        onDone: onDone,
      );

  /// 上传（新增、修改）：zip 用 multipart（meta + 程序包，只改说明时只有 meta），http_get 用 JSON
  Future<Map<String, dynamic>> _upload(Map<String, dynamic> meta, PanelFile? file, void Function(int, int) onProgress) async {
    final api = _ctl.api;
    final mp = meta['type'] == 'zip' ? toolMultipart(meta, file) : null;
    final json = mp == null ? Uint8List.fromList(utf8.encode(jsonEncode(meta))) : null;
    final r = await api.postRaw('/api/tools/upload',
        body: mp?.body ?? () => Stream.value(json!),
        length: mp?.length ?? json!.length,
        onProgress: file == null ? null : onProgress,
        headers: () => {
              'Content-Type': mp?.type ?? 'application/json',
              'X-Ops-Mcp': api.key,
              'X-Ops-Token': api.conn,
              'X-Ops-Key': _hasToken ? '' : _key,
              'X-Ops-Sfu': '$_sfu',
            });
    if (r['ok'] == false) throw ApiError(str(r['error']).isNotEmpty ? str(r['error']) : str(r['message']));
    return r;
  }

  Future<bool> _delete(ToolItem x) async {
    if (!await confirmDialog(context, title: '删除工具？', message: '确定从 $_sfuName 删除工具“${_title(x)}”吗？网吧电脑上的 AI 助手以后就用不了它了。', ok: '删除', destructive: true)) return false;
    try {
      await _ctl.api.post('/api/tools/delete', _body({'name': x['name']}));
    } on ApiError catch (e) {
      if (mounted) await showAlert(context, e.message);
      return false;
    }
    if (mounted) showToast(context, '已删除');
    _selected = null;
    await _load();
    return true;
  }

  Future<void> _download(ToolItem x, BuildContext from) async {
    final origin = rectOf(from);
    showToast(context, '正在下载 ${x['name']}.zip…');
    try {
      final r = await _ctl.api.post('/api/tools/link', _body({'name': x['name']}));
      final bytes = await _ctl.api.getBytes(str(r['url']));
      await services.saveFile(bytes, '${x['name']}.zip', origin: origin);
    } on ApiError catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, '保存失败，请再试一次');
    }
  }

  void _togglePin(ToolItem x) {
    final on = ListPrefs.instance.togglePin(_listKey, str(x['name']));
    showToast(context, on ? '已置顶，只在这台设备上生效' : '已取消置顶');
    setState(() {});
  }

  Future<void> _openDetail(ToolItem x) async {
    if (isWide(context)) {
      if (!await _leaveEdit()) return;
      return setState(() => _selected = str(x['name']));
    }
    await pushPanel(context,
        title: '工具',
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setInner) => ToolDetail(
                  item: x,
                  can: _can,
                  pinned: ListPrefs.instance.isPinned(_listKey, str(x['name'])),
                  onEdit: () async {
                    Navigator.pop(ctx);
                    await _edit(x);
                  },
                  onDelete: () async {
                    if (await _delete(x) && ctx.mounted) Navigator.pop(ctx);
                  },
                  onDownload: (b) => _download(x, b),
                  onPin: () => setInner(() => _togglePin(x)),
                )));
  }

  Future<void> _switchSfu() async {
    final r = await actionSheet<int>(context, title: '选择 SFU', message: '两台 SFU 各存一份、不互相同步，要在哪台用就往哪台传', actions: [for (final (id, name) in _sfus) SheetAction(name, id, checked: id == _sfu)]);
    if (r == null || r == _sfu || !await _leaveEdit()) return;
    setState(() {
      _sfu = r;
      _selected = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final wide = isWide(context);
    final list = _visible;
    final ql = _q.trim();
    // 宽屏：右边不空着，默认打开列表第一条
    if (wide && _editing == null && list.isNotEmpty && !list.any((x) => x['name'] == _selected)) _selected = str(list.first['name']);
    final owners = _items.map(_owner).toSet();
    final types = _items.map((x) => str(x['type'])).toSet();
    const ownerNames = {'toolbox': 'toolbox', 'yx': '银杏', 'cloud': '云启动', 'admin': '管理员'};
    final groups = [
      FilterGroup('sort', '排序', _sort, const [('name', '名称'), ('updated', '最近更新')]),
      FilterGroup('type', '类型', _type, types.length > 1 ? const [('all', '全部'), ('zip', '程序包'), ('http_get', '接口')] : const []),
      FilterGroup('owner', '上传', _ownerF, owners.length > 1 ? [('all', '全部'), for (final o in ownerNames.keys) if (owners.contains(o)) (o, ownerNames[o]!)] : const []),
    ];
    final active = [
      if (_sort != 'name') ActiveFilter('排序：最近更新', () => setState(() => _sort = 'name')),
      if (_type != 'all') ActiveFilter('类型：${_type == 'zip' ? '程序包' : '接口'}', () => setState(() => _type = 'all')),
      if (_ownerF != 'all') ActiveFilter('上传：${ownerNames[_ownerF] ?? _ownerF}', () => setState(() => _ownerF = 'all')),
    ];
    final d = _data ?? const {};
    final used = (d['used'] ?? d['usedBytes'] ?? asMap(d['space'])['used'] ?? asMap(d['usage'])['used'] ?? _items.fold<num>(0, (n, x) => n + ((x['size'] as num?) ?? 0))) as num;
    final limit = (d['limit'] ?? d['limitBytes'] ?? asMap(d['space'])['limit'] ?? asMap(d['usage'])['limit'] ?? 20 * (1 << 30)) as num;
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (_sfus.isNotEmpty) AButton(label: 'SFU：$_sfuName', icon: Icons.dns_outlined, small: true, onPressed: _sfus.length > 1 ? _switchSfu : null),
        if (!_hasToken && _sfus.isNotEmpty)
          if (_key.isNotEmpty) ...[
            Tag('已输入管理密码', icon: Icons.verified_user_outlined, color: c.okText),
            AButton(
                label: '退出管理',
                kind: BtnKind.text,
                small: true,
                onPressed: () {
                  _keysOf(_ctl).remove(_sfu);
                  _load();
                }),
          ] else
            AButton(label: '输入管理密码', icon: Icons.shield_outlined, small: true, onPressed: _login),
        if (_data != null) Text('${_items.length} / 500 个工具 · 已用 ${toolSize(used)} / ${toolSize(limit)}', style: monoStyle(size: 11.5, color: c.muted)),
      ]),
    );
    final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      bar,
      SearchBarRow(
        placeholder: '搜索工具',
        onSearch: (v) => setState(() => _q = v),
        groups: groups,
        onFilter: (name, v) => setState(() => switch (name) { 'sort' => _sort = v, 'type' => _type = v, _ => _ownerF = v }),
        onCompact: () => setState(() {}),
        active: active,
        actions: [if (_can) AIconButton(icon: Icons.add, tooltip: '新增工具', size: 20, onPressed: () => _edit(null))],
      ),
      Expanded(
        child: _loading
            ? const EmptyHint('加载中…', loading: true)
            : _error != null
                ? EmptyHint(_error!)
                : !_can
                    ? const EmptyHint('这个页面的链接没有登录身份，输入管理密码后才能查看和管理工具', icon: Icons.shield_outlined)
                    : CategoryList<ToolItem>(
                        items: list,
                        idOf: (x) => str(x['name']),
                        groupOf: (x) => str(x['category']),
                        listKey: _listKey,
                        query: ql,
                        empty: ql.isNotEmpty || _type != 'all' || _ownerF != 'all' ? '没有找到匹配的工具' : '还没有工具，点“+”添加一个',
                        row: (x, compact) {
                          final qq = ql.toLowerCase();
                          final hitName = qq.isNotEmpty && !_title(x).toLowerCase().contains(qq) && !str(x['desc']).toLowerCase().contains(qq);
                          return ListRow(
                            title: _title(x),
                            query: ql,
                            leading: Tag(str(x['type']), color: x['type'] == 'zip' ? const Color(0xFF0EA5E9) : const Color(0xFF10B981)),
                            subtitle: compact ? null : str(x['desc']),
                            snippet: compact || !hitName ? null : snippetOf('${x['name']} ${x['category'] ?? ''}', ql),
                            meta: compact ? null : '${x['name']} · ${toolOwners[_owner(x)] ?? '管理员上传'}${(x['size'] as num? ?? 0) > 0 ? ' · ${toolSize(x['size'] as num)}' : ''}',
                            selected: x['name'] == _selected,
                            onTap: () => _openDetail(x),
                          );
                        }),
      ),
    ]);
    if (!wide) return side;
    final sel = _items.where((x) => x['name'] == _selected).firstOrNull;
    final detail = _editing != null
        ? _editor(_editing!, (name) async {
            setState(() {
              _editing = null;
              if (name != null) _selected = name;
            });
            if (name != null) await _load();
          })
        : sel == null
            ? EmptyHint(_can ? '从列表中选择一个工具查看，或点“+”新增' : '输入管理密码后才能查看工具', icon: Icons.handyman_outlined)
            : ToolDetail(
                key: ValueKey(sel['name']),
                item: sel,
                can: _can,
                pinned: ListPrefs.instance.isPinned(_listKey, str(sel['name'])),
                onEdit: () => _edit(sel),
                onDelete: () => _delete(sel),
                onDownload: (b) => _download(sel, b),
                onPin: () => _togglePin(sel),
              );
    return TwoPane(side: side, detail: detail);
  }
}

/// 输入密码的小窗口（输入的字不显示出来）
Future<String?> _askPassword(BuildContext context, String title) async {
  var v = '';
  final ok = await confirmDialog(context, title: title, content: _PasswordField(onChanged: (t) => v = t));
  return ok ? v : null;
}

/// 输入框自己管 controller（对话框关闭动画里还会用到，不能一关就释放）
class _PasswordField extends StatefulWidget {
  const _PasswordField({required this.onChanged});
  final ValueChanged<String> onChanged;
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    return s.isCupertino
        ? CupertinoTextField(controller: _c, obscureText: true, autofocus: true, placeholder: '管理密码', onChanged: widget.onChanged)
        : TextField(controller: _c, obscureText: true, autofocus: true, onChanged: widget.onChanged, decoration: fieldDecoration(context, hint: '管理密码', dense: s.isDesktop));
  }
}

/// 一个工具的详情
class ToolDetail extends StatelessWidget {
  const ToolDetail(
      {super.key,
      required this.item,
      required this.can,
      required this.pinned,
      required this.onEdit,
      required this.onDelete,
      required this.onDownload,
      required this.onPin});
  final ToolItem item;
  final bool can, pinned;
  final VoidCallback onEdit, onDelete, onPin;
  final void Function(BuildContext) onDownload;

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final x = item;
    final zip = x['type'] == 'zip';
    final params = asMap(x['params']);
    final args = asList(x['args']).map(str).toList();
    final parsed = zip ? toolParseArgs(args, params) : null;
    final problems = toolArgProblems(x);
    final editable = can && x['canEdit'] != false;
    final owner = _owner(x);
    final t = _updated(x);
    ParamRow rowOf(String k) {
      final p = asMap(params[k]);
      final h = parsed?.how[k];
      return ParamRow(name: k, desc: str(p['desc']), how: h?.how ?? '', opt: h?.opt ?? '', def: str(p['default']), required: p['required'] == true);
    }

    String howText(ParamRow r) => r.how.isEmpty
        ? '没用到，传了也到不了程序'
        : r.how == 'pos'
            ? '只传值'
            : r.how == 'flag'
                ? '开关：${r.opt}'
                : '${r.opt} + 值';
    final mode = str(x['mode']).isEmpty ? 'silent' : str(x['mode']);
    Widget warn(String text) => Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: TextStyle(fontSize: NT.fSmall, color: c.dangerText)));
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(_title(x), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text)),
        Tag(str(x['type']), color: zip ? const Color(0xFF0EA5E9) : const Color(0xFF10B981)),
      ]),
      const SizedBox(height: 4),
      Text(
          [
            str(x['name']),
            if ((x['size'] as num? ?? 0) > 0) toolSize(x['size'] as num),
            if (t != null) '更新于 ${fmtTime(t)}',
            if (str(x['by']).isNotEmpty) '${x['by']} 最后上传',
            toolOwners[owner] ?? '管理员上传',
          ].join(' · '),
          style: TextStyle(fontSize: 11.5, color: c.muted)),
      if (can && x['canEdit'] == false)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('这个工具是${toolOwnerWho[owner] ?? '管理员'}上传的，${owner != 'admin' && str(x['owner']).isNotEmpty ? '只有那边的人' : '只有用管理密码打开的页面'}能修改、删除；你可以查看、下载、使用。',
              style: TextStyle(fontSize: NT.fSmall, color: c.warnText)),
        ),
      const SizedBox(height: 10),
      PropGrid([
        ('说明', str(x['desc'])),
        if (str(x['category']).isNotEmpty) ('分类', str(x['category'])),
        if (str(x['timeout']).isNotEmpty) ('超时（秒）', str(x['timeout'])),
        ('风险', toolRiskText(x)),
        if (zip) ('运行方式', toolModes[mode]?.split('：').first ?? mode),
        if (mode != 'interactive' && str(x['output']).isNotEmpty) ('结果文件', str(x['output'])),
        if (zip) ...[
          ('入口程序', str(x['entry'])),
          if (str(x['help']).isNotEmpty) ('帮助指令', str(x['help'])),
          if (parsed == null && args.isNotEmpty) ('启动参数（每段用 | 隔开）', args.join(' | ')),
        ] else ...[
          ('接口地址', str(x['url'])),
          if (str(x['maxKb']).isNotEmpty) ('最多读取（KB）', str(x['maxKb'])),
        ],
        if (x['headers'] is Map) ('请求头', asMap(x['headers']).entries.map((e) => '${e.key}: ${e.value}').join('；')),
        if (str(x['sha256']).isNotEmpty) ('sha256', str(x['sha256'])),
      ]),
      if (parsed != null) ...[
        const SizedBox(height: 10),
        CommandPreview(toolPreview(str(x['entry']), parsed.fixed, [for (final k in parsed.how.keys) rowOf(k)])),
      ],
      if (problems.unused.isNotEmpty)
        warn('参数 ${problems.unused.join('、')} 在启动参数里没用到，AI 传了值也到不了程序，请点“修改”设置它怎么传给程序${parsed != null ? '（直接点“修改”再保存就会改好）' : ''}'),
      if (problems.joined.isNotEmpty) warn('启动参数“${problems.joined.join('”“')}”写在了一段里，程序会收到一整段、认不出来。点“修改”再保存，会自动分成两段'),
      if (zip && params.isEmpty && args.isEmpty)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('这个工具没有登记参数：AI 每次运行前先用帮助指令看程序自己打印的用法，再用 argv 把参数一项一项传进去。', style: TextStyle(fontSize: NT.fSmall, color: c.muted))),
      if (params.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('参数', style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.muted)),
        const SizedBox(height: 4),
        for (final k in params.keys)
          Builder(builder: (_) {
            final r = rowOf(k);
            final p = asMap(params[k]);
            return Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: c.line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(k, style: monoStyle(size: 13, color: c.text)),
                  if (r.required) Tag('必填', color: c.warnText),
                  if (parsed != null)
                    Text(howText(r), style: monoStyle(size: 12, color: r.how.isEmpty ? c.dangerText : c.muted))
                  else if (p['flag'] == true)
                    Tag('开关', color: c.muted),
                ]),
                if (r.desc.isNotEmpty) Text(r.desc, style: TextStyle(fontSize: NT.fSmall, color: c.text2)),
                if (r.def.isNotEmpty) Text('默认值：${r.def}', style: monoStyle(size: 12, color: c.muted)),
              ]),
            );
          }),
      ],
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (editable) AButton(label: '修改', icon: Icons.edit_outlined, small: true, onPressed: onEdit),
        if (zip) Builder(builder: (b) => AButton(label: '下载 zip', icon: Icons.download_outlined, small: true, onPressed: () => onDownload(b))),
        AButton(label: pinned ? '取消置顶' : '置顶', icon: Icons.push_pin_outlined, small: true, onPressed: onPin),
        if (editable) AButton(label: '删除', icon: Icons.delete_outline, small: true, kind: BtnKind.danger, onPressed: onDelete),
      ]),
    ]);
  }
}

/// “程序收到的命令行”
class CommandPreview extends StatelessWidget {
  const CommandPreview(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: c.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('程序收到的命令行（[ ] 里的没填就不加）', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.muted)),
        const SizedBox(height: 4),
        SelectableText(text, style: monoStyle(size: 12.5, color: c.text)),
      ]),
    );
  }
}

/// 新增、修改工具的表单
class ToolEditor extends StatefulWidget {
  const ToolEditor(
      {super.key,
      required this.form,
      required this.isNew,
      required this.items,
      required this.full,
      required this.upload,
      required this.onBusy,
      required this.onDone});
  final ToolForm form;
  final bool isNew;
  final List<ToolItem> items;

  /// 清单是不是完整的（不完整时看不到原来的请求头）
  final bool full;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> meta, PanelFile? file, void Function(int, int) onProgress) upload;
  final ValueChanged<bool> onBusy;

  /// 保存成功传工具名，取消传 null
  final ValueChanged<String?> onDone;
  @override
  State<ToolEditor> createState() => _ToolEditorState();
}

class _ToolEditorState extends State<ToolEditor> {
  ToolForm get f => widget.form;
  final _ctls = <TextEditingController>[];
  final _rowCtls = <ParamRow, Map<String, TextEditingController>>{};
  late final _name = _text(f.name, (v) => f.name = v);
  late final _title = _text(f.title, (v) => f.title = v);
  late final _category = _text(f.category, (v) => f.category = v);
  late final _desc = _text(f.desc, (v) => f.desc = v);
  late final _entry = _text(f.entry, (v) => f.entry = v);
  late final _url = _text(f.url, (v) => f.url = v);
  late final _timeout = _text(f.timeout, (v) => f.timeout = v);
  late final _maxKb = _text(f.maxKb, (v) => f.maxKb = v);
  late final _output = _text(f.output, (v) => f.output = v);
  late final _headers = _text(f.headers, (v) => f.headers = v);
  late final _fixed = _text(f.fixed, (v) => f.fixed = v);
  late final _args = _text(f.argsText, (v) => f.argsText = v);
  PanelFile? _file;
  bool _saving = false;
  String? _progress;
  double? _ratio;

  /// 输入框：改了就写回表单，预览跟着变
  TextEditingController _text(String init, void Function(String) set) {
    final c = TextEditingController(text: init);
    c.addListener(() {
      if (c.text == _last[c]) return;
      _last[c] = c.text;
      set(c.text);
      if (mounted) setState(() {});
    });
    _last[c] = init;
    _ctls.add(c);
    return c;
  }

  final _last = <TextEditingController, String>{};

  Map<String, TextEditingController> _rowFields(ParamRow r) => _rowCtls[r] ??= {
        'name': _text(r.name, (v) => r.name = v),
        'desc': _text(r.desc, (v) => r.desc = v),
        'opt': _text(r.opt, (v) => r.opt = v),
        'def': _text(r.def, (v) => r.def = v),
      };

  @override
  void dispose() {
    for (final c in _ctls) {
      c.dispose();
    }
    super.dispose();
  }

  void _setArgsText() => _args.text = f.argsText;
  void _syncRows() {
    for (final r in f.rows) {
      final m = _rowFields(r);
      if (m['opt']!.text != r.opt) m['opt']!.text = r.opt;
    }
  }

  Future<void> _pickZip() async {
    try {
      final files = await pickPanelFiles(extensions: const ['zip'], multiple: false);
      if (files.isEmpty) return;
      if (files.first.size > toolMaxZip) {
        if (mounted) await showAlert(context, '程序包不能超过 500MB');
        return;
      }
      setState(() => _file = files.first);
    } catch (_) {
      if (mounted) showToast(context, '没有选到文件');
    }
  }

  Future<void> _save() async {
    final built = buildToolMeta(f);
    if (built.error != null) return showAlert(context, built.error!);
    for (final q in built.confirms) {
      if (!await confirmDialog(context, title: '确认一下', message: q, ok: '仍然保存')) return;
      if (!mounted) return;
    }
    final meta = built.meta!;
    final name = str(meta['name']);
    final same = widget.items.where((x) => x['name'] == name).firstOrNull;
    if (same != null && same['canEdit'] == false) {
      return showAlert(context, '已经有一个叫“$name”的工具，是${toolOwnerWho[_owner(same)] ?? '管理员'}上传的，你不能覆盖它，请换一个名称');
    }
    if (widget.isNew && same != null && !await confirmDialog(context, title: '覆盖工具？', message: '已经有一个叫“$name”的工具了，上传会覆盖它。继续吗？', ok: '覆盖', destructive: true)) return;
    if (!mounted) return;
    if (f.zip && widget.isNew && _file == null) return showAlert(context, '新增 zip 工具要选择程序包');
    setState(() {
      _saving = true;
      _progress = _file == null ? null : '正在上传…';
      _ratio = _file == null ? null : 0;
    });
    widget.onBusy(true);
    Map<String, dynamic> r;
    try {
      r = await widget.upload(meta, f.zip ? _file : null, (sent, total) {
        if (!mounted) return;
        final pct = total == 0 ? 100 : (sent * 100 ~/ total);
        setState(() {
          _ratio = total == 0 ? 1 : sent / total;
          _progress = pct < 100 ? '正在上传 ${toolSize(sent)} / ${toolSize(total)}（$pct%）' : '已传完，等 SFU 校验保存…';
        });
      });
    } on ApiError catch (e) {
      widget.onBusy(false);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _progress = null;
      });
      return showAlert(context, e.message);
    }
    widget.onBusy(false);
    if (!mounted) return;
    showToast(context, '${r['replaced'] == true ? '已更新' : '已上传'}：$name');
    widget.onDone(name);
  }

  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final zip = f.zip;
    final cats = categoriesOf(widget.items.map((x) => str(x['category'])));
    Widget gap([double h = 10]) => SizedBox(height: h);
    Widget hint(String t, {Color? color}) => Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(t, style: TextStyle(fontSize: NT.fCaption, color: color ?? c.muted)));
    // 下拉框：不填 = SFU 的默认；原来存了表单不认识的值（比如以后新加的）也列出来，保存时不丢
    List<(String, String)> choices(Map<String, String> map, String cur, String def) => [
          ('', '不填（默认${map[def]!.split('：').first}）'),
          for (final e in map.entries) (e.key, e.value),
          if (cur.isNotEmpty && !map.containsKey(cur)) (cur, cur),
        ];
    return LayoutBuilder(builder: (ctx, box) {
      final two = box.maxWidth >= 640;
      Widget pair(Widget a, Widget b) => two
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, gap(), b]);
      return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
        Text(widget.isNew ? '新增工具' : '修改工具：${f.name}', style: TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600, color: c.text)),
        gap(12),
        pair(
          ChoiceField<String>(
              label: '类型',
              value: f.type,
              enabled: widget.isNew && !_saving,
              options: const [('zip', 'zip（程序包，在电脑上运行）'), ('http_get', 'http_get（调用一个网络接口）')],
              onChanged: (v) => setState(() {
                    f.type = v;
                    f.raw = false;
                  })),
          widget.isNew
              ? AField(controller: _name, label: '名称（小写字母、数字、_、-，最长 64 位）', hint: '例如 disk-check', mono: true, maxLength: 64, autofocus: true)
              : AField(controller: _title, label: '标题（可不填）', hint: '例如 硬盘检查', maxLength: 100),
        ),
        if (widget.isNew) ...[gap(), AField(controller: _title, label: '标题（可不填）', hint: '例如 硬盘检查', maxLength: 100)],
        gap(),
        CategoryField(controller: _category, all: cats),
        gap(),
        AField(controller: _desc, label: '说明（AI 靠它判断什么时候用、结果怎么看）', hint: '例如 检查硬盘健康状态和坏道，把结果打印出来', minLines: 2, maxLines: 5),
        gap(),
        if (zip) ...[
          pair(
            AField(controller: _entry, label: '入口程序（.exe / .bat / .cmd / .ps1，zip 里的相对路径）', hint: '例如 bin/check.exe', mono: true),
            ChoiceField<String>(
                label: '帮助指令（推荐登记：AI 先运行它看用法，再用参数运行）',
                value: f.help,
                options: [('', '不填（运行时默认用 --help）'), for (final h in toolHelps) (h, h)],
                onChanged: (v) => setState(() => f.help = v)),
          ),
          gap(),
          pair(
            AField(controller: _timeout, label: '超时（秒，最多 $toolMaxTimeout，可不填）', hint: '例如 120'),
            ChoiceField<String>(label: '运行方式', value: f.mode, options: choices(toolModes, f.mode, 'silent'), onChanged: (v) => setState(() => f.mode = v)),
          ),
          gap(),
          ChoiceField<String>(label: '风险', value: f.risk, options: choices(toolRisks, f.risk, 'danger'), onChanged: (v) => setState(() => f.risk = v)),
          if (f.mode != 'interactive') ...[
            gap(),
            AField(controller: _output, label: '结果文件（可不填：不填就把程序打印出来的内容当结果；填了就读这个文件）', hint: r'例如 {TMP}\report.txt', mono: true),
            hint('可以用 {TMP}（这次运行的临时目录，运行完会删）、{TOOLDIR}（工具解压后的目录）、{参数名}。请用这两个目录开头，别写相对路径'),
          ],
          gap(),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            AButton(label: _file == null ? '选择程序包（zip）' : '换一个程序包', icon: Icons.folder_zip_outlined, small: true, onPressed: _saving ? null : _pickZip),
            Text(_file == null ? (widget.isNew ? '不超过 500MB' : '不选就不换包') : '${_file!.name}（${toolSize(_file!.size)}）', style: TextStyle(fontSize: NT.fSmall, color: c.muted)),
          ]),
        ] else ...[
          AField(controller: _url, label: '接口地址（参数用 {参数名} 写进地址里）', hint: 'https://api.example.com/bar/{barId}?f={fields}', mono: true),
          gap(),
          pair(
            AField(controller: _timeout, label: '超时（秒，最多 $toolMaxTimeout，可不填）'),
            AField(controller: _maxKb, label: '最多读取（KB，可不填）'),
          ),
          gap(),
          ChoiceField<String>(label: '风险', value: f.risk, options: choices(toolRisks, f.risk, 'safe'), onChanged: (v) => setState(() => f.risk = v)),
          gap(),
          AField(controller: _headers, label: '请求头（每行一个，格式“名称: 值”，可不填）', hint: 'X-Api-Key: ……', mono: true, minLines: 2, maxLines: 5),
          if (!widget.full && !widget.isNew) hint('清单里看不到原来的请求头，原来有的话要重新填，不然保存后会丢', color: c.warnText),
        ],
        gap(14),
        Text('参数（AI 运行工具时填的值）', style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: c.text2)),
        for (final r in f.rows) _paramCard(r, zip),
        Align(
            alignment: Alignment.centerLeft,
            child: AButton(
                label: '添加参数',
                icon: Icons.add,
                kind: BtnKind.text,
                small: true,
                onPressed: () => setState(() => f.rows.add(ParamRow())))),
        if (zip)
          hint(f.raw
              ? '自己写启动参数时，“怎么传给程序”只用来区分开关参数（开关没有值，打开时才加 ?参数名: 后面那段）'
              : '参数表可以一个都不填：程序有自带用法的话，登记“帮助指令”，AI 运行时先看用法再用参数运行；填了的参数，可选项没值时会自动不加'),
        if (zip) ...[
          gap(),
          if (f.raw) ...[
            AField(controller: _args, label: '启动参数（自己写）', hint: '--name\n{name}', mono: true, minLines: 3, maxLines: 8),
            hint('每行一个参数（程序收到的一段）。可以用：{参数名}（换成参数的值）、?参数名:文字（参数有值或开关打开时才加这段）、{TOOLDIR}（工具解压后的目录）、{TMP}（临时目录）'),
            Align(
              alignment: Alignment.centerLeft,
              child: AButton(
                  label: '改回用参数表设置',
                  kind: BtnKind.text,
                  small: true,
                  onPressed: () {
                    if (!f.toSimple()) {
                      showAlert(context, '现在写的启动参数没法用参数表表示，只能继续自己写');
                      return;
                    }
                    setState(() {
                      _fixed.text = f.fixed;
                      _syncRows();
                    });
                  }),
            ),
          ] else ...[
            AField(controller: _fixed, label: '固定启动参数（每次都加在最前面，可不填；用空格分开，带空格的用引号括起来）', hint: '例如 /silent', mono: true),
            gap(8),
            CommandPreview(f.preview),
            Align(
              alignment: Alignment.centerLeft,
              child: AButton(
                  label: '自己写启动参数（高级）',
                  kind: BtnKind.text,
                  small: true,
                  onPressed: () => setState(() {
                        f.toRaw();
                        _setArgsText();
                      })),
            ),
          ],
        ],
        if (_progress != null) ...[
          gap(),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: _ratio, minHeight: 6, color: NT.accent, backgroundColor: c.fill2)),
          hint(_progress!),
        ],
        gap(14),
        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          AButton(label: '取消', kind: BtnKind.text, onPressed: _saving ? null : () => widget.onDone(null)),
          AButton(
              label: _saving ? '保存中…' : (widget.isNew ? '上传' : '保存'),
              icon: Icons.upload_outlined,
              kind: BtnKind.primary,
              onPressed: _saving ? null : _save),
        ]),
      ]);
    });
  }

  /// 参数表的一行（窄的时候也放得下：每个参数一张小卡片）
  Widget _paramCard(ParamRow r, bool zip) {
    final c = NetbarColors(context);
    final m = _rowFields(r);
    final showHow = zip;
    final showOpt = zip && !f.raw && r.how != 'pos';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(NT.rSm), border: Border.all(color: c.line)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 150, child: AField(controller: m['name']!, label: '参数名', hint: 'name', mono: true, maxLength: 40)),
            SizedBox(width: 220, child: AField(controller: m['desc']!, label: '说明（给 AI 看）', hint: '名字')),
            if (showHow)
              SizedBox(
                  width: 170,
                  child: ChoiceField<String>(
                      label: '怎么传给程序',
                      value: r.how,
                      options: [for (final e in toolHows.entries) (e.key, e.value)],
                      onChanged: (v) => setState(() => r.how = v))),
            if (showOpt) SizedBox(width: 140, child: AField(controller: m['opt']!, label: '选项名', hint: r.how == 'flag' ? '--verbose' : '--name', mono: true)),
            if (r.how != 'flag') ...[
              SizedBox(width: 160, child: AField(controller: m['def']!, label: '默认值', hint: '可不填', mono: true)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox.adaptive(value: r.required, onChanged: (v) => setState(() => r.required = v == true)),
                Text('必填', style: TextStyle(fontSize: NT.fSmall, color: c.text2)),
              ]),
            ],
          ]),
        ),
        AIconButton(icon: Icons.close, tooltip: '删除这个参数', onPressed: () => setState(() => f.rows.remove(r))),
      ]),
    );
  }
}
