// 语音通话（前台 + 主管）：实时语音模型负责听和说，要动电脑的事交给现在的 AI 处理。
// 和网页版 /api/voice 是同一套协议：麦克风 16kHz PCM16 走二进制帧上行，前台 24kHz PCM16 下行播放，
// 其余（开始说话、转写、AI 边说边出字、派发任务、确认高危操作）走 JSON 文本帧。
// 手机和 PC 都用：麦克风用 record 采流，播放用 flutter_soloud 喂 PCM（全平台：安卓/iOS/Windows/mac/Linux）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../controller.dart';
import '../models.dart';

/// 通话的当前状态（决定声波球怎么动、提示文字显示什么）
enum VoicePhase { connecting, listen, heard, think, speak, busy, approval, muted, idle }

const _phaseText = {
  VoicePhase.connecting: ['正在连接…', '第一次使用时会询问麦克风权限，请允许'],
  VoicePhase.listen: ['正在听', '直接说就行，说完会自动回应'],
  VoicePhase.heard: ['在听你说…', ''],
  VoicePhase.think: ['正在想…', ''],
  VoicePhase.speak: ['正在说', '直接开口就能打断，也可以点一下'],
  VoicePhase.busy: ['正在处理电脑上的事', '可以接着说话，比如问进度、叫停'],
  VoicePhase.approval: ['等你同意', '说“可以”或“不行”，也可以在卡片里点'],
  VoicePhase.muted: ['麦克风已关闭', '点麦克风按钮重新打开'],
  VoicePhase.idle: ['已暂停', '点一下继续'],
};

/// 一个可选的说话声音
class VoiceOption {
  VoiceOption(this.id, this.name, this.gender);
  final String id, name, gender;
  factory VoiceOption.fromJson(Map<String, dynamic> j) => VoiceOption(str(j['id']), str(j['name']), str(j['gender']));
}

/// 通话界面上的一条聊天气泡（显示几秒后自动淡出）
class VoiceBubble {
  VoiceBubble(this.id, this.isUser, this.text, {this.pending = false});
  final int id;
  final bool isUser;
  String text;
  bool pending; // 还没出文字：先占位不显示
  bool gone = false; // 正在淡出
  Timer? timer;
}

const _bubbleMax = 6;
const _fadeDelay = Duration(seconds: 7);
const _fadeAnim = Duration(milliseconds: 550);

class VoiceCallController extends ChangeNotifier {
  VoiceCallController(this.chat);
  final ChatController chat;

  // ---- 对外状态（界面用）----
  bool on = false; // 通话是否开着
  bool expanded = false; // 是否显示全屏通话界面
  bool muted = false;
  VoicePhase phase = VoicePhase.idle;
  String phaseHint = '';
  String machineLabel = '';
  final List<VoiceBubble> bubbles = [];
  List<VoiceOption> voices = [];
  String voiceId = '';
  String get voiceName => voices.firstWhere((v) => v.id == voiceId, orElse: () => VoiceOption('', '音色', '')).name;
  String get stateLabel => _phaseText[phase]![0];

  // ---- 内部 ----
  WebSocketChannel? _ws;
  bool _ready = false;
  bool _disposed = false;
  final _rec = AudioRecorder();
  StreamSubscription? _micSub;
  bool _playbackReady = false;
  final _soloud = SoLoud.instance;
  AudioSource? _stream;
  bool _drop = false; // 被打断的回答还在路上的声音：不播
  bool _playing = false;

  String _you = '', _ai = '';
  VoiceBubble? _youBubble, _aiBubble;
  int _bubbleSeq = 0;

  // 和 Agent 一轮运行衔接
  String _agentText = '';
  bool _agentSent = false;
  String _runError = '';
  String _greet = '';
  // 还没处理的确认（通话中途连上也能接上）：id -> 事件数据
  final Map<String, Map<String, dynamic>> _pendingApprovals = {};

  bool get active => on && _ready;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  // ---------- 开始 / 结束 / 暂停 ----------
  /// 返回是否成功开始（没有麦克风权限时返回 false，界面就不用进通话页）
  Future<bool> enter() async {
    if (on) return true;
    if (chat.config.mcpUrl.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    voiceId = prefs.getString('netbar_ops.talkVoice') ?? '';
    // 先要麦克风权限，没有就别开
    if (!await _rec.hasPermission()) {
      chat.toast('没有麦克风权限：请在系统设置里允许这个应用使用麦克风。');
      return false;
    }
    on = true;
    muted = false;
    expanded = true;
    machineLabel = chat.config.machineName.isNotEmpty ? chat.config.machineName : '远程电脑';
    _seedHistory();
    notifyListeners();
    await _start();
    return true;
  }

  Future<void> _start() async {
    _phase(VoicePhase.connecting);
    try {
      await _initPlayback();
      await _startMic();
    } catch (e) {
      return _exit('打开麦克风失败：$e');
    }
    if (!on) return _release();
    _connect();
  }

  void _connect() {
    final base = chat.config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final wsBase = base.replaceFirst(RegExp(r'^http'), 'ws');
    try {
      final ch = WebSocketChannel.connect(Uri.parse('$wsBase/api/voice'));
      _ws = ch;
      _ready = false;
      ch.ready.then((_) {
        if (_ws != ch || !on) return;
        _send({
          'type': 'start',
          'machine': chat.config.machineName,
          'barName': chat.config.barName,
          'mcpUrl': chat.config.mcpUrl,
          'token': chat.config.token,
          'busy': chat.busy,
          'history': _history(),
          if (voiceId.isNotEmpty) 'voice': voiceId,
          if (_greet.isNotEmpty) 'greet': _greet,
        }, force: true);
        _greet = '';
      }).catchError((_) {});
      ch.stream.listen(
        (data) {
          if (data is String) {
            _event(jsonDecode(data) as Map<String, dynamic>);
          } else if (data is List<int>) {
            _playChunk(data is Uint8List ? data : Uint8List.fromList(data));
          }
        },
        onError: (_) => _onClosed(),
        onDone: _onClosed,
      );
    } catch (e) {
      _pause('连不上语音服务，点一下重试');
    }
  }

  void _onClosed() {
    if (_ws == null) return;
    _ws = null;
    _ready = false;
    if (on) _pause(phase == VoicePhase.connecting ? '连不上语音服务，点一下重试' : '语音连接断开了，点一下重新连接');
  }

  /// 暂停：关掉麦克风和连接，界面状态留着，点一下继续
  void _pause(String msg) {
    _hush();
    _release();
    _phase(VoicePhase.idle, msg);
  }

  /// 点“继续”/点状态：重新连
  void resume() {
    if (!on) return;
    _start();
  }

  /// 关掉麦克风和连接（播放资源留着，继续时还能出声）
  void _release() {
    final ws = _ws;
    _ws = null;
    _ready = false;
    _micSub?.cancel();
    _micSub = null;
    _rec.stop().catchError((_) => null);
    ws?.sink.close().catchError((_) {});
  }

  void exit() => _exit(null);

  void _exit(String? err) {
    if (!on) return;
    on = false;
    _ready = false;
    expanded = false;
    _hush();
    _release();
    _pendingApprovals.clear();
    for (final b in bubbles) {
      b.timer?.cancel();
    }
    bubbles.clear();
    _youBubble = _aiBubble = null;
    _releasePlayback();
    notifyListeners();
    if (err != null) chat.toast(err);
  }

  // ---------- 全屏界面开合 ----------
  void openScreen() {
    if (!on) return;
    expanded = true;
    machineLabel = chat.config.machineName.isNotEmpty ? chat.config.machineName : '远程电脑';
    if (bubbles.isEmpty) _seedHistory();
    notifyListeners();
  }

  void minimize() {
    expanded = false;
    notifyListeners();
  }

  // ---------- 麦克风 ----------
  Future<void> _startMic() async {
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    ));
    _micSub = stream.listen((data) {
      if (_ready && !muted && _ws != null) _ws!.sink.add(data);
    });
  }

  void toggleMute() {
    muted = !muted;
    if (muted) {
      if (phase != VoicePhase.speak) _phase(VoicePhase.muted);
    } else {
      _settle();
    }
    notifyListeners();
  }

  // ---------- 播放：24kHz 单声道 PCM16，流式喂给 soloud，播完/打断由它处理 ----------
  Future<void> _initPlayback() async {
    if (_playbackReady) return;
    if (!_soloud.isInitialized) await _soloud.init();
    _stream = _soloud.setBufferStream(
      bufferingType: BufferingType.released, // 播过的内存及时释放，适合长时间说话
      bufferingTimeNeeds: 0.12, // 攒够 ~120ms 就开始放，低延迟
      sampleRate: 24000,
      channels: Channels.mono,
      format: BufferType.s16le,
      maxBufferSizeDuration: const Duration(seconds: 30),
      onBuffering: (isBuffering, handle, time) {
        // 正在说的时候缓冲空了 = 这段说完了，回到“正在听”
        if (isBuffering && phase == VoicePhase.speak) {
          _playing = false;
          _settle();
        }
      },
    );
    _soloud.play(_stream!);
    _playbackReady = true;
  }

  void _playChunk(Uint8List bytes) {
    if (!on || _drop || bytes.isEmpty || _stream == null) return;
    try {
      _soloud.addAudioDataStream(_stream!, bytes);
    } catch (_) {
      // 缓冲满等异常：丢掉这块，不影响后续
    }
    _playing = true;
    if (phase != VoicePhase.speak) _phase(VoicePhase.speak, _ai.isNotEmpty ? _tail(_ai) : null);
  }

  // 打断：清空没播的声音（很快安静下来）
  void _hush() {
    if (_stream != null) {
      try {
        _soloud.resetBufferStream(_stream!);
      } catch (_) {}
    }
    _playing = false;
  }

  void _releasePlayback() {
    if (!_playbackReady) return;
    _playbackReady = false;
    final s = _stream;
    _stream = null;
    if (s != null) _soloud.disposeSource(s).catchError((_) {});
    if (_soloud.isInitialized) _soloud.deinit();
  }

  // ---------- 状态机 ----------
  void _phase(VoicePhase p, [String? hint]) {
    phase = p;
    phaseHint = hint ?? _phaseText[p]![1];
    notifyListeners();
  }

  // AI 没在说话时该回到什么状态
  void _settle() {
    if (!on || phase == VoicePhase.idle || phase == VoicePhase.connecting || _playing) return;
    if (muted) {
      _phase(VoicePhase.muted);
    } else if (_pendingApprovals.isNotEmpty) {
      _phase(VoicePhase.approval);
    } else if (chat.busy) {
      _phase(VoicePhase.busy);
    } else {
      _phase(VoicePhase.listen);
    }
  }

  void _send(Map<String, dynamic> obj, {bool force = false}) {
    if (_ws == null) return;
    if (!force && !_ready) return;
    _ws!.sink.add(jsonEncode(obj));
  }

  /// 点声波球/状态：正在说就打断，暂停了就继续
  void tapMain() {
    if (phase == VoicePhase.speak) {
      _hush();
      _drop = true;
      _send({'type': 'interrupt'});
      _settle();
    } else if (phase == VoicePhase.idle) {
      resume();
    }
  }

  // ---------- 服务端事件 ----------
  void _event(Map<String, dynamic> m) {
    switch (str(m['type'])) {
      case 'ready':
        _ready = true;
        voices = asList(m['voices']).map((v) => VoiceOption.fromJson(asMap(v))).toList();
        voiceId = str(m['voice']);
        _phase(VoicePhase.listen);
        for (final a in _pendingApprovals.values) {
          _send(_approvalMsg(a));
        }
        _settle();
      case 'speech_started':
        // 用户开口：AI 没说完的立即停下；为这句占个位置（文字晚到也不会跑到 AI 下面）
        _hush();
        _drop = true;
        _you = '';
        _doneBubble(_youBubble);
        _doneBubble(_aiBubble);
        _aiBubble = null;
        _youBubble = _newBubble(true, '');
        if (!muted) _phase(VoicePhase.heard);
      case 'speech_stopped':
        if (phase == VoicePhase.heard) {
          _settle();
          if (_you.isNotEmpty) _setHint('你：$_you');
        }
      case 'user_text':
        _you = str(m['text']);
        if (phase != VoicePhase.speak) _setHint('你：$_you');
        _youBubble ??= _newBubble(true, '');
        _fillBubble(_youBubble!, _you);
      case 'response_started':
        _ai = '';
        _drop = false;
        _doneBubble(_aiBubble);
        _aiBubble = null;
        if (phase != VoicePhase.speak) _phase(VoicePhase.think, _you.isNotEmpty ? '你：$_you' : '');
      case 'ai_text':
        _ai += str(m['delta']);
        if (phase == VoicePhase.speak) _setHint(_tail(_ai));
        _aiBubble ??= _newBubble(false, '');
        _fillBubble(_aiBubble!, _ai);
      case 'response_done':
        _fadeBubble(_aiBubble);
        _fadeBubble(_youBubble);
        if (!_playing) _settle();
      case 'delegate':
        chat.sendVoiceObjective(str(m['objective']));
      case 'cancel_task':
        chat.stopByUser();
      case 'approve':
        if (chat.taskId != null) chat.approve(str(m['id']), allow: m['allow'] == true);
      case 'closed':
        _ws = null;
        final reason = str(m['reason']);
        if (reason == 'user') {
          _exit(null);
        } else if (reason == 'fatal' || reason == 'full') {
          _exit(str(m['message']));
        } else {
          _pause(str(m['message']).isNotEmpty ? str(m['message']) : '语音连接断开了，点一下重新连接');
        }
    }
  }

  void _setHint(String t) {
    phaseHint = t;
    notifyListeners();
  }

  String _tail(String s) => s.length <= 60 ? s : s.substring(s.length - 60);

  // ---------- 气泡 ----------
  VoiceBubble _newBubble(bool isUser, String text) {
    final b = VoiceBubble(_bubbleSeq++, isUser, text, pending: text.isEmpty);
    bubbles.add(b);
    while (bubbles.length > _bubbleMax) {
      bubbles.removeAt(0).timer?.cancel();
    }
    notifyListeners();
    return b;
  }

  void _fillBubble(VoiceBubble b, String text) {
    if (text.isEmpty) return;
    b.text = text;
    b.pending = false;
    b.gone = false;
    b.timer?.cancel();
    notifyListeners();
  }

  void _fadeBubble(VoiceBubble? b) {
    if (b == null || b.pending || b.gone || b.timer != null) return;
    b.timer = Timer(_fadeDelay, () {
      b.gone = true;
      notifyListeners();
      Timer(_fadeAnim, () {
        bubbles.remove(b);
        notifyListeners();
      });
    });
  }

  // 一个气泡收尾：一直没出文字的删掉，有文字的开始淡出
  void _doneBubble(VoiceBubble? b) {
    if (b == null) return;
    if (b.pending) {
      b.timer?.cancel();
      bubbles.remove(b);
      notifyListeners();
    } else {
      _fadeBubble(b);
    }
  }

  void _seedHistory() {
    for (final b in bubbles) {
      b.timer?.cancel();
    }
    bubbles.clear();
    _youBubble = _aiBubble = null;
    for (final h in _recentTurns()) {
      final b = _newBubble(h.$1, h.$2);
      _fadeBubble(b);
    }
  }

  // ---------- 和文字对话的衔接（ChatController 在运行时调用）----------
  void onBusy(bool b) {
    if (!on) return;
    if (b) {
      _agentText = '';
      _agentSent = false;
      _runError = '';
    }
    _send({'type': 'task_state', 'busy': b});
    if (phase != VoicePhase.speak) _settle();
  }

  void onAgentText(String text) {
    if (!on) return;
    _agentText = text;
    _agentSent = false;
  }

  void onAgentTool() {
    if (!on || _agentText.isEmpty || _agentSent) return;
    _agentSent = true;
    _send({'type': 'task_progress', 'text': _agentText});
  }

  void onRunError(String msg) {
    if (on) _runError = msg;
  }

  void onRunEnded(List<String> options) {
    if (!on) return;
    _send({'type': 'task_result', 'busy': chat.busy, 'text': _agentText, 'error': _runError, 'options': options});
    _agentText = '';
    _runError = '';
    _pendingApprovals.clear();
    if (phase != VoicePhase.speak) Future.delayed(const Duration(milliseconds: 50), _settle);
  }

  void onApproval(Map<String, dynamic> d) {
    if (!on) return;
    _pendingApprovals[str(d['id'])] = d;
    _send(_approvalMsg(d));
    if (phase != VoicePhase.speak) _settle();
  }

  void onApprovalDone(String id, bool allow) {
    if (!on) return;
    _pendingApprovals.remove(id);
    _send({'type': 'approval_done', 'id': id, 'allow': allow});
    if (phase != VoicePhase.speak) _settle();
  }

  Map<String, dynamic> _approvalMsg(Map<String, dynamic> a) {
    final machine = str(a['machine']);
    final connect = a['connect'] == true;
    final what = connect
        ? '连接本网吧的另一台电脑 $machine，连上后可以在那台电脑上查看和操作'
        : '${machine.isNotEmpty ? "在另一台电脑 $machine 上" : ""}执行一个会改动电脑的操作：${str(a['tool'])}';
    return {
      'type': 'approval',
      'id': str(a['id']),
      'risks': asList(a['risks']).map(str).toList(),
      'what': what,
      'detail': jsonEncode(a['input'] ?? {}),
    };
  }

  // ---------- 换声音 ----------
  Future<void> setVoice(String id) async {
    if (id == voiceId) return;
    voiceId = id;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString('netbar_ops.talkVoice', id);
    // 连着的话重新连一次，用新声音说一句（音色只能在开始时设置）
    if (on && phase != VoicePhase.idle) {
      _hush();
      _release();
      _greet = '声音换好了，之后我就用这个声音跟你说话。';
      _start();
    }
  }

  // ---------- 历史：让前台知道“刚才那个”指什么 ----------
  List<(bool, String)> _recentTurns() {
    final out = <(bool, String)>[];
    final chats = chat.path.where((t) => t.kind == 'chat').toList();
    for (final t in chats.length > 6 ? chats.sublist(chats.length - 6) : chats) {
      if (t.text.isNotEmpty && !t.noText) out.add((true, _clip(t.text)));
      final reply = t.replyText;
      if (reply.isNotEmpty) out.add((false, _clip(reply)));
    }
    return out;
  }

  List<Map<String, String>> _history() =>
      _recentTurns().map((e) => {'role': e.$1 ? 'user' : 'assistant', 'text': e.$2}).toList();

  String _clip(String s) => s.length <= 300 ? s : s.substring(0, 300);

  @override
  void dispose() {
    _disposed = true;
    _hush();
    _release();
    _rec.dispose();
    for (final b in bubbles) {
      b.timer?.cancel();
    }
    _releasePlayback();
    super.dispose();
  }
}
