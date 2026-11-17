// 测试用的假后台：模拟网吧经营管家的接口（含实时返回、操作确认）
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netbar_ops/src/group.dart';

/// 假的多人会话实时连接：记下发出去的消息，push 模拟后台推来的消息
class FakeRoomSocket {
  final _in = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  void push(Map<String, dynamic> m) {
    if (!closed) _in.add(jsonEncode(m));
  }

  void close() {
    if (closed) return;
    closed = true;
    _in.close();
  }

  RoomSocket get socket => (stream: _in.stream, send: (String s) => sent.add(Map<String, dynamic>.from(jsonDecode(s) as Map)), close: close);
}

class FakeBackend {
  /// 多人会话的实时连接都换成假的（不连网络）
  FakeBackend() {
    GroupRoom.defaultConnect = (url) {
      final s = FakeRoomSocket();
      roomSockets.add(s);
      // 主人连上：回 hello 和当前成员
      scheduleMicrotask(() {
        s.push({
          'type': 'hello',
          'me': {'id': 'owner', 'name': ownerName, 'owner': true}
        });
        s.push(roomInfo());
      });
      return s.socket;
    };
  }

  // ---------- 多人会话 ----------
  final roomSockets = <FakeRoomSocket>[];
  String ownerName = '房主';
  Map<String, dynamic>? invite;

  /// 被邀请进来的人：{id, name, online}
  final guests = <Map<String, dynamic>>[];
  final roomSays = <Map<String, dynamic>>[];

  /// /api/sessions/get 返回的对话（不设就是空的）
  Map<String, dynamic>? sessionData;

  /// 下一次 /api/chat 回 409（别人刚叫 AI 干上活）
  bool otherRunning = false;

  Map<String, dynamic> roomInfo() => {
        'type': 'presence',
        'ownerName': ownerName,
        'ownerOnline': true,
        'invite': invite,
        'members': [
          {'id': 'owner', 'name': ownerName, 'owner': true, 'online': true},
          for (final g in guests) {...g, 'joinedAt': 0},
        ],
      };

  /// 推给所有连着的页面
  void pushRoom(Map<String, dynamic> m) {
    for (final s in roomSockets) {
      s.push(m);
    }
  }

  void pushPresence() => pushRoom(roomInfo());

  /// 群里记一条事件（chat、auto_task、auto_task_status），接在最后一轮后面
  void pushRoomEvent(String e, Map<String, dynamic> d) => pushRoom({
        'type': 'event',
        'ev': {'e': e, 'd': d, 't': 0, 'turn': 't$_turn'}
      });

  final List<String> calls = [];
  final List<Map<String, dynamic>> chatBodies = [];
  final List<Map<String, dynamic>> events = [];
  Completer<bool>? approval;
  int _turn = 0;
  String? sessionId;

  /// 下一次提问时要求确认一个写操作
  bool askApproval = false;

  final kb = [
    {
      'id': 'k1',
      'type': 'experience',
      'title': '桌面图标被隐藏的排查方法',
      'content': '## 原因\n“显示桌面图标”被关了。\n\n**解决办法**：右键桌面→查看→显示桌面图标',
      'source': 'ai',
      'machine': '测试组-测试网吧-01',
      'netbarGroup': '测试组',
      'netbarName': '测试网吧',
      'netbarSeat': '01',
      'netbarIp': '',
      'updatedAt': '2026-10-23T08:00:00Z',
      'stats': {'calls': 2, 'effective': 1, 'ratio': .5}
    },
    {'id': 'k2', 'type': 'background', 'title': '网维工具箱 说明文档', 'content': '工具箱放在 D:\\tools', 'source': 'manual', 'machine': '', 'updatedAt': '2026-10-22T08:00:00Z'},
  ];
  final skills = [
    {'id': 's1', 'name': '客户机开机慢标准检查', 'description': '客户机开机或进系统很慢时', 'content': '1. 查启动项', 'enabled': true, 'useCount': 3, 'updatedAt': '2026-10-23T08:00:00Z'},
  ];
  final memories = <Map<String, dynamic>>[
    {'id': 'm1', 'scope': 'machine', 'content': '这台机器键盘 F 键坏了', 'source': 'ai', 'updatedAt': '2026-10-23T08:00:00Z'},
  ];

  /// 收到的 /api/start 请求；expireNext：下一个请求回“连接已过期”
  final startBodies = <Map<String, dynamic>>[];
  bool expireNext = false;

  http.Client client() => MockClient.streaming((req, body) async {
        final path = req.url.path;
        calls.add(path);
        final text = await body.bytesToString();
        final b = text.isEmpty || path == '/api/upload' ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(text) as Map);
        if (path == '/api/start') {
          startBodies.add(b);
          final env = '${b['env']}';
          final key = env == 'toolbox' ? '${b['mcp']}' : 'netbar://$env/2/${b['branch']}';
          return _json({'token': 'conn-${startBodies.length}', 'key': key, 'env': env, if (env != 'toolbox') 'barId': '2'});
        }
        // 模拟后台重启：下一个请求回“连接已过期”
        if (expireNext && path != '/api/harnesses') {
          expireNext = false;
          return _json({'error': '连接已过期，请刷新页面重新连接。'}, 400);
        }
        if (path == '/api/chat') {
          if (otherRunning) {
            otherRunning = false;
            return _json({'error': '这个对话还有任务在执行（可能在别的窗口里），请等它结束后再继续。'}, 409);
          }
          return _chat(b);
        }
        if (path.startsWith('/api/room/')) return _room(path, b);
        if (path == '/api/sessions/get' && sessionData != null) return _json(sessionData!);
        if (path == '/api/upload') {
          return _json({
            'file': {'group': 'g', 'id': 'u${calls.length}', 'name': Uri.decodeComponent(req.headers['X-File-Name'] ?? ''), 'size': text.length, 'kind': 'text'}
          });
        }
        return _json(switch (path) {
          '/api/kb/list' => {'items': kb},
          '/api/kb/suggest' => {
              'items': [
                for (final x in kb) {'id': x['id'], 'type': x['type'], 'title': x['title'], 'snippet': '摘要'},
                for (final s in skills) {'id': s['id'], 'type': 'skill', 'title': s['name'], 'snippet': s['description']},
              ]
            },
          '/api/skills/list' => {'items': skills},
          '/api/memory/list' => {'items': memories},
          '/api/sessions' => {
              'sessions': [
                {'id': 'old-session-1', 'title': '游戏菜单打不开', 'updatedAt': '2026-10-22T10:00:00Z', 'rounds': 3, 'shared': true}
              ]
            },
          '/api/share/status' => {'share': null},
          '/api/harnesses' => {
              'items': [
                {'id': 'claude', 'name': 'Claude', 'desc': 'Anthropic Claude Code', 'available': true},
                {'id': 'codex', 'name': 'Codex', 'desc': 'OpenAI Codex', 'available': true},
                {'id': 'dsh', 'name': 'DeepSeek', 'desc': 'DeepSeek Harness', 'available': false},
              ],
              'default': 'claude'
            },
          '/api/approve' => () {
              approval?.complete(b['allow'] == true);
              return {'ok': true};
            }(),
          _ => {'ok': true},
        });
      });

  http.StreamedResponse _room(String path, Map<String, dynamic> b) {
    switch (path) {
      case '/api/room/say':
        roomSays.add(b);
        pushRoomEvent('chat', {
          'from': {'id': 'owner', 'name': ownerName},
          'text': b['text'],
          if ((b['mentions'] as List).isNotEmpty) 'mentions': b['mentions'],
        });
        return _json({'ok': true});
      case '/api/room/invite':
        invite = b['action'] == 'close'
            ? null
            : {'code': 'abcdef0123456789abcdef01', 'createdAt': 0, 'expiresAt': b['expires'] == 'never' ? 0 : DateTime(2026, 11, 24, 10).millisecondsSinceEpoch};
        if (b['action'] == 'close') guests.clear();
        pushPresence();
        return _json(roomInfo());
      case '/api/room/kick':
        guests.removeWhere((g) => g['id'] == b['memberId']);
        pushPresence();
        return _json(roomInfo());
      case '/api/room/rename':
        ownerName = '${b['name']}'.trim();
        pushPresence();
        return _json({'name': ownerName});
      case '/api/room/cancel':
        pushRoomEvent('auto_task_status', {'id': b['id'], 'status': 'cancelled', 'by': ownerName});
        return _json({'ok': true});
    }
    return _json(roomInfo());
  }

  http.StreamedResponse _json(Map<String, dynamic> d, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(d))), status, headers: {'content-type': 'application/json'});

  /// 模拟一轮对话的实时返回
  Future<http.StreamedResponse> _chat(Map<String, dynamic> b) async {
    chatBodies.add(b);
    final ctl = StreamController<List<int>>();
    void send(String e, Map<String, dynamic> d) => ctl.add(utf8.encode('event: $e\ndata: ${jsonEncode(d)}\n\n'));
    final turn = 't${++_turn}';
    final first = sessionId == null;
    sessionId ??= 'session-1';
    () async {
      send('start', {'taskId': 'task-$turn', 'turn': turn, 'parent': b['parentTurn']});
      send('user', {
        'text': b['diagnose'] == true ? '🔍 自动检查当前桌面' : b['message'],
        'kind': b['diagnose'] == true ? 'diagnose' : 'chat',
        'turn': turn,
        'parent': b['parentTurn'],
        if ((b['kbRefs'] as List?)?.isNotEmpty == true)
          'kbRefs': [
            {'id': 'k1', 'type': 'experience', 'title': '桌面图标被隐藏的排查方法'}
          ]
      });
      send('session', {'sessionId': sessionId, 'title': first ? b['message'] : '', 'mcpStatus': 'connected', 'autoApprove': false});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (askApproval) {
        send('tool_use', {
          'id': 'tool1',
          'name': 'kill_process',
          'input': {'name': 'notepad.exe'},
          'write': true
        });
        send('approval', {
          'id': 'tool1',
          'tool': 'kill_process',
          'input': {'name': 'notepad.exe'},
          'risks': <String>[]
        });
        approval = Completer<bool>();
        final allow = await approval!.future;
        send('approval_done', {'id': 'tool1', 'allow': allow, 'reason': allow ? '' : '用户在页面上拒绝了这个操作。'});
        send('tool_result', {'id': 'tool1', 'isError': !allow, 'content': allow ? '已结束进程' : '拒绝'});
      }
      // 先边生成边推送一段，最后再给完整的一段
      send('text_delta', {'text': '## 检查结果\n这台机器'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      send('text', {'text': '## 检查结果\n这台机器 **CPU 占用正常**，`notepad.exe` 已处理。\n\n- 第一项：显卡驱动正常\n- 第二项：网络正常\n\n| 项目 | 状态 |\n|---|---|\n| 显卡 | 正常 |\n| 网络 | 正常 |'});
      send('kb_used', {'id': 'k1', 'title': '桌面图标被隐藏的排查方法', 'effective': true});
      send('done', {'sessionId': sessionId, 'isError': false, 'turns': 3, 'cost': 0.0123, 'harness': b['harness'] ?? 'claude'});
      await ctl.close();
    }();
    return http.StreamedResponse(ctl.stream, 200, headers: {'content-type': 'text/event-stream'});
  }
}
