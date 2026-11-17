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

  /// 下一次提问时先推思考过程和一次工具调用（思考 → 调用工具 → 结果）
  bool withThinking = false;

  /// 下一次提问时 Claude 额度用完、这一轮没做完（retry=false），自动换成 Codex
  bool quotaFail = false;

  /// 目标模式：后台存的目标（/api/goal 改它；带 goal 的提问设它；每轮结束 turnsUsed+1）
  Map<String, dynamic>? goal;
  final goalActions = <Map<String, dynamic>>[];

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

  /// /api/start 额外给回的字段（who、offline、borrowedBar…）；/api/reconnect 给回的离线原因
  Map<String, dynamic> startExtra = {};
  String reconnectOffline = '';

  /// 一轮开始时 session 事件报的连接状态（offline 时带 offline 原因）
  String mcpStatus = 'connected';
  String offlineReason = '';

  /// 历史对话列表里另加的（例如管理员看到的别人的对话）；/api/sessions/get 给回的内容
  List<Map<String, dynamic>> extraSessions = [];
  Map<String, dynamic>? sessionGet;

  http.Client client() => MockClient.streaming((req, body) async {
        final path = req.url.path;
        calls.add(path);
        final text = await body.bytesToString();
        final b = text.isEmpty || path == '/api/upload' ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(text) as Map);
        if (path == '/api/start') {
          startBodies.add(b);
          final env = '${b['env']}';
          final key = env == 'pass'
              ? 'netbar://pass/${Uri.encodeComponent('${b['mcp']}')}'
              : env == 'toolbox' && b['mcp'] != null
                  ? '${b['mcp']}'
                  : 'netbar://$env/2/${b['branch']}';
          return _json({'token': 'conn-${startBodies.length}', 'key': key, 'env': env, if (env != 'toolbox') 'barId': env == 'pass' ? 'room-abcd' : '2', ...startExtra});
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
                {'id': 'old-session-1', 'title': '游戏菜单打不开', 'updatedAt': '2026-10-22T10:00:00Z', 'rounds': 3, 'shared': true},
                ...extraSessions,
              ]
            },
          '/api/sessions/get' when sessionGet != null => sessionGet!,
          '/api/reconnect' => {'offline': reconnectOffline},
          '/api/share/status' => {'share': null},
          '/api/harnesses' => {
              'items': [
                {
                  'id': 'claude',
                  'name': 'Claude',
                  'desc': 'Anthropic Claude Code',
                  'available': true,
                  'model': 'claude-opus-5-5',
                  'models': [
                    {'id': 'claude-opus-5-5', 'name': 'claude-opus-5-5', 'efforts': ['low', 'medium', 'high', 'xhigh'], 'defaultEffort': 'medium'},
                    {'id': 'claude-sonnet-5', 'name': 'claude-sonnet-5', 'efforts': ['low', 'medium', 'high', 'xhigh'], 'defaultEffort': 'medium'},
                  ]
                },
                {
                  'id': 'codex',
                  'name': 'Codex',
                  'desc': 'OpenAI Codex',
                  'available': true,
                  'model': 'gpt-6.1-sol',
                  'models': [
                    {
                      'id': 'gpt-6.1-sol',
                      'name': 'GPT-6.1 Sol',
                      'efforts': ['low', 'medium', 'high'],
                      'effortDescs': {'low': '快速回答', 'high': '想得更深'},
                      'defaultEffort': 'medium'
                    },
                    {'id': 'gpt-5.1-codex', 'name': 'GPT-5.1 Codex', 'efforts': <String>[], 'defaultEffort': ''},
                  ]
                },
                {'id': 'dsh', 'name': 'DeepSeek', 'desc': 'DeepSeek Harness', 'available': false, 'model': '', 'models': <Object>[]},
              ],
              'default': 'claude'
            },
          '/api/goal' => () {
              goalActions.add(b);
              final a = b['action'];
              if (a == 'clear') {
                goal = null;
              } else if (goal != null) {
                if (a == 'pause') goal = {...goal!, 'status': 'paused', 'reason': '你暂停了目标'};
                if (a == 'resume') goal = {...goal!, 'status': 'active', 'reason': ''};
                if (a == 'extend') goal = {...goal!, 'status': 'active', 'reason': '', 'maxTurns': (goal!['maxTurns'] as int) + 10};
                if (a == 'edit') goal = {...goal!, 'objective': b['objective']};
              }
              return {'goal': goal, 'running': false};
            }(),
          '/api/sessions/get' => {
              'session': {'id': b['sessionId'], 'title': '旧对话', 'createdAt': '2026-10-22T10:00:00Z', 'selected': <String, String>{}},
              'events': events,
              'running': false,
              'goal': goal,
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
        'text': b['diagnose'] == true
            ? '🔍 自动检查当前桌面'
            : b['goalContinue'] == true
                ? '🎯 继续推进目标'
                : b['message'],
        'kind': b['diagnose'] == true
            ? 'diagnose'
            : b['goalContinue'] == true
                ? 'goal'
                : 'chat',
        'harness': b['harness'] ?? 'claude',
        'turn': turn,
        'parent': b['parentTurn'],
        if ((b['kbRefs'] as List?)?.isNotEmpty == true)
          'kbRefs': [
            {'id': 'k1', 'type': 'experience', 'title': '桌面图标被隐藏的排查方法'}
          ]
      });
      send('session', {'sessionId': sessionId, 'title': first ? b['message'] : '', 'mcpStatus': mcpStatus, if (mcpStatus == 'offline') 'offline': offlineReason, 'autoApprove': false});
      if (b['goal'] is Map) {
        goal = {'objective': b['goal']['objective'], 'status': 'active', 'maxTurns': b['goal']['maxTurns'], 'turnsUsed': 0, 'timeUsedMs': 0, 'reason': '', 'summary': ''};
        send('goal', {'goal': goal});
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (withThinking) {
        withThinking = false;
        send('thinking_delta', {'text': '先看看进程'});
        await Future<void>.delayed(const Duration(milliseconds: 10));
        send('thinking', {'text': '先看看进程列表，找出占用高的程序'});
        send('tool_use', {
          'id': 'ps1',
          'name': 'run_powershell',
          'input': {'command': 'Get-Process | Sort CPU'}
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        send('tool_result', {'id': 'ps1', 'isError': false, 'content': 'notepad 12%'});
      }
      if (quotaFail) {
        quotaFail = false;
        send('text', {'text': '我先看了一下'});
        send('harness_switch', {
          'from': 'claude',
          'to': 'codex',
          'retry': false,
          'kind': 'quota',
          'reason': "You've hit your weekly limit",
          'text': 'Claude 的额度用完了，这一轮没做完。'
        });
        send('done', {'sessionId': sessionId, 'isError': true, 'error': "You've hit your weekly limit", 'turns': 1, 'harness': 'claude'});
        await ctl.close();
        return;
      }
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
      if (goal != null && goal!['status'] == 'active') {
        final used = (goal!['turnsUsed'] as int) + 1;
        goal = {...goal!, 'turnsUsed': used, if (used >= (goal!['maxTurns'] as int)) 'status': 'budget_limited'};
        send('goal', {'goal': goal, if (goal!['status'] == 'budget_limited') 'note': '目标已经自动推进了 ${goal!['maxTurns']} 轮，还没完成，先停下。'});
      }
      send('done', {'sessionId': sessionId, 'isError': false, 'turns': 3, 'cost': 0.0123, 'harness': b['harness'] ?? 'claude'});
      await ctl.close();
    }();
    return http.StreamedResponse(ctl.stream, 200, headers: {'content-type': 'text/event-stream'});
  }
}
