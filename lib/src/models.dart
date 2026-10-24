// 数据结构：对话事件、轮次树（重新生成、编辑重发产生的多个版本）、知识库、技能、记忆
import 'dart:convert';

const diagnoseTitle = '🔍 自动检查当前桌面';
const summarizeTitle = '📝 总结本次对话的经验到知识库';

Map<String, dynamic> asMap(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<dynamic> asList(dynamic v) => v is List ? v : const [];
String str(dynamic v) => v == null ? '' : v.toString();

/// 一条对话事件：e 是类型（user、text、approval…），d 是内容，turn 是属于哪一轮
class ChatEvent {
  ChatEvent(this.e, this.d, [this.turn]);
  final String e;
  final Map<String, dynamic> d;
  final String? turn;

  factory ChatEvent.fromJson(Map<String, dynamic> j) => ChatEvent(str(j['e']), asMap(j['d']), j['turn'] as String?);
}

/// 附件信息（服务端返回的，不含机器地址）
class AttachmentInfo {
  AttachmentInfo({required this.group, required this.id, required this.name, required this.size, required this.kind, this.type = '', this.pasted = false});
  final String group, id, name, kind, type;
  final int size;
  final bool pasted;

  factory AttachmentInfo.fromJson(Map<String, dynamic> j) => AttachmentInfo(
        group: str(j['group']),
        id: str(j['id']),
        name: str(j['name']),
        size: (j['size'] as num?)?.toInt() ?? 0,
        kind: str(j['kind']),
        type: str(j['type']),
        pasted: j['pasted'] == true,
      );
  Map<String, dynamic> get ref => {'group': group, 'id': id};
  String get key => '$group/$id';
  bool get isImage => kind == 'image';
}

/// @ 推荐的知识库条目，或 @ 选中的技能
class RefItem {
  RefItem({required this.id, required this.type, required this.title});
  final String id, type, title;
  bool get isSkill => type == 'skill';
  factory RefItem.fromJson(Map<String, dynamic> j) => RefItem(id: str(j['id']), type: str(j['type']), title: str(j['title']));
}

/// 一轮提问：用户消息 + 这一轮的所有事件
class Turn {
  Turn({required this.id, required this.parent, required this.kind, required this.user});
  final String id;
  final String? parent;
  final String kind; // chat | diagnose | summarize
  final Map<String, dynamic> user;
  final List<ChatEvent> events = [];
  bool done = false;
  Map<String, dynamic>? feedback;

  String get text => str(user['text']);
  bool get noText => user['noText'] == true;
  List<AttachmentInfo> get attachments => asList(user['attachments']).map((a) => AttachmentInfo.fromJson(asMap(a))).toList();
  List<RefItem> get kbRefs => asList(user['kbRefs']).map((r) => RefItem.fromJson(asMap(r))).toList();
  String get quote => str(user['quote']);
  Map<String, dynamic>? get skill => user['skill'] is Map ? asMap(user['skill']) : null;

  /// 这一轮 AI 回复的原文（复制、朗读用），去掉问题选项代码块
  String get replyText => events.where((e) => e.e == 'text').map((e) => splitOptions(str(e.d['text'])).text).where((t) => t.isNotEmpty).join('\n\n');
}

/// 轮次树：每个分叉处可以有多个版本
class TurnTree {
  final Map<String, Turn> turns = {};
  final Map<String, List<String>> kids = {};

  /// 按记录建树；以前没有轮次编号的记录按第几次提问编成 L1、L2…（和服务端规则一致）
  static TurnTree build(List<ChatEvent> events) {
    final tree = TurnTree();
    var legacy = 0;
    String? legacyCur, cur;
    for (final ev in events) {
      if (ev.e == 'user') {
        String id;
        String? parent;
        if (ev.turn != null) {
          id = ev.turn!;
          parent = ev.d['parent'] as String?;
        } else {
          id = 'L${++legacy}';
          parent = legacyCur;
          legacyCur = id;
        }
        final text = str(ev.d['text']);
        final kind = ev.d['kind'] as String? ??
            (text == diagnoseTitle
                ? 'diagnose'
                : text == summarizeTitle
                    ? 'summarize'
                    : 'chat');
        tree.turns[id] = Turn(id: id, parent: parent, kind: kind, user: ev.d);
        (tree.kids[parent ?? 'root'] ??= []).add(id);
        cur = id;
        continue;
      }
      final t = tree.turns[ev.turn ?? cur] ?? tree.turns[cur];
      if (t == null) continue;
      if (ev.e == 'feedback') {
        t.feedback = ev.d['value'] == null ? null : ev.d;
        continue;
      }
      if (ev.e == 'done' || ev.e == 'error') t.done = true;
      t.events.add(ev);
    }
    return tree;
  }

  /// 当前看的这个版本：每个分叉处按 selected 选，没选过就看最新的
  List<Turn> path(Map<String, String> selected) {
    final out = <Turn>[];
    var key = 'root';
    while (true) {
      final ids = kids[key];
      if (ids == null || ids.isEmpty) return out;
      final id = ids.contains(selected[key]) ? selected[key]! : ids.last;
      out.add(turns[id]!);
      key = id;
    }
  }

  List<String> siblings(Turn t) => kids[t.parent ?? 'root'] ?? const [];
}

/// 自动检查桌面后 AI 给出的问题选项
class DiagOption {
  DiagOption(this.title, this.detail);
  final String title, detail;
}

/// 从 AI 回复里取出 ```options 代码块
({String text, List<DiagOption>? options}) splitOptions(String text) {
  final m = RegExp(r'```options\s*\n([\s\S]*?)```').firstMatch(text);
  if (m == null) return (text: text, options: null);
  var options = <DiagOption>[];
  try {
    options = asList(jsonDecode(m.group(1)!)).map(asMap).where((o) => str(o['title']).isNotEmpty).take(4).map((o) => DiagOption(str(o['title']), str(o['detail']))).toList();
  } catch (_) {}
  return (text: text.replaceFirst(m.group(0)!, '').trim(), options: options);
}

/// 历史对话列表的一项
class SessionSummary {
  SessionSummary({required this.id, required this.title, required this.updatedAt, required this.rounds, required this.shared});
  final String id, title;
  final DateTime? updatedAt;
  final int rounds;
  final bool shared;
  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
        id: str(j['id']),
        title: str(j['title']),
        updatedAt: DateTime.tryParse(str(j['updatedAt']))?.toLocal(),
        rounds: (j['rounds'] as num?)?.toInt() ?? 1,
        shared: j['shared'] == true,
      );
}

/// 经验的使用统计
class KbStats {
  KbStats(this.calls, this.effective, this.ratio);
  final int calls, effective;
  final double? ratio;
  factory KbStats.fromJson(Map<String, dynamic> j) => KbStats((j['calls'] as num?)?.toInt() ?? 0, (j['effective'] as num?)?.toInt() ?? 0, (j['ratio'] as num?)?.toDouble());
  String get ratioText => ratio == null ? '—' : '${(ratio! * 100).round()}%';
}

/// 知识库条目（经验、背景知识）
class KbItem {
  KbItem(this.raw);
  final Map<String, dynamic> raw;
  String get id => str(raw['id']);
  String get type => str(raw['type']);
  bool get isExperience => type == 'experience';
  String get title => str(raw['title']);
  String get content => str(raw['content']);
  String get source => str(raw['source']);
  String get machine => str(raw['machine']);
  DateTime? get updatedAt => DateTime.tryParse(str(raw['updatedAt']))?.toLocal();
  String attr(String k) => str(raw[k]);
  KbStats get stats => KbStats.fromJson(asMap(raw['stats']));
}

/// 技能
class SkillItem {
  SkillItem(this.raw);
  final Map<String, dynamic> raw;
  String get id => str(raw['id']);
  String get name => str(raw['name']);
  String get description => str(raw['description']);
  String get content => str(raw['content']);
  bool get enabled => raw['enabled'] != false;
  int get useCount => (raw['useCount'] as num?)?.toInt() ?? 0;
  String get machine => str(raw['machine']);
  DateTime? get updatedAt => DateTime.tryParse(str(raw['updatedAt']))?.toLocal();
}

/// 记忆
class MemoryItem {
  MemoryItem(this.raw);
  final Map<String, dynamic> raw;
  String get id => str(raw['id']);
  String get scope => str(raw['scope']);
  String get content => str(raw['content']);
  bool get byAi => raw['source'] == 'ai';
  DateTime? get updatedAt => DateTime.tryParse(str(raw['updatedAt']))?.toLocal();
}

const memoryScopeNames = {'bar': '这家网吧', 'machine': '这台机器'};
const kbTypeNames = {'experience': '经验', 'background': '背景知识'};

String fmtTime(DateTime? t) {
  if (t == null) return '';
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(t.month)}/${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
}

String fmtSize(int n) => n >= 1048576 ? '${(n / 1048576).toStringAsFixed(1)} MB' : '${(n / 1024).round().clamp(1, 1 << 30)} KB';
