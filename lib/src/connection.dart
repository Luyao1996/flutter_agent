// 连接方式、身份和电脑离线（和网页版 ops.js 的 startConn / setOffline / reconnectNow / showWho 一致）
// - /api/start 给回的这次连接的情况（StartInfo）：打开的人是哪套身份（who）、电脑离线的原因、网吧号、借来的网吧名称
// - 电脑离线：照样能对话、看历史、接着历史对话，只是 AI 不能操作这台电脑；顶部显示“电脑离线”，点“重新连接”恢复
// - 用密码打开（管理员）能看这台电脑上别人的对话：只能查看、改名、删除，不能接着问
import 'package:flutter/foundation.dart';

import 'api.dart';
import 'controller.dart';
import 'models.dart';

/// 口令远程借用的网吧名称：这台电脑以前用远程运维后台打开时的“分组/网吧名称”
@immutable
class BorrowedBar {
  const BorrowedBar({required this.id, required this.group, required this.name});
  final String id, group, name;
  static BorrowedBar? fromJson(Object? j) {
    final m = asMap(j);
    return str(m['name']).isEmpty ? null : BorrowedBar(id: str(m['id']), group: str(m['group']), name: str(m['name']));
  }
}

/// /api/start 给回的这次连接的情况
@immutable
class StartInfo {
  const StartInfo({this.env = '', this.who = '', this.barId = '', this.seat = '', this.role = '', this.autoRun = false, this.offline = '', this.borrowedBar});
  static const empty = StartInfo();

  /// 链接的环境：toolbox / yx / cloud / pass
  final String env;

  /// 打开的人是哪套身份（后台按登录令牌判断）：toolbox、yx（银杏）、cloud（云启动）、*（没有登录令牌，用密码打开的，算管理员）；旧后台不给是空
  final String who;

  /// 后台解密出的网吧号（口令远程是 room-随机码）、座位号、角色、是否自动执行
  final String barId, seat, role;
  final bool autoRun;

  /// 电脑连不上的原因；空 = 连上了
  final String offline;

  /// 口令远程借来的网吧名称（借不到为 null）
  final BorrowedBar? borrowedBar;

  factory StartInfo.fromJson(Map<String, dynamic> d) => StartInfo(
        env: str(d['env']),
        who: str(d['who']),
        barId: str(d['barId']),
        seat: str(d['seat']),
        role: str(d['role']),
        autoRun: d['autoRun'] == true,
        offline: str(d['offline']),
        borrowedBar: BorrowedBar.fromJson(d['borrowedBar']),
      );
}

/// 身份的中文名（顶部网吧信息后面的小标签）
const whoNames = {'cloud': '云启动', 'yx': '银杏', 'toolbox': '工具箱', '*': '管理员'};

/// 连接、身份、离线、只读对话的状态和操作；ChatController 混入
mixin ConnStateMixin on ChangeNotifier {
  NetbarApi get api;
  List<LocalNote> get notes;
  void toast(String m);

  /// 打开的人是哪套身份：toolbox / yx / cloud / *（管理员，用密码打开）；还没连上或旧后台为空
  String get who => api.info.who;

  /// 身份的中文名：云启动、银杏、工具箱、管理员；没有时为空
  String get whoLabel => whoNames[who] ?? '';

  /// 用密码打开的（没有登录令牌）：管理员，技能、知识库、记忆都能看能改，能看这台电脑上所有人的对话
  bool get isAdmin => who == '*';

  /// 电脑连不上的原因；空 = 没有离线
  String offline = '';
  bool get isOffline => offline.isNotEmpty;

  /// 正在重新连接
  bool reconnecting = false;

  /// 当前打开的是别人在这台电脑上的对话（用密码打开时能看）：只能查看，不能接着问；from 是从哪里打开的（toolbox / 银杏 / 云启动…）
  bool readOnlySession = false;
  String readOnlyFrom = '';

  static const readOnlyTip = '这是别人在这台电脑上的对话，只能查看；要提问请点“新对话”';
  static const offlineDiagnoseTip = '这台电脑现在连不上，检查不了。等它开机后点顶部的“重新连接”，或者直接描述问题问 AI';

  /// 状态变了要不要在对话里说明一次（打开、状态变化时）
  void setOffline(String reason, {bool tell = false}) {
    final was = offline;
    offline = reason;
    onlineChanged(was.isNotEmpty && reason.isEmpty);
    if (tell) {
      if (reason.isNotEmpty) {
        final r = reason.replaceFirst(RegExp(r'[。.]+$'), '');
        notes.add(LocalNote('sys', '这台电脑现在连不上：$r。\n你仍然可以和 AI 对话、查看和继续历史对话，只是 AI 暂时不能查看或操作这台电脑。等它开机后，点顶部的“重新连接”。'));
      } else if (was.isNotEmpty) {
        notes.add(LocalNote('sys', '这台电脑已经连上了，AI 可以照常操作它。'));
      }
    }
    notifyListeners();
  }

  /// 从离线变回在线时（显示“已连接”）
  void onlineChanged(bool backOnline);

  /// 电脑离线时点“重新连接”：照打开时一样连（AI 助手没在运行要先启动，可能要等几十秒）
  Future<void> reconnect() async {
    if (reconnecting) return;
    reconnecting = true;
    final tip = LocalNote('sys', '正在重新连接这台电脑${api.config.canLaunch ? '，AI 助手没在运行的话要先启动，可能要等几十秒' : ''}…');
    notes.add(tip);
    notifyListeners();
    try {
      final d = await api.post('/api/reconnect', const {}, NetbarApi.startTimeout);
      notes.remove(tip);
      final off = str(d['offline']);
      if (off.isNotEmpty) {
        toast('还是连不上：$off');
        setOffline(off);
      } else {
        setOffline('', tell: true);
      }
    } on ApiError catch (e) {
      notes.remove(tip);
      toast('重新连接失败：${e.message}');
    } finally {
      reconnecting = false;
      notifyListeners();
    }
  }

  /// 一轮开始时（session 事件）后台报的连接状态：电脑离线了 / 又连上了
  void onSessionStatus(Map<String, dynamic> d) {
    if (d['mcpStatus'] == 'offline') {
      final r = str(d['offline']).isEmpty ? '这台电脑现在连不上' : str(d['offline']);
      if (r != offline) setOffline(r, tell: offline.isEmpty);
    } else if (isOffline) {
      setOffline('', tell: true);
    }
  }
}
