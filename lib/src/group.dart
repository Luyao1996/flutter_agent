// 多人会话（群聊）：邀请链接、群成员、@、实时推送（和网页版 public/group.js 一致）
// 组件这边永远是“主人”（用这台电脑的连接打开对话的人）；被邀请的人用网页链接加入，组件不用做“受邀加入”
// 规则：有别人在线时是“群聊模式”——打字发的话默认交给 AI；只 @ 了群里的人（或 @所有人）、又没叫 AI 时，才只是发给人看。
// 只有主人一个人时和以前一样，每句话都发给 AI。语音通话不在这里（保持原样）
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'controller.dart';
import 'models.dart';

/// 群里 AI 的名字
const aiName = '龙龙';

/// 主人在群里的默认名字（后台没给名字时用）
const defaultOwnerName = '房主';

/// 群聊模式下输入框的提示
const groupPlaceholder = '直接说就是问 AI；要跟群里的人说话，先 @ 他的名字';

// 唤醒词：墩墩龙、龙龙、龙妹任意位置都算；“助手”是常用词，只在开头才算；也可以 @AI
final _wakeAny = RegExp(r'墩墩龙|龙龙|龙妹|@AI(?![A-Za-z])', caseSensitive: false);
final _wakeHead = RegExp(r'^[\s@，,。.!！?？~～、]*助手');

/// 这句话是不是在叫 AI
bool callsAi(String text) => _wakeAny.hasMatch(text) || _wakeHead.hasMatch(text);

/// 邀请链接的有效期
const inviteExpires = {'1d': '1 天', '7d': '7 天', 'never': '永久'};

/// 根据群聊自动发起的任务的各个状态
const autoTaskStatusText = {'pending': '马上开始，不需要的话点“取消”', 'queued': '排在当前工作后面，轮到了自动开始', 'running': '正在处理', 'done': '已处理完', 'cancelled': '已取消', 'failed': '没能开始'};

class RoomMember {
  RoomMember({required this.id, required this.name, this.owner = false, this.online = false, this.inCall = false});
  final String id, name;
  final bool owner, online, inCall;
  factory RoomMember.fromJson(Map<String, dynamic> j) =>
      RoomMember(id: str(j['id']), name: str(j['name']), owner: j['owner'] == true, online: j['online'] == true, inCall: j['inCall'] == true);
}

class RoomInvite {
  RoomInvite({required this.code, required this.expiresAt});
  final String code;

  /// 过期时间（毫秒）；0 = 永久
  final int expiresAt;
  factory RoomInvite.fromJson(Map<String, dynamic> j) => RoomInvite(code: str(j['code']), expiresAt: (j['expiresAt'] as num?)?.toInt() ?? 0);
}

/// 房间的状态（/api/room/state、实时推送的 presence）
class RoomInfo {
  RoomInfo({required this.ownerName, required this.ownerOnline, required this.invite, required this.members});
  final String ownerName;
  final bool ownerOnline;
  final RoomInvite? invite;
  final List<RoomMember> members;
  factory RoomInfo.fromJson(Map<String, dynamic> j) => RoomInfo(
    ownerName: str(j['ownerName']).isEmpty ? defaultOwnerName : str(j['ownerName']),
    ownerOnline: j['ownerOnline'] == true,
    invite: j['invite'] is Map ? RoomInvite.fromJson(asMap(j['invite'])) : null,
    members: asList(j['members']).map((m) => RoomMember.fromJson(asMap(m))).toList(),
  );
}

/// 实时连接（测试时换成假的）
typedef RoomSocket = ({Stream<dynamic> stream, void Function(String) send, void Function() close});
typedef RoomConnector = RoomSocket Function(Uri url);

RoomSocket _wsConnect(Uri url) {
  final ch = WebSocketChannel.connect(url);
  // 连不上时 stream 会报错并结束（由那边重连），这里只是不让它变成没人接的错误
  ch.ready.catchError((_) {});
  return (stream: ch.stream, send: ch.sink.add, close: () => ch.sink.close());
}

String _randomHex(int bytes) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// 一个对话的多人房间：跟着当前打开的对话走
class GroupRoom extends ChangeNotifier {
  GroupRoom(this.chat);
  final ChatController chat;
  NetbarApi get api => chat.api;

  /// 这个组件的编号：别人叫 AI 干活时，后台按它认出是不是自己发起的
  final String clientId = _randomHex(16);

  /// 建实时连接用的函数；测试时换成假的（defaultConnect 换掉后新建的房间都用它）
  static RoomConnector defaultConnect = _wsConnect;
  RoomConnector connect = defaultConnect;

  RoomInfo? info;
  String? sid;
  RoomSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _timer;
  int _retry = 0;
  bool _expired = false, _disposed = false;

  /// 取消失败（任务其实已经结束）时，本地当作“已处理完”
  final Map<String, String> localAutoStatus = {};

  bool get connected => _ws != null;

  /// 群聊模式：有别人在线
  bool get active => info?.members.any((m) => !m.owner && m.online) ?? false;

  /// 顶部显示“几人在线”：有别人加入过或开了邀请
  bool get showBadge => info != null && (info!.members.length > 1 || info!.invite != null);
  int get onlineCount => info?.members.where((m) => m.online).length ?? 0;

  /// 消息里 @ 了群里的人（不算自己）或 @所有人
  bool mentionsPeople(String text) => text.contains('@所有人') || (info?.members.any((m) => !m.owner && m.name.isNotEmpty && text.contains('@${m.name}')) ?? false);

  /// 打字发的话：默认交给 AI；只 @ 了人、没叫 AI 的才只发群里
  bool textToPeople(String text) => mentionsPeople(text) && !callsAi(text);

  String inviteUrl(String code) => '${chat.config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/join/$code';

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    chat.refresh();
  }

  // ---------- 实时连接 ----------
  /// 换了对话：实时连接也跟着换（null = 没有打开对话）
  void follow(String? sessionId) {
    if (_disposed) return;
    if (sessionId == sid && (_ws != null || _timer != null)) return;
    _disconnect();
    sid = sessionId;
    info = null;
    _retry = 0;
    localAutoStatus.clear();
    _notify();
    if (sessionId != null) _connect();
  }

  void _disconnect() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        ws.close();
      } catch (_) {}
    }
  }

  void _connect() {
    _timer = null;
    final id = sid;
    if (_disposed || id == null || !api.isOpen) return;
    final url = Uri.parse('${chat.config.baseUrl.replaceAll(RegExp(r'/+$'), '').replaceFirst(RegExp(r'^http'), 'ws')}/api/room');
    RoomSocket ws;
    try {
      ws = connect(url);
    } catch (_) {
      return _scheduleRetry(id);
    }
    _ws = ws;
    _expired = false;
    _sub = ws.stream.listen(
      (raw) {
        Map<String, dynamic> m;
        try {
          m = asMap(jsonDecode(str(raw)));
        } catch (_) {
          return;
        }
        if (_ws == ws) _onMessage(m);
      },
      onError: (_) {},
      onDone: () => _onClosed(ws, id),
      cancelOnError: false,
    );
    // 主人用这台电脑的连接验证
    try {
      ws.send(jsonEncode({'type': 'hello', 'sessionId': id, 'mcpUrl': api.key, 'token': api.conn, 'barId': chat.barKey}));
    } catch (_) {}
  }

  void _onClosed(RoomSocket ws, String id) {
    if (_ws != ws) return;
    _ws = null;
    _sub = null;
    _notify();
    if (_disposed || sid != id) return;
    // 连接编号过期了（后台重启过）：重新连上电脑再来
    if (_expired) {
      api.open().then((_) {
        if (sid == id && _ws == null && !_disposed) _connect();
      }, onError: (_) => _scheduleRetry(id));
      return;
    }
    _scheduleRetry(id);
  }

  void _scheduleRetry(String id) {
    if (_disposed || sid != id) return;
    final wait = Duration(milliseconds: min(10000, 1000 * (1 << min(_retry++, 4))));
    _timer = Timer(wait, () {
      if (sid == id && _ws == null) _connect();
    });
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (str(m['type'])) {
      case 'hello':
        _retry = 0;
      case 'presence':
        info = RoomInfo.fromJson(m);
        _notify();
      case 'event':
        final ev = ChatEvent.fromJson(asMap(m['ev']));
        if (chat.sessionId == sid) chat.onRoomEvent(ev);
      // 别人叫 AI 干活了：连上去一起看（自己发起的不用）
      case 'task':
        if (str(m['clientId']) != clientId && chat.sessionId == sid) chat.onRoomTask();
      // 群里有人改了目标：跟着更新
      case 'goal':
        if (chat.sessionId == sid) chat.applyGoal(m['goal']);
      // 主人被踢不会发生；对话被删除时提示一下
      case 'kicked':
        chat.toast(str(m['reason']));
      case 'error':
        _expired = m['expired'] == true;
    }
  }

  // ---------- 发言、自动任务 ----------
  /// 群里说话（不交给 AI）：@ 了谁就提醒谁
  Future<void> say(String text) async {
    final mentions = <String>[
      for (final m in info?.members ?? const <RoomMember>[])
        if (!m.owner && m.name.isNotEmpty && text.contains('@${m.name}')) m.id,
      if (text.contains('@所有人')) 'all',
    ];
    await api.post('/api/room/say', {'sessionId': sid ?? chat.sessionId, 'text': text, 'mentions': mentions});
  }

  /// 取消根据群聊自动发起的任务：群里谁都能点
  Future<void> cancelAutoTask(String id) async {
    try {
      await api.post('/api/room/cancel', {'sessionId': chat.sessionId, 'id': id});
    } on ApiError catch (e) {
      chat.toast(e.message);
      localAutoStatus[id] = 'done';
      _notify();
    }
  }

  /// 一个自动任务现在的状态（看最新的 auto_task_status）
  ({String status, String by, String error}) autoTaskStatus(String id, List<ChatEvent> events) {
    var st = (status: 'pending', by: '', error: '');
    for (final e in events) {
      if (e.e == 'auto_task_status' && str(e.d['id']) == id) st = (status: str(e.d['status']), by: str(e.d['by']), error: str(e.d['error']));
    }
    final local = localAutoStatus[id];
    if (local != null && const ['pending', 'queued', 'running'].contains(st.status)) st = (status: local, by: '', error: '');
    return st;
  }

  // ---------- 邀请、成员（分享窗口里的“邀请加入”） ----------
  /// 重新取一次房间状态
  Future<void> refresh() async {
    final r = await api.post('/api/room/state', {'sessionId': chat.sessionId});
    info = RoomInfo.fromJson(r);
    _notify();
  }

  /// 生成（重新生成）邀请链接，expires：1d / 7d / never
  Future<void> createInvite(String expires) async {
    info = RoomInfo.fromJson(await api.post('/api/room/invite', {'sessionId': chat.sessionId, 'action': 'create', 'expires': expires}));
    _notify();
  }

  /// 关闭邀请：链接失效，已经进来的人都会被移出
  Future<void> closeInvite() async {
    info = RoomInfo.fromJson(await api.post('/api/room/invite', {'sessionId': chat.sessionId, 'action': 'close'}));
    _notify();
  }

  Future<void> kick(String memberId) async {
    info = RoomInfo.fromJson(await api.post('/api/room/kick', {'sessionId': chat.sessionId, 'memberId': memberId}));
    _notify();
  }

  /// 改自己在群里的名字，返回改好的名字（重名时后台会加编号）
  Future<String> rename(String name) async => str((await api.post('/api/room/rename', {'sessionId': chat.sessionId, 'name': name}))['name']);

  // ---------- @ 弹出的候选 ----------
  /// 群成员：AI 排第一，然后“所有人”和群里的人；只有自己一个人时不显示
  List<({RefItem item, String snippet})> mentionItems(String q) {
    final i = info;
    if (i == null || i.members.length < 2) return const [];
    q = q.toLowerCase();
    final list = <({RefItem item, String snippet})>[
      (item: RefItem(id: 'ai', type: 'person', title: aiName), snippet: '叫 AI 处理问题'),
      (item: RefItem(id: 'all', type: 'person', title: '所有人'), snippet: '提醒群里所有人'),
      for (final m in i.members)
        if (!m.owner) (item: RefItem(id: m.id, type: 'person', title: m.name), snippet: m.online ? '在线' : '不在线'),
    ];
    return list.where((x) => q.isEmpty || x.item.title.toLowerCase().contains(q) || (x.item.id == 'ai' && 'ai'.contains(q))).toList();
  }

  /// 有人 @ 我（主人）：提示一下
  void notifyAt(String name) {
    chat.toast('$name @了你');
    SystemSound.play(SystemSoundType.alert).catchError((_) {});
    HapticFeedback.mediumImpact().catchError((_) {});
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnect();
    super.dispose();
  }
}
