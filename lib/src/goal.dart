// 目标模式（和网页版 ops.js“目标模式”一节一致）：给对话定一个目标，AI 每做完一轮，等几秒自动让它接着做，
// 直到它核对确实做完（complete）、卡住要人帮忙（blocked）、用完轮数（budget_limited），或者用户暂停、停止
// 目标状态以后台为准（/api/goal、对话里的 goal 事件、打开对话时带的 goal）
import 'dart:async';

import 'api.dart';
import 'controller.dart';
import 'models.dart';

const goalDefaultTurns = 10;
const goalTurnChoices = [5, 10, 20, 30, 50];
const goalAutoSeconds = 3;
const goalStatusNames = {'active': '进行中', 'paused': '已暂停', 'blocked': '卡住了', 'budget_limited': '轮数用完了', 'complete': '已完成'};

/// 自动推进的那一轮在记录里的标题
const goalTurnTitle = '🎯 继续推进目标';

class GoalInfo {
  GoalInfo(this.raw);
  final Map<String, dynamic> raw;
  String get objective => str(raw['objective']);
  String get status => str(raw['status']);
  int get maxTurns => (raw['maxTurns'] as num?)?.toInt() ?? goalDefaultTurns;
  int get turnsUsed => (raw['turnsUsed'] as num?)?.toInt() ?? 0;
  int get timeUsedMs => (raw['timeUsedMs'] as num?)?.toInt() ?? 0;
  String get reason => str(raw['reason']);
  String get summary => str(raw['summary']);
  bool get active => status == 'active';
  bool get unfinished => status != 'complete';

  static GoalInfo? from(dynamic v) => v is Map && v.isNotEmpty ? GoalInfo(asMap(v)) : null;
}

/// “/目标 内容”（或 /goal）：返回目标内容（只打“/目标”时是空字符串）；不是这个命令返回 null
String? parseGoalCommand(String text) {
  final m = RegExp(r'^[/／](?:目标|goal)(?:\s+([\s\S]*))?$', caseSensitive: false).firstMatch(text.trim());
  return m == null ? null : (m.group(1) ?? '').trim();
}

class GoalState {
  GoalState(this.ctl);
  final ChatController ctl;

  GoalInfo? goal;

  /// 打开旧对话时目标在进行中：先不自动推进，等用户点“继续推进”（免得一打开 AI 就开始操作电脑）
  bool hold = false;

  /// 倒数几秒后自动接着做（倒数时可以点暂停）
  int left = 0;
  Timer? _timer;
  bool get counting => _timer != null;
  bool get unfinished => goal != null && goal!.unfinished;

  /// 界面上要打开“设定/修改目标”窗口（由输入区注册）
  void Function()? onOpenDialog;

  void set(GoalInfo? g, {bool? hold}) {
    goal = g;
    if (hold != null) this.hold = hold;
    if (g == null || !g.active) cancelAuto(notify: false);
    ctl.refresh();
  }

  void cancelAuto({bool notify = true}) {
    _timer?.cancel();
    _timer = null;
    if (notify) ctl.refresh();
  }

  /// 一轮结束后：目标还在进行中、没有排队的消息、没停过，就倒数几秒自动接着做
  void scheduleAuto() {
    final g = goal;
    if (g == null || !g.active || hold || ctl.busy || ctl.sessionId == null || ctl.queue.isNotEmpty || ctl.queuePaused || _timer != null) return;
    left = goalAutoSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (--left > 0) return ctl.refresh();
      cancelAuto();
      continueNow();
    });
    ctl.refresh();
  }

  void continueNow() {
    final g = goal;
    if (ctl.busy || g == null || !g.active) return;
    hold = false;
    ctl.send(SendOptions(goalContinue: true));
  }

  Future<Map<String, dynamic>?> _action(String action, [Map<String, dynamic> extra = const {}]) async {
    try {
      final r = await ctl.api.post('/api/goal', {'sessionId': ctl.sessionId, 'action': action, ...extra});
      set(GoalInfo.from(r['goal']));
      return r;
    } on ApiError catch (e) {
      ctl.toast(e.message);
      return null;
    }
  }

  Future<void> pause() async {
    cancelAuto();
    await _action('pause');
  }

  /// 继续（暂停、卡住后）/ 再做几轮（轮数用完后）：后台没有任务在跑就马上接着做
  Future<void> resume({bool extend = false}) async {
    final r = await _action(extend ? 'extend' : 'resume', extend ? {'turns': goalDefaultTurns} : {});
    if (r != null && r['running'] != true) continueNow();
  }

  Future<void> clear() async {
    cancelAuto();
    if (await _action('clear') != null) ctl.toast('已清除目标');
  }

  /// 设定新目标（输入框里的附件、引用、@ 一起发出去）或修改还没完成的目标
  Future<void> submit(String text, {int maxTurns = goalDefaultTurns}) async {
    text = text.trim();
    if (text.isEmpty) return ctl.toast('请写下要达成的目标');
    if (unfinished) {
      final r = await _action('edit', {'objective': text});
      if (r == null) return;
      ctl.toast('目标已修改，AI 下一轮按新目标做');
      if (r['running'] != true) {
        hold = false;
        scheduleAuto();
      }
      return;
    }
    final c = ctl.composerContent();
    if (c.error != null) return ctl.toast(c.error!);
    final back = ctl.clearComposer();
    final o = c.opts!.withGoal(text, {'objective': text, 'maxTurns': maxTurns});
    if (ctl.busy) return ctl.enqueue(o);
    ctl.send(o, onFail: back);
  }

  void dispose() => _timer?.cancel();
}
