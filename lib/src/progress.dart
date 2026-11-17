// 输入框上方的进度条和“AI 的处理过程”（和网页版 ops.js 的 think 一节一致）
// 这一轮的过程（每段思考、每次调用的工具）直接从这一轮的记录里取：思考过程会存进对话记录（thinking 事件），
// 只有正在想的这一段（thinking_delta，只有 Claude 边想边推）不进记录，单独放在 live 里
// 思考内容后台已经要求用中文、英文的会翻译好再推过来，这里照原样显示
import 'models.dart';

/// 处理过程里的一步：一段思考，或者一次工具调用
class ThinkStep {
  ThinkStep.think(this.text, {this.live = false})
      : type = 'think',
        id = '',
        name = '',
        input = null,
        machine = '';
  ThinkStep.tool({required this.id, required this.name, this.input, this.machine = ''})
      : type = 'tool',
        text = '',
        live = false;
  final String type; // think | tool
  final String text, id, name, machine;
  final dynamic input;
  final bool live;
  String state = 'run'; // 工具：run 调用中 / ok / err
  String result = '';
  bool get isThink => type == 'think';
}

/// 一轮里的处理过程（按顺序）；live 是正在想、还没想完的这一段
List<ThinkStep> thinkSteps(Turn? t, {String live = ''}) {
  final out = <ThinkStep>[];
  final tools = <String, ThinkStep>{};
  for (final ev in t?.events ?? const <ChatEvent>[]) {
    final d = ev.d;
    if (ev.e == 'thinking' && str(d['text']).trim().isNotEmpty) {
      out.add(ThinkStep.think(str(d['text'])));
    } else if (ev.e == 'tool_use') {
      final s = ThinkStep.tool(id: str(d['id']), name: str(d['name']), input: d['input'], machine: str(d['machine']));
      tools[s.id] = s;
      out.add(s);
    } else if (ev.e == 'tool_result') {
      final s = tools[str(d['id'])];
      if (s == null) continue;
      s.state = d['isError'] == true ? 'err' : 'ok';
      final r = d['content'] is String ? d['content'] as String : (d['content'] == null ? '' : d['content'].toString());
      s.result = r.length > 3000 ? r.substring(0, 3000) : r;
    }
  }
  if (live.isNotEmpty) out.add(ThinkStep.think(live, live: true));
  return out;
}

/// 工具名换成网管看得懂的说法；没列出的显示原名
const toolLabels = {
  'run_powershell': '执行 PowerShell 命令', 'run_cmd': '执行命令', 'screenshot': '截屏', 'list_dir': '查看文件夹', 'read_text_file': '读取文件',
  'list_processes': '查看进程', 'kill_process': '结束进程', 'get_system_info': '查看系统信息', 'get_hardware_info': '查看硬件信息',
  'get_perf': '查看性能占用', 'get_sensors': '查看温度', 'get_event_log': '查看系统日志', 'get_bsod_history': '查看蓝屏记录',
  'get_disk_health': '查看硬盘健康', 'get_startup_items': '查看开机启动项', 'list_windows': '查看窗口', 'get_ui_tree': '读取界面内容',
  'window_action': '操作窗口', 'click_element': '点击界面', 'mouse': '操作鼠标', 'key_press': '按键盘', 'clipboard': '读写剪贴板',
  'list_services': '查看服务', 'control_service': '启停服务', 'start_program': '启动程序', 'restart_explorer': '重启桌面',
  'net_info': '查看网络', 'net_diag': '诊断网络', 'traceroute': '跟踪网络路由', 'list_connections': '查看网络连接',
  'display_info': '查看显示器', 'set_display': '调整显示设置', 'audio_devices': '查看声音设备', 'ask_user': '在电脑上弹窗提问',
  'download_url': '下载文件', 'download_file': '取回文件', 'upload_file': '上传文件', 'delete_path': '删除文件',
  'kb_search': '查知识库', 'kb_get': '读知识库', 'lib_tree': '看资料库目录', 'lib_read': '读资料', 'lib_grep': '在资料库里查找', 'skill_list': '查技能', 'skill_get': '读技能',
  'list_netbar_machines': '查本网吧的电脑', 'connect_machine': '连接另一台电脑', 'disconnect_machine': '断开另一台电脑',
  'share_remote_file': '生成文件下载链接', 'list_tools': '查看可用工具',
  'tool_library_list': '查看工具库', 'tool_package_inspect': '查看程序包', 'tool_library_save': '保存工具到工具库', 'tool_library_delete': '从工具库删除工具',
  'list_sfu_tools': '查看工具库', 'run_sfu_tool': '运行工具', 'WebSearch': '上网搜索', 'web_search': '上网搜索',
};

/// 问诊（公司的代码诊断服务）的工具名很通用（start、wait…），按服务名单独认
const _diagLabels = {'start': '开问诊单', 'wait': '等问诊结论', 'send': '给问诊补充信息', 'stop': '停止问诊', 'get': '查看问诊单', 'list': '查问诊记录', 'feedback': '反馈问诊结论', 'search': '搜公司代码和记录'};

String toolLabel(String name) {
  if (name.startsWith('mcp__diag__')) return _diagLabels[name.substring(11)] ?? '问诊';
  final n = name.replaceFirst(RegExp(r'^mcp__[^_]+(?:_[^_]+)*?__'), '');
  return toolLabels[n] ?? n;
}

/// 工具参数的一句话摘要：命令、路径这类最有用的那一项
String toolArg(dynamic input) {
  if (input is! Map) return input == null ? '' : input.toString();
  for (final k in ['command', 'script', 'cmd', 'path', 'query', 'name', 'program', 'url', 'machine', 'title', 'text']) {
    final v = input[k];
    if (v is String && v.trim().isNotEmpty) return v;
  }
  for (final v in input.values) {
    if (v is String && v.trim().isNotEmpty) return v;
  }
  return '';
}

String oneLine(String t) => t.replaceAll('**', '').replaceAll(RegExp(r'\s+'), ' ').trim();

String fmtElapsed(Duration d) {
  final s = d.inSeconds;
  return s < 60 ? '$s 秒' : '${s ~/ 60} 分 ${s % 60} 秒';
}

/// 正在做的事：work 处理中（text 是提示）/ tool 调用工具 / wait 等你确认（detail 是要确认的操作）/ reply 正在回复
class RunAct {
  const RunAct([this.kind = '', this.text = '', this.detail = '']);
  final String kind, text, detail;
}

/// 进度条的一行：标题（谁在做什么）+ 最新内容
({String title, String detail}) progressLine({required bool running, required String ai, required List<ThinkStep> steps, required RunAct act}) {
  if (!running) {
    // 结束后：灰色的一行，写这一轮想了几段、调用了几次工具，后面是最后一段思考
    final nThink = steps.where((x) => x.isThink).length, nTool = steps.length - nThink;
    final lastThink = steps.lastWhere((x) => x.isThink, orElse: () => ThinkStep.think(''));
    final count = [if (nThink > 0) '思考 $nThink 段', if (nTool > 0) '调用工具 $nTool 次'].join('，');
    return (title: '处理过程', detail: oneLine(count + (lastThink.text.isNotEmpty ? '：${lastThink.text}' : '')));
  }
  final last = steps.lastOrNull;
  String title, detail;
  if (act.kind == 'wait') {
    title = '$ai 在等你确认';
    detail = act.detail;
  } else if (last != null && last.live) {
    title = '$ai 正在思考';
    detail = last.text;
  } else if (act.kind == 'reply') {
    title = '$ai 正在回复';
    detail = '';
  } else if (last != null && !last.isThink && last.state == 'run') {
    title = '$ai 正在${toolLabel(last.name)}';
    detail = (last.machine.isNotEmpty ? '［${last.machine}］' : '') + toolArg(last.input);
  } else if (last != null && last.isThink && act.kind != 'tool') {
    title = '$ai 正在思考';
    detail = last.text;
  } else {
    final t = act.text.replaceFirst(RegExp(r'^AI\s*'), '').replaceFirst(RegExp(r'…$'), '');
    title = '$ai ${t.isEmpty ? '正在处理' : t}';
    detail = '';
  }
  // 只露出最新的结尾，像字幕一样往前滚
  detail = oneLine(detail);
  if (detail.length > 300) detail = '…${detail.substring(detail.length - 300)}';
  return (title: title, detail: detail);
}
