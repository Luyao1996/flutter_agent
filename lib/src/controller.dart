// 聊天的全部逻辑（和网页版 ops.js 一致）：发送、实时返回、排队、分支、确认、附件、@ 推荐、恢复对话
// 界面只负责显示和把用户操作交给这里；三个平台共用这一份逻辑
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'config.dart';
import 'models.dart';

/// 输入区里待发送的附件
class PendingFile {
  PendingFile({required this.name, required this.size, required this.kind, this.pasted = false});
  final String key = _randomId(8);
  final String name, kind;
  int size;
  final bool pasted;
  String status = 'uploading'; // uploading | done | error
  double progress = 0;
  String error = '';
  AttachmentInfo? info;
  Uint8List? preview; // 图片缩略图
  String? text; // 粘贴的长文本
  final Completer<void> cancel = Completer<void>();
}

/// 排队中的消息（AI 处理中发送的）
class QueuedMessage {
  QueuedMessage(this.opts);
  final SendOptions opts;
}

/// 一次发送的内容
class SendOptions {
  SendOptions(
      {this.text = '',
      this.diagnose = false,
      this.summarize = false,
      this.parentTurn,
      this.hasParent = false,
      this.attachments = const [],
      this.quote = '',
      this.kbRefs = const [],
      this.skillId,
      this.skillName});
  final String text;
  final bool diagnose, summarize;

  /// hasParent 为 true 时按 parentTurn 接（null = 从头开始）；否则接在当前版本的最后
  final String? parentTurn;
  final bool hasParent;
  final List<AttachmentInfo> attachments;
  final String quote;
  final List<RefItem> kbRefs;
  final String? skillId, skillName;

  SendOptions withParent(String? p) => SendOptions(
      text: text,
      diagnose: diagnose,
      summarize: summarize,
      parentTurn: p,
      hasParent: true,
      attachments: attachments,
      quote: quote,
      kbRefs: kbRefs,
      skillId: skillId,
      skillName: skillName);
}

/// 不属于对话记录、只在界面上显示的提示（例如“请在下方描述问题”）
class LocalNote {
  LocalNote(this.kind, this.text);
  final String kind; // ai | sys | error
  final String text;
}

/// 平台能力：附件压缩等（由界面层提供，便于测试时替换）
typedef ImageShrinker = Future<({Uint8List bytes, String name})> Function(Uint8List bytes, String name);

String _randomId(int bytes) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _uuid() {
  final h = _randomId(16);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class ChatController extends ChangeNotifier {
  ChatController(this.config, {NetbarApi? api, this.shrinkImage}) : api = api ?? NetbarApi(config) {
    input.addListener(_onInputChanged);
  }

  final NetbarOpsConfig config;
  final NetbarApi api;
  final ImageShrinker? shrinkImage;

  // ---------- 提示：界面层注册，用来弹出小提示和确认框 ----------
  void Function(String message)? onToast;

  /// 重新生成、编辑重发前，被替换的内容里执行过写操作时调用；返回是否继续
  Future<bool> Function(List<String> executedOps)? onConfirmReplace;
  void toast(String m) => onToast?.call(m);

  /// 界面状态变了（例如朗读开始、结束）时让界面刷新
  void refresh() => notifyListeners();

  /// 组件关掉以后不再刷新界面
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _cancelStream() {
    final c = _streamCancel;
    if (c != null && !c.isCompleted) c.complete();
    _streamCancel = null;
  }

  // ---------- 对话状态 ----------
  String? sessionId;
  String title = '';
  String sessionInfo = '新对话';
  String mcpStatus = 'unknown'; // unknown | connected | failed
  bool autoApprove = false;
  bool busy = false;
  String? taskId;
  String? liveTurn;
  bool thinking = false;
  String thinkingText = 'AI 正在处理…';
  bool showStartChoices = false;
  bool startPicked = false;
  bool historyNote = false;
  final List<ChatEvent> events = [];
  Map<String, String> selected = {};
  final Map<String, List<LocalNote>> turnNotes = {};
  final List<LocalNote> notes = [];

  /// 本轮自动检查得到的问题选项，以及哪些选项已经点过
  final Set<String> lockedOptions = {};
  String? editingTurn;
  String? speakingTurn;
  TurnTree? _tree;
  List<DiagOption>? _diagOptions;
  int _kbSavedCount = 0;
  bool _stopNext = false;
  Completer<void>? _streamCancel;
  bool _disposed = false;
  Timer? _diagTimer, _draftTimer;
  /// 调用过的远程机器工具（Codex、DeepSeek 开始时不报连接状态，远程工具调用成功就算已连接）
  final Set<String> _remoteCalls = {};

  /// AI 正在生成、还没写完的这段回复（只用来显示，写完后由完整的 text 事件替换）
  String? streamingText;

  /// 一次给出整段回复时（Codex、DeepSeek），用打字机效果显示的那段：轮次编号:事件序号
  String? typewriterKey;
  DateTime typewriterAt = DateTime(0);

  // ---------- 切换 AI（Claude、Codex、DeepSeek） ----------
  List<Harness> harnesses = [];
  String harnessId = '';
  Harness? get harness => harnesses.where((h) => h.id == harnessId).firstOrNull;
  final DateTime _openedAt = DateTime.now();
  static const diagnoseDelay = Duration(seconds: 3);

  TurnTree get tree => _tree ??= TurnTree.build(events);
  List<Turn> get path => tree.path(selected);
  void _changed() {
    _tree = null;
    notifyListeners();
  }

  // ---------- 输入区 ----------
  final TextEditingController input = TextEditingController();
  final List<PendingFile> files = [];
  String quote = '';
  final List<RefItem> refs = [];
  RefItem? skill;
  String placeholder = '描述遇到的问题，例如：游戏打不开、没有声音、上不了网…';
  String draftGroup = _uuid();
  String get uploadGroup => sessionId ?? draftGroup;

  // ---------- 排队 ----------
  final List<QueuedMessage> queue = [];
  bool queuePaused = false;

  bool get hasContent => input.text.trim().isNotEmpty || files.isNotEmpty;

  /// 打开组件：有上次的对话就恢复（还在执行的任务会重新连上），没有就让用户选怎么开始
  Future<void> start() async {
    if (!config.isValid) {
      notes.add(LocalNote('error', '缺少远程机器的连接信息，请传入完整的 MCP 地址和令牌。'));
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    harnessId = prefs.getString('netbar_ops.harness') ?? '';
    loadHarnesses();
    final draft = prefs.getString(_key('draft'));
    if (draft != null && input.text.isEmpty) input.text = draft;
    final saved = prefs.getString(_key('session'));
    if (saved != null && await openSession(saved, restoring: true)) return;
    _showStart();
  }

  String _key(String k) => 'netbar_ops.$k.${config.mcpUrl.trim()}';
  Future<void> _remember(String k, String? v) async {
    final prefs = await SharedPreferences.getInstance();
    if (v == null || v.isEmpty) {
      await prefs.remove(_key(k));
    } else {
      await prefs.setString(_key(k), v);
    }
  }

  /// 可以用的 AI 列表；记住的那个用不了时换成服务器默认的
  Future<void> loadHarnesses() async {
    try {
      final r = await api.get('/api/harnesses');
      harnesses = asList(r['items']).map((x) => Harness.fromJson(asMap(x))).toList();
      if (!harnesses.any((h) => h.id == harnessId && h.available)) harnessId = str(r['default']);
      notifyListeners();
    } catch (_) {}
  }

  /// 换一个 AI：下一条消息开始生效（同一个对话中途也能换）
  Future<void> setHarness(String id) async {
    if (id == harnessId) return;
    harnessId = id;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString('netbar_ops.harness', id);
    toast('已切换到 ${harness?.name ?? id}，下一条消息开始生效');
  }

  void _showStart() {
    showStartChoices = true;
    startPicked = false;
    notifyListeners();
  }

  /// 新对话的两个选项：自动检查这台电脑 / 自己描述问题
  void pickStart(bool diagnose) {
    if (startPicked) return;
    if (diagnose && busy) return toast('任务执行中，等结束后再开始检查');
    startPicked = true;
    if (!diagnose) {
      notes.add(LocalNote('ai', '好的，请在下方输入框描述你遇到的问题，越具体越好。'));
      notifyListeners();
      return;
    }
    // 远程画面刚连上时截图容易失败：刚打开就点的，稍等几秒
    final wait = diagnoseDelay - DateTime.now().difference(_openedAt);
    if (wait <= Duration.zero) {
      send(SendOptions(diagnose: true));
      return;
    }
    _setBusy(true);
    _setThinking(true, '稍等几秒，远程画面连上后马上开始检查…');
    _diagTimer = Timer(wait, () {
      if (_disposed) return;
      _setBusy(false);
      send(SendOptions(diagnose: true));
    });
  }

  // ---------- 发送 ----------
  /// 输入框里的内容；有问题时返回错误提示
  ({SendOptions? opts, String? error}) composerContent() {
    if (files.any((f) => f.status == 'uploading')) return (opts: null, error: '附件还在上传，请稍等');
    if (files.any((f) => f.status == 'error')) return (opts: null, error: '有附件没有上传成功，请先删掉');
    final sk = skill;
    final text = input.text.trim().isNotEmpty ? input.text.trim() : (sk != null ? '使用技能：${sk.title}' : '');
    return (
      opts: SendOptions(text: text, attachments: files.map((f) => f.info!).toList(), quote: quote, kbRefs: List.of(refs), skillId: sk?.id, skillName: sk?.title),
      error: null,
    );
  }

  /// 发送后清空输入区，返回恢复用的函数（发送失败时放回去）
  VoidCallback clearComposer() {
    final saved = (text: input.text, files: List.of(files), quote: quote, refs: List.of(refs), skill: skill);
    input.text = '';
    files.clear();
    quote = '';
    refs.clear();
    skill = null;
    _remember('draft', null);
    notifyListeners();
    return () {
      if (input.text.isEmpty) input.text = saved.text;
      files
        ..clear()
        ..addAll(saved.files);
      quote = saved.quote;
      refs
        ..clear()
        ..addAll(saved.refs);
      skill = saved.skill;
      notifyListeners();
    };
  }

  /// 发送输入框里的内容（AI 处理中就排队）
  void sendComposer() {
    final c = composerContent();
    if (c.error != null) return toast(c.error!);
    final o = c.opts!;
    if (o.text.isEmpty && o.attachments.isEmpty) return;
    if (busy) {
      clearComposer();
      return enqueue(o);
    }
    final restore = clearComposer();
    send(o, onFail: restore);
  }

  /// 发出一轮：opts.hasParent 为 false 时接在当前版本的最后
  Future<void> send(SendOptions opts, {VoidCallback? onFail}) async {
    if (busy || _disposed) return;
    showStartChoices = false;
    final parentTurn = opts.hasParent ? opts.parentTurn : _currentLeaf();
    _diagOptions = null;
    _kbSavedCount = 0;
    _setBusy(true);
    _setThinking(
        true,
        opts.diagnose
            ? 'AI 正在检查桌面…'
            : opts.summarize
                ? 'AI 正在总结经验…'
                : 'AI 正在处理…');
    var started = false;
    _streamCancel = Completer<void>();
    try {
      final body = {
        'message': opts.text,
        'diagnose': opts.diagnose,
        'summarize': opts.summarize,
        if (opts.hasParent || sessionId != null) 'parentTurn': parentTurn,
        'attachments': opts.attachments.map((a) => a.ref).toList(),
        'quote': opts.quote,
        'kbRefs': opts.kbRefs.map((r) => r.id).toList(),
        if (opts.skillId != null) 'skillId': opts.skillId,
        'machine': config.machineName,
        'netbar': config.netbar,
        'barId': config.barKey,
        'sessionId': sessionId,
        'isClient': config.isClient,
        if (harnessId.isNotEmpty) 'harness': harnessId,
      };
      await for (final (e, d) in api.stream('/api/chat', body, cancel: _streamCancel!.future)) {
        started = true;
        _onLiveEvent(e, d);
      }
    } on ApiError catch (e) {
      if (!started) onFail?.call();
      _failLive(e.message);
    } catch (e) {
      if (!started) onFail?.call();
      _failLive('出错了：$e');
    } finally {
      _endRun(opts.diagnose, opts.summarize);
    }
  }

  /// 这一轮中途出错（连接断了等）：在这一轮里显示原因，并算作已结束（反馈、重新生成按钮照常出现）
  void _failLive(String message) {
    final t = liveTurn == null ? null : tree.turns[liveTurn];
    if (t == null || t.done) {
      notes.add(LocalNote('error', message));
      return;
    }
    final ev = ChatEvent('error', {'error': message, 'local': true}, t.id);
    events.add(ev);
    t.events.add(ev);
    t.done = true;
  }

  String? _currentLeaf() {
    final p = path;
    return sessionId != null && p.isNotEmpty ? p.last.id : null;
  }

  /// 打开时这个对话还有任务在执行：重新连上，先补上这一轮已有的内容，再接着实时显示
  Future<void> _attachRunning() async {
    var diagnose = false, summarize = false, reload = false;
    _diagOptions = null;
    _kbSavedCount = 0;
    _setBusy(true);
    _setThinking(true);
    _streamCancel = Completer<void>();
    try {
      await for (final (e, d) in api.stream('/api/chat/attach', {'sessionId': sessionId}, cancel: _streamCancel!.future)) {
        if (e == 'user') {
          diagnose = d['kind'] == 'diagnose';
          summarize = d['kind'] == 'summarize';
        }
        _onLiveEvent(e, d);
      }
    } on ApiError catch (e) {
      // 任务刚好在这期间结束了：重新打开一次，把这一轮补上
      if (e.status == 409) {
        reload = true;
      } else {
        _failLive(e.message);
      }
    } finally {
      _endRun(diagnose, summarize);
      if (reload && sessionId != null && !_disposed) scheduleMicrotask(() => openSession(sessionId!, restoring: true));
    }
  }

  void _endRun(bool diagnose, bool summarize) {
    _setThinking(false);
    _setBusy(false);
    taskId = null;
    _stopNext = false;
    streamingText = null;
    final t = liveTurn == null ? null : tree.turns[liveTurn];
    void note(LocalNote n) => t == null ? notes.add(n) : (turnNotes[t.id] ??= []).add(n);
    // 自动检查没找出问题（或检查失败）：请用户自己描述
    if (diagnose && (_diagOptions == null || _diagOptions!.isEmpty)) {
      note(LocalNote('ai', '没有从桌面上发现明显的问题。请在下方描述你遇到的情况，我来帮你排查。'));
      placeholder = '请描述遇到的问题，例如：游戏打不开、没有声音、上不了网…';
    }
    if (summarize && _kbSavedCount == 0) note(LocalNote('sys', '这次没有记录新的经验'));
    liveTurn = null;
    _changed();
    // 接着处理排队的消息
    if (!_disposed) scheduleMicrotask(runQueue);
  }

  void _onLiveEvent(String e, Map<String, dynamic> d) {
    if (e == 'start') {
      taskId = d['taskId'] as String?;
      liveTurn = d['turn'] as String?;
      if (_stopNext) {
        _stopNext = false;
        stop();
      }
      return;
    }
    if (e == 'session') return _onSession(d);
    // 正在生成的文字只用来显示，不算进对话记录；还没写完的选项代码块先不显示
    if (e == 'text_delta') {
      final text = str(d['text']).replaceFirst(RegExp(r'```options[\s\S]*$'), '').trim();
      if (text.isEmpty) return;
      streamingText = text;
      _setThinking(true, 'AI 正在回复…');
      return notifyListeners();
    }
    final ev = ChatEvent(e, d, liveTurn);
    if (e == 'user') {
      // 新对话：之前没连上的尝试不再显示
      if (sessionId == null) {
        events.clear();
        turnNotes.clear();
      }
      notes.clear();
      showStartChoices = false;
      events.add(ev);
      selected[(d['parent'] as String?) ?? 'root'] = str(d['turn']);
      return _changed();
    }
    // 先取这一轮再加事件：先加的话，树重建时已经包含这条，再加一次就重复了
    final t = tree.turns[liveTurn];
    events.add(ev);
    t?.events.add(ev);
    switch (e) {
      case 'text':
        final o = splitOptions(str(d['text'])).options;
        if (o != null) _diagOptions = o;
        // 一次给出整段的（没有经过“边生成边显示”）：用打字机效果快速显示
        if (streamingText == null && t != null) {
          typewriterKey = '${t.id}:${t.events.length - 1}';
          typewriterAt = DateTime.now();
        }
        streamingText = null;
        _setThinking(true);
      case 'tool_use':
        // 远程机器的工具名不带 mcp__ 前缀（知识库工具带）
        if (!str(d['name']).startsWith('mcp__')) _remoteCalls.add(str(d['id']));
        _setThinking(true, 'AI 正在调用工具…');
      case 'auto_approved':
        _setThinking(true, 'AI 正在调用工具…');
      case 'tool_result':
        if (d['isError'] != true && _remoteCalls.contains(str(d['id']))) mcpStatus = 'connected';
        _setThinking(true);
      case 'approval':
        _setThinking(false);
      case 'approval_done':
        _setThinking(true, d['allow'] == true ? 'AI 正在调用工具…' : 'AI 正在处理…');
      case 'kb_saved':
        _kbSavedCount++;
      case 'auto_mode':
        autoApprove = true;
      case 'done':
      case 'error':
        _setThinking(false);
    }
    notifyListeners();
  }

  void _onSession(Map<String, dynamic> d) {
    sessionId = d['sessionId'] as String?;
    _remember('session', sessionId);
    if (str(d['title']).isNotEmpty) title = str(d['title']);
    autoApprove = d['autoApprove'] == true;
    sessionInfo = '对话进行中';
    // Codex、DeepSeek 开始时不报告连接状态（unknown）：连不上会在调用工具时报错
    if (d['mcpStatus'] == 'connected') {
      mcpStatus = 'connected';
    } else if (d['mcpStatus'] != 'unknown') {
      mcpStatus = 'failed';
      notes.add(LocalNote('error', '远程机器没有连上，请确认链接是否正确、机器是否在线。'));
    }
    notifyListeners();
  }

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

  void _setThinking(bool on, [String text = 'AI 正在处理…']) {
    thinking = on;
    thinkingText = text;
  }

  /// 停止当前这一轮（排队中有消息时先暂停，等用户点“立即处理”）
  void stopByUser() {
    if (queue.isNotEmpty) queuePaused = true;
    stop();
    notifyListeners();
  }

  void stop() {
    if (taskId != null) api.post('/api/stop', {'taskId': taskId}).catch_();
  }

  // ---------- 排队 ----------
  void enqueue(SendOptions o) {
    queue.add(QueuedMessage(o));
    notifyListeners();
    toast(queuePaused ? '已加入排队（排队已暂停，点“立即处理”开始）' : 'AI 正在处理，这条消息已排队，这一轮结束后接着处理');
  }

  void runQueue() {
    if (_disposed) return;
    if (busy || queuePaused || queue.isEmpty) return notifyListeners();
    final item = queue.removeAt(0);
    notifyListeners();
    send(item.opts);
  }

  /// 立即处理：排到最前面，停掉正在执行的这一轮
  void processNow(QueuedMessage item) {
    queue
      ..remove(item)
      ..insert(0, item);
    queuePaused = false;
    if (!busy) return runQueue();
    notifyListeners();
    if (taskId != null) {
      stop();
    } else {
      _stopNext = true;
    }
  }

  void removeQueued(QueuedMessage item) {
    queue.remove(item);
    notifyListeners();
  }

  // ---------- 操作确认 ----------
  Future<void> approve(String approvalId, {required bool allow, bool always = false}) async {
    try {
      await api.post('/api/approve', {'taskId': taskId, 'approvalId': approvalId, 'allow': allow, 'always': always});
    } on ApiError catch (e) {
      toast(e.message);
    }
  }

  Future<void> autoApproveOff() async {
    if (sessionId != null) await api.post('/api/auto-approve/off', {'sessionId': sessionId}).catch_();
    autoApprove = false;
    notes.add(LocalNote('sys', '已关闭“始终允许”，之后的改动操作会重新询问你'));
    notifyListeners();
  }

  // ---------- 版本切换、重新生成、编辑 ----------
  /// 旧版本的记录（编号 L 开头）只有第一轮能重新生成、编辑
  bool canBranch(Turn t) => t.parent == null || !t.parent!.startsWith('L');

  void selectBranch(String? parent, String id) {
    if (busy) return toast('任务执行中，等结束后再切换版本');
    selected[parent ?? 'root'] = id;
    _changed();
    if (sessionId != null) api.post('/api/sessions/select', {'sessionId': sessionId, 'parent': parent, 'turn': id}).catch_();
  }

  void stepBranch(Turn t, int delta) {
    final ids = tree.siblings(t);
    final i = ids.indexOf(t.id) + delta;
    if (i >= 0 && i < ids.length) selectBranch(t.parent, ids[i]);
  }

  /// 被替换的这段（这一轮和后面各轮）里已经在机器上执行过的改动操作
  List<String> executedWrites(Turn t) {
    final p = path;
    final ops = <String>[];
    final start = max(0, p.indexWhere((x) => x.id == t.id));
    for (final x in p.sublist(start)) {
      final ok = {for (final e in x.events.where((e) => e.e == 'tool_result')) str(e.d['id']): e.d['isError'] != true};
      final allowed = x.events.where((e) => (e.e == 'approval_done' && e.d['allow'] == true) || e.e == 'auto_approved').map((e) => str(e.d['id'])).toSet();
      for (final e in x.events) {
        if (e.e == 'tool_use' && (e.d['write'] == true || allowed.contains(str(e.d['id']))) && ok[str(e.d['id'])] == true) ops.add(str(e.d['name']));
      }
    }
    return ops;
  }

  Future<bool> _confirmReplace(Turn t) async {
    final ops = executedWrites(t);
    if (ops.isEmpty) return true;
    return await onConfirmReplace?.call(ops) ?? false;
  }

  SendOptions _reuse(Turn t, String text) => SendOptions(
        text: text,
        attachments: t.attachments,
        quote: t.quote,
        kbRefs: t.kbRefs,
        skillId: t.skill == null ? null : str(t.skill!['id']),
        skillName: t.skill == null ? null : str(t.skill!['name']),
      ).withParent(t.parent);

  Future<void> regenerate(Turn t) async {
    if (busy) return toast('任务执行中，等结束后再重新生成');
    if (!await _confirmReplace(t)) return;
    if (t.kind == 'diagnose') return send(SendOptions(diagnose: true).withParent(null));
    send(_reuse(t, t.noText ? '' : t.text));
  }

  void beginEdit(Turn t) {
    if (busy) return toast('任务执行中，等结束后再编辑');
    editingTurn = t.id;
    notifyListeners();
  }

  void cancelEdit() {
    editingTurn = null;
    notifyListeners();
  }

  Future<void> submitEdit(Turn t, String text) async {
    text = text.trim();
    if (text.isEmpty && t.attachments.isEmpty) return toast('内容不能为空');
    if (busy) return toast('任务执行中，等结束后再发送');
    if (!await _confirmReplace(t)) return;
    editingTurn = null;
    send(_reuse(t, text));
  }

  /// 输入框为空时按 ↑：编辑当前版本里最后一条自己发的消息
  bool editLast() {
    final t = path.where((x) => x.kind == 'chat').lastOrNull;
    if (t == null || !canBranch(t) || busy) return false;
    beginEdit(t);
    return true;
  }

  // ---------- 点赞点踩 ----------
  Future<void> sendFeedback(Turn t, String? value, [String reason = '']) async {
    if (sessionId == null) return;
    try {
      await api.post('/api/feedback', {'sessionId': sessionId, 'turn': t.id, 'value': value, 'reason': reason});
    } on ApiError catch (e) {
      return toast(e.message);
    }
    events.add(ChatEvent('feedback', {'value': value, 'reason': reason}, t.id));
    _changed();
    toast(value == 'up'
        ? '感谢反馈'
        : value == 'down'
            ? '已记下，我们会改进'
            : '已取消');
  }

  // ---------- 记忆撤销 ----------
  Future<void> undoMemory(String memoryId, String? turn) async {
    try {
      await api.post('/api/memory/delete', {'id': memoryId, 'barId': config.barKey, 'sessionId': sessionId, 'turn': turn});
    } on ApiError catch (e) {
      return toast(e.message);
    }
    events.add(ChatEvent('memory_undone', {'id': memoryId}, turn));
    _changed();
  }

  // ---------- 自动检查后的问题选项 ----------
  void pickOption(String key, DiagOption? o) {
    if (busy || lockedOptions.contains(key)) return;
    lockedOptions.add(key);
    if (o == null) {
      notes.add(LocalNote('ai', '好的，请在下方输入框描述你遇到的问题。'));
      notifyListeners();
      return;
    }
    send(SendOptions(text: '请帮我解决这个问题：${o.title}${o.detail.isEmpty ? '' : '（${o.detail}）'}'));
  }

  void summarize() => send(SendOptions(summarize: true));

  // ---------- 对话：新建、打开、改名、删除 ----------
  void _reset() {
    if (autoApprove && sessionId != null) api.post('/api/auto-approve/off', {'sessionId': sessionId}).catch_();
    _cancelStream();
    autoApprove = false;
    streamingText = null;
    _remoteCalls.clear();
    sessionId = null;
    _remember('session', null);
    title = '';
    events.clear();
    selected = {};
    turnNotes.clear();
    notes.clear();
    lockedOptions.clear();
    editingTurn = null;
    historyNote = false;
    if (queue.isNotEmpty) toast('已清空排队中的 ${queue.length} 条消息');
    queue.clear();
    queuePaused = false;
    draftGroup = _uuid();
    _changed();
  }

  void newChat() {
    if (busy) return toast('请先等待或停止当前任务');
    _reset();
    sessionInfo = '新对话';
    _showStart();
  }

  Future<bool> openSession(String id, {bool restoring = false}) async {
    if (busy && !restoring) {
      toast('请先等待或停止当前任务');
      return false;
    }
    Map<String, dynamic> data;
    try {
      data = await api.post('/api/sessions/get', {'sessionId': id});
    } on ApiError catch (e) {
      if (!restoring) toast(e.message);
      return false;
    }
    // 等待期间用户已经发出了新消息（或组件已关闭）：不能再切换，否则会打断刚发出的这一轮
    if (_disposed || busy) return false;
    _reset();
    showStartChoices = false;
    sessionId = id;
    _remember('session', id);
    final session = asMap(data['session']);
    final running = data['running'] == true;
    final runningTurn = data['runningTurn'];
    // 还在执行的那一轮先不显示，等重新连上任务后实时补上
    events.addAll(asList(data['events']).map((e) => ChatEvent.fromJson(asMap(e))).where((e) => !running || e.turn != runningTurn));
    selected = asMap(session['selected']).map((k, v) => MapEntry(k, str(v)));
    title = str(session['title']);
    sessionInfo = restoring ? '对话进行中' : '历史对话 · ${fmtTime(DateTime.tryParse(str(session['createdAt']))?.toLocal())} 开始';
    historyNote = !running && !restoring;
    _changed();
    if (running) _attachRunning();
    return true;
  }

  Future<List<SessionSummary>> listSessions() async => asList((await api.post('/api/sessions'))['sessions']).map((s) => SessionSummary.fromJson(asMap(s))).toList();

  Future<String?> renameSession(String id, String newTitle) async {
    try {
      final r = await api.post('/api/sessions/rename', {'sessionId': id, 'title': newTitle});
      if (id == sessionId) title = str(r['title']);
      notifyListeners();
      return str(r['title']);
    } on ApiError catch (e) {
      toast(e.message);
      return null;
    }
  }

  Future<bool> deleteSession(String id) async {
    if (id == sessionId && busy) {
      toast('请先等待或停止当前任务');
      return false;
    }
    try {
      await api.post('/api/sessions/delete', {'sessionId': id, 'isDebug': true});
    } on ApiError catch (e) {
      toast(e.message);
      return false;
    }
    if (id == sessionId) {
      _reset();
      sessionInfo = '新对话';
      notes.add(LocalNote('sys', '已删除这个对话，可以在下方描述新的问题'));
      notifyListeners();
    }
    return true;
  }

  // ---------- 附件 ----------
  static const _mb = 1024 * 1024;
  static const limits = {'count': 10, 'total': 30 * _mb, 'image': 5 * _mb, 'pdf': 20 * _mb, 'office': 20 * _mb, 'text': 5 * _mb};
  static const kindNames = {'image': '图片', 'pdf': 'PDF', 'office': 'Office 文件', 'text': '文本文件'};

  /// 粘贴超过这么多字就变成文本附件
  static const longPaste = 2000;

  static String guessKind(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'\.(png|jpe?g|webp|gif)$').hasMatch(n)) return 'image';
    if (n.endsWith('.pdf')) return 'pdf';
    if (RegExp(r'\.(docx|xlsx|pptx)$').hasMatch(n)) return 'office';
    return 'text';
  }

  static String _stamp() {
    final d = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.hour)}${p(d.minute)}${p(d.second)}';
  }

  /// 加入附件（选文件、拍照、粘贴、拖拽进来的都走这里）
  void addFile(Uint8List bytes, String name, {bool pasted = false, bool screenshot = false}) {
    if (files.length >= limits['count']!) return toast('一条消息最多带 ${limits['count']} 个附件');
    if (screenshot || name.isEmpty) name = '截图-${_stamp()}.png';
    final f = PendingFile(name: name, size: bytes.length, kind: pasted ? 'text' : guessKind(name), pasted: pasted);
    files.add(f);
    notifyListeners();
    _prepareAndUpload(f, bytes);
  }

  /// 选的文件太大，没读进来：直接显示成失败的附件卡片
  void addOversized(String name, int size) {
    if (files.length >= limits['count']!) return toast('一条消息最多带 ${limits['count']} 个附件');
    final f = PendingFile(name: name, size: size, kind: guessKind(name))
      ..status = 'error'
      ..error = '太大了（${fmtSize(size)}），单个文件不能超过 ${fmtSize(limits['pdf']!)}';
    files.add(f);
    notifyListeners();
  }

  /// 粘贴的长文字变成文本附件
  void addPastedText(String text) {
    addFile(Uint8List.fromList(utf8.encode(text)), '粘贴的文本-${_stamp()}.txt', pasted: true);
    toast('粘贴的文字超过 $longPaste 字，已变成一个文本附件');
  }

  Future<void> _prepareAndUpload(PendingFile f, Uint8List bytes) async {
    var name = f.name;
    try {
      if (f.kind == 'image' && shrinkImage != null && !name.toLowerCase().endsWith('.gif')) {
        final r = await shrinkImage!(bytes, name);
        bytes = r.bytes;
        name = r.name;
      }
      if (f.kind == 'image') f.preview = bytes;
      if (f.pasted) f.text = utf8.decode(bytes, allowMalformed: true);
      f.size = bytes.length;
      final max = limits[f.kind]!;
      if (bytes.length > max) throw ApiError('太大了（${fmtSize(bytes.length)}），${kindNames[f.kind]}不能超过 ${fmtSize(max)}');
      final total = files.where((x) => x.status != 'error').fold<int>(0, (n, x) => n + x.size);
      if (total > limits['total']!) throw ApiError('附件总大小不能超过 ${fmtSize(limits['total']!)}');
      var last = DateTime(0);
      f.info = await api.upload(bytes, name, uploadGroup, pasted: f.pasted, cancel: f.cancel.future, onProgress: (p) {
        f.progress = p;
        // 进度最多每 100 毫秒刷新一次界面
        final now = DateTime.now();
        if (p >= 1 || now.difference(last).inMilliseconds >= 100) {
          last = now;
          notifyListeners();
        }
      });
      f.status = 'done';
    } on ApiError catch (e) {
      if (!files.contains(f)) return;
      f.status = 'error';
      f.error = e.message;
    } catch (_) {
      if (!files.contains(f)) return;
      f.status = 'error';
      f.error = f.kind == 'image' ? '图片打不开，可能已损坏' : '文件读取失败';
    }
    notifyListeners();
  }

  void removeFile(PendingFile f) {
    if (!f.cancel.isCompleted) f.cancel.complete();
    files.remove(f);
    if (f.info != null) api.post('/api/uploads/delete', {'group': f.info!.group, 'id': f.info!.id}).catch_();
    notifyListeners();
  }

  // ---------- 引用、@ 推荐、技能 ----------
  static const maxQuote = 4000;
  void setQuote(String text) {
    text = text.trim();
    if (text.isEmpty) return;
    if (text.length > maxQuote) toast('引用的文字太长，只保留前 $maxQuote 字');
    quote = text.length > maxQuote ? text.substring(0, maxQuote) : text;
    notifyListeners();
  }

  void clearQuote() {
    quote = '';
    notifyListeners();
  }

  void removeRef(RefItem r) {
    refs.remove(r);
    notifyListeners();
  }

  void clearSkill() {
    skill = null;
    notifyListeners();
  }

  /// 手动运行技能（“技能”菜单）：输入框里的附件、引用、@ 推荐也一起带上；AI 正在处理时先排队
  void runSkill(SkillItem x) {
    final c = composerContent();
    if (c.error != null) return toast(c.error!);
    final extra = input.text.trim();
    final restore = clearComposer();
    final o = c.opts!;
    final opts =
        SendOptions(text: '使用技能：${x.name}${extra.isNotEmpty ? '\n$extra' : ''}', attachments: o.attachments, quote: o.quote, kbRefs: o.kbRefs, skillId: x.id, skillName: x.name);
    if (busy) return enqueue(opts);
    send(opts, onFail: restore);
  }

  // ---------- 输入框里打 @ ----------
  static const maxRefs = 8;
  bool mentionOpen = false;
  List<RefItem> mentionItems = [];
  List<String> mentionSnippets = [];
  int mentionIndex = 0;
  String mentionQuery = '';
  int _mentionStart = -1;
  int _mentionSeq = 0;
  Timer? _mentionTimer;
  String _lastText = '';

  void _onInputChanged() {
    if (input.text != _lastText) {
      _lastText = input.text;
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 500), () => _remember('draft', _lastText));
    }
    _checkMention();
  }

  void _checkMention() {
    final sel = input.selection;
    if (!sel.isValid || !sel.isCollapsed) return closeMention();
    final before = input.text.substring(0, sel.baseOffset.clamp(0, input.text.length));
    final m = RegExp(r'(^|\s)@([^\s@]{0,30})$').firstMatch(before);
    if (m == null) return closeMention();
    final q = m.group(2)!;
    _mentionStart = before.length - q.length - 1;
    if (mentionOpen && q == mentionQuery) return;
    mentionQuery = q;
    _mentionTimer?.cancel();
    _mentionTimer = Timer(const Duration(milliseconds: 120), _loadMention);
  }

  Future<void> _loadMention() async {
    final seq = ++_mentionSeq;
    List<dynamic> items;
    try {
      items = asList((await api.post('/api/kb/suggest', {'q': mentionQuery}))['items']);
    } catch (_) {
      return closeMention();
    }
    if (seq != _mentionSeq) return;
    const order = ['experience', 'background', 'skill'];
    final list = items.map(asMap).where((x) => !refs.any((r) => r.id == x['id']) && skill?.id != x['id']).toList()
      ..sort((a, b) => order.indexOf(str(a['type'])) - order.indexOf(str(b['type'])));
    mentionItems = list.map(RefItem.fromJson).toList();
    mentionSnippets = list.map((x) => str(x['snippet'])).toList();
    mentionIndex = 0;
    mentionOpen = true;
    notifyListeners();
  }

  void closeMention() {
    _mentionTimer?.cancel();
    _mentionSeq++;
    if (!mentionOpen) return;
    mentionOpen = false;
    notifyListeners();
  }

  void moveMention(int delta) {
    if (mentionItems.isEmpty) return;
    mentionIndex = (mentionIndex + delta) % mentionItems.length;
    if (mentionIndex < 0) mentionIndex += mentionItems.length;
    notifyListeners();
  }

  /// 选中一个候选：输入框里的“@关键词”去掉，变成上方的标签
  void pickMention([int? index]) {
    final i = index ?? mentionIndex;
    if (i < 0 || i >= mentionItems.length) return;
    final x = mentionItems[i];
    final end = input.selection.baseOffset.clamp(0, input.text.length);
    final start = _mentionStart.clamp(0, end);
    input.value = TextEditingValue(text: input.text.replaceRange(start, end, ''), selection: TextSelection.collapsed(offset: start));
    closeMention();
    if (x.isSkill) {
      if (skill != null && skill!.id != x.id) toast('一条消息只能运行一个技能，已换成“${x.title}”');
      skill = x;
    } else if (refs.length >= maxRefs) {
      toast('一条消息最多推荐 $maxRefs 条');
    } else {
      refs.add(x);
    }
    notifyListeners();
  }

  /// “@”按钮：在光标处插入 @ 并弹出候选
  void insertAt() {
    final sel = input.selection.isValid ? input.selection : TextSelection.collapsed(offset: input.text.length);
    final before = input.text.substring(0, sel.start);
    final ins = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' @' : '@';
    input.value = TextEditingValue(text: input.text.replaceRange(sel.start, sel.end, ins), selection: TextSelection.collapsed(offset: sel.start + ins.length));
  }

  /// 语音识别出的一句话插到光标处
  void insertText(String text) {
    final sel = input.selection.isValid ? input.selection : TextSelection.collapsed(offset: input.text.length);
    input.value = TextEditingValue(text: input.text.replaceRange(sel.start, sel.end, text), selection: TextSelection.collapsed(offset: sel.start + text.length));
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelStream();
    queue.clear();
    _diagTimer?.cancel();
    _draftTimer?.cancel();
    _mentionTimer?.cancel();
    input.dispose();
    api.close();
    super.dispose();
  }
}

extension _IgnoreErrors<T> on Future<T> {
  /// 不关心结果的请求：出错也不打扰用户
  Future<void> catch_() => then((_) {}, onError: (_) {});
}
