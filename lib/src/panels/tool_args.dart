// 工具库的规则（和网页版 tools.js 一致，不涉及界面，方便单独测试）：
//   参数值能用哪些字符、启动参数怎么从参数表生成（普通用户不用写模板）、已有的启动参数怎么拆回参数表、
//   “程序收到的命令行”预览、保存前的检查（生成 SFU 要的 meta）
import '../models.dart';

/// 风险：safe 直接运行；danger 要网吧电脑上的助手允许高风险工具才运行。不填时 zip 算 danger、http_get 算 safe
const toolRisks = {'safe': '安全：直接运行', 'danger': '高风险：电脑上的助手允许高风险工具时才运行'};

/// 运行方式（只有 zip）：不填算 silent
const toolModes = {'silent': '后台运行：不显示控制台窗口，等程序结束、拿到输出', 'interactive': '显示窗口：在顾客桌面打开，不等结束、拿不到输出'};

/// 帮助指令（只有 zip）：登记了以后，AI 运行时先跑它看用法，再用 argv 传参数；不登记运行时默认用 --help
const toolHelps = ['--help', '-help', '-h', 'help'];

/// 参数怎么传给程序
const toolHows = {'opt': '选项 + 值', 'pos': '只传值', 'flag': '开关（打开才加）'};

/// 工具是哪边上传的（SFU 只记昵称，后台上传时记下系统）
const toolOwners = {'toolbox': 'toolbox 上传', 'yx': '银杏上传', 'cloud': '云启动上传', 'admin': '管理员上传'};
const toolOwnerWho = {'toolbox': 'toolbox 那边的人', 'yx': '银杏那边的人', 'cloud': '云启动那边的人', 'admin': '管理员'};

final toolNameRe = RegExp(r'^[a-z0-9_-]{1,64}$');
final toolEntryRe = RegExp(r'\.(exe|bat|cmd|ps1)$', caseSensitive: false);
final toolParamRe = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
const toolMaxZip = 500 * 1024 * 1024;
const toolMaxTimeout = 540;

/// 大小：工具库总量是 20GB，要能显示 GB
String toolSize(num n) => n >= 1 << 30
    ? '${(n / (1 << 30)).toStringAsFixed(1)} GB'
    : n >= 1048576
        ? '${(n / 1048576).toStringAsFixed(1)} MB'
        : '${(n / 1024).round().clamp(n > 0 ? 1 : 0, 1 << 30)} KB';

/// zip 工具的参数值能用哪些字符（助手按风险和入口分级）：
///   safe：文字、数字、空格和 _ . : / \ -，最长 200 字；danger + .exe：除控制字符外都行，最长 1000 字；
///   danger + .bat/.cmd/.ps1：safe 的基础上再加 = ,，最长 200 字。不填风险时 zip 算 danger
({RegExp re, String text}) toolValueRule(String risk, String entry) {
  if ((risk.isEmpty ? 'danger' : risk) == 'safe') {
    return (re: RegExp(r'^[\p{L}\p{N} _.:/\\-]{0,200}$', unicode: true), text: '文字、数字、空格和 _ . : / \\ -，最长 200 字（风险是“安全”的工具）');
  }
  if (RegExp(r'\.exe$', caseSensitive: false).hasMatch(entry)) return (re: RegExp(r'^[^\p{Cc}]{0,1000}$', unicode: true), text: '除换行、制表符以外的字符，最长 1000 字');
  return (re: RegExp(r'^[\p{L}\p{N} _.:/\\=,-]{0,200}$', unicode: true), text: '文字、数字、空格和 _ . : / \\ - = ,，最长 200 字（入口是 .bat/.cmd/.ps1 的高风险工具）');
}

/// 一个参数怎么传给程序：how 是 opt（选项 + 值）/ pos（只传值）/ flag（开关），opt 是选项名
class ParamHow {
  const ParamHow(this.how, [this.opt = '']);
  final String how, opt;
  @override
  bool operator ==(Object other) => other is ParamHow && other.how == how && other.opt == opt;
  @override
  int get hashCode => Object.hash(how, opt);
  @override
  String toString() => '$how:$opt';
}

/// 参数表的一行
class ParamRow {
  ParamRow({this.name = '', this.desc = '', this.how = 'opt', this.opt = '', this.def = '', this.required = false, Map<String, dynamic>? orig}) : orig = orig ?? {};
  String name, desc, how, opt, def;
  bool required;

  /// 原来参数上表单里没有的字段（SFU 以后新加的）原样留着
  final Map<String, dynamic> orig;
}

bool _attached(String opt) => RegExp(r'[=:]$').hasMatch(opt);

/// 按参数表生成 SFU 的 args（参数表里的顺序 = 命令行里的顺序，固定启动参数放最前面）：
///   选项 + 值：--name 小艺（两段）；选项名以 = 或 : 结尾时连在一起：--name=小艺、/name:小艺；只传值：小艺；开关：打开时才加 --verbose
///   必填或有默认值的参数一定有值，直接写；可选又没默认值的，没填时整段不加（?参数名:… 的写法）
List<String> toolArgsFrom(List<String> fixed, List<ParamRow> rows) {
  final args = [...fixed];
  for (final r in rows) {
    final always = r.required || r.def.isNotEmpty;
    String cond(String x) => always ? x : '?${r.name}:$x';
    final val = '{${r.name}}';
    if (r.how == 'flag') {
      args.add('?${r.name}:${r.opt}');
    } else if (r.how == 'pos') {
      args.add(cond(val));
    } else if (_attached(r.opt)) {
      args.add(cond(r.opt + val));
    } else {
      args
        ..add(cond(r.opt))
        ..add(cond(val));
    }
  }
  return args;
}

/// 反过来：把已有工具的 args 拆回“固定启动参数 + 每个参数的传法”；拆不了（自己写的特殊模板）返回 null
({List<String> fixed, Map<String, ParamHow> how})? toolParseArgs(List<String> args, Map<String, dynamic> params) {
  final fixed = <String>[];
  final how = <String, ParamHow>{};
  bool has(String k) => params.containsKey(k);
  bool known(String k) => has(k) && !how.containsKey(k);
  bool isFlag(String k) => asMap(params[k])['flag'] == true;
  // 像选项名：以 - 开头，或者去掉前面的 - / 和后面的 = : 正好是参数名（/name、--Name=）
  bool optLike(String a, String k) => a.startsWith('-') || a.replaceAll(RegExp(r'^[-/]+|[=:]$'), '').toLowerCase() == k.toLowerCase();
  final whole = RegExp(r'^\{([\w-]+)\}$');
  bool valueNext(int j) {
    final m = whole.firstMatch(j + 1 < args.length ? args[j + 1] : '');
    return m != null && has(m.group(1)!) && optLike(args[j], m.group(1)!);
  }

  var i = 0;
  // 开头没有占位符的是固定启动参数；但后面紧跟“{参数}”的那一段是这个参数的选项名，不算
  while (i < args.length && !RegExp(r'\{|^\?[\w-]+:').hasMatch(args[i]) && !valueNext(i)) {
    fixed.add(args[i++]);
  }
  for (; i < args.length; i++) {
    final a = args[i];
    final n = i + 1 < args.length ? args[i + 1] : null;
    RegExpMatch? m;
    if ((m = RegExp(r'^\?([\w-]+):(.*)$').firstMatch(a)) != null) {
      final k = m!.group(1)!, x = m.group(2)!;
      if (!known(k)) return null;
      if (x == '{$k}') {
        how[k] = const ParamHow('pos');
        continue;
      }
      if (isFlag(k) && !x.contains('{')) {
        how[k] = ParamHow('flag', x);
        continue;
      }
      final tail = '{$k}';
      if (x.endsWith(tail)) {
        final opt = x.substring(0, x.length - tail.length);
        if (_attached(opt) && !opt.contains('{')) {
          how[k] = ParamHow('opt', opt);
          continue;
        }
      }
      if (!x.contains('{') && n == '?$k:{$k}') {
        how[k] = ParamHow('opt', x);
        i++;
        continue;
      }
      return null;
    }
    if ((m = whole.firstMatch(a)) != null && known(m!.group(1)!)) {
      how[m.group(1)!] = const ParamHow('pos');
      continue;
    }
    if ((m = RegExp(r'^([^{}]+[=:])\{([\w-]+)\}$').firstMatch(a)) != null && known(m!.group(2)!) && !a.startsWith('?')) {
      how[m.group(2)!] = ParamHow('opt', m.group(1)!);
      continue;
    }
    if (!a.contains('{') && n != null && (m = whole.firstMatch(n)) != null && known(m!.group(1)!) && optLike(a, m.group(1)!)) {
      how[m.group(1)!] = ParamHow('opt', a);
      i++;
      continue;
    }
    // 常见的写错：“--name {name}”写在了同一段（程序会收到一整段）。按本意认成“选项 + 值”，保存时会自动分开
    if ((m = RegExp(r'^([^\s{}?]+)\s+\{([\w-]+)\}$').firstMatch(a)) != null && known(m!.group(2)!)) {
      how[m.group(2)!] = ParamHow('opt', m.group(1)!);
      continue;
    }
    return null;
  }
  // 另一种写错：只写了“--name”没写 {name}。固定启动参数最后正好是某个没用到的参数的选项，就认成这个参数的选项
  for (final k in params.keys) {
    final last = fixed.isEmpty ? null : fixed.last;
    if (!how.containsKey(k) &&
        !isFlag(k) &&
        last != null &&
        RegExp('^(--?|/)${RegExp.escape(k)}[=:]?\$', caseSensitive: false).hasMatch(last) &&
        i == args.length &&
        fixed.length == args.length) {
      fixed.removeLast();
      how[k] = ParamHow('opt', last);
    }
  }
  return (fixed: fixed, how: how);
}

/// 固定启动参数：用空格分开，带空格的用引号括起来
List<String> toolSplitArgs(String text) => RegExp(r'"([^"]*)"|(\S+)').allMatches(text).map((m) => m.group(1) ?? m.group(2)!).toList();
String toolQuote(String a) => a.isEmpty || RegExp(r'\s').hasMatch(a) ? '"$a"' : a;

/// 程序收到的命令行长什么样（预览）：有默认值的用默认值，可选没默认值的放在 [ ] 里
String toolPreview(String entry, List<String> fixed, List<ParamRow> rows) {
  final parts = [entry.isEmpty ? '入口程序' : entry, ...fixed.map(toolQuote)];
  for (final r in rows) {
    final always = r.required || r.def.isNotEmpty;
    final v = r.def.isNotEmpty ? toolQuote(r.def) : '<${r.desc.isEmpty ? r.name : r.desc}>';
    final seg = r.how == 'flag'
        ? r.opt
        : r.how == 'pos'
            ? v
            : _attached(r.opt)
                ? r.opt + v
                : '${r.opt} $v';
    parts.add(always ? seg : '[$seg]');
  }
  return parts.join(' ');
}

/// 工具的风险（不填时显示默认）
String toolRiskText(Map<String, dynamic> x) {
  final risk = str(x['risk']);
  final r = risk.isNotEmpty ? risk : (x['type'] == 'zip' ? 'danger' : 'safe');
  return '${toolRisks[r]?.split('：').first ?? r}${risk.isEmpty ? '（默认）' : ''}';
}

/// 表单里填的内容
class ToolForm {
  String type = 'zip', name = '', title = '', category = '', desc = '';
  String entry = '', url = '', risk = '', mode = '', output = '', timeout = '', maxKb = '', headers = '', help = '';

  /// raw：自己写启动参数（高级）时的 args 文字（每行一段）；否则用 fixed（固定启动参数）+ 参数表生成
  bool raw = false;
  String argsText = '', fixed = '';
  List<ParamRow> rows = [];
  bool get zip => type == 'zip';

  /// 按已有的工具（或新建）填好表单；已有的启动参数拆得开就用参数表，拆不开就用“自己写”
  static ToolForm of(Map<String, dynamic> x) {
    final f = ToolForm()
      ..type = str(x['type']).isEmpty ? 'zip' : str(x['type'])
      ..name = str(x['name'])
      ..title = str(x['title'])
      ..category = str(x['category'])
      ..desc = str(x['desc'])
      ..entry = str(x['entry'])
      ..url = str(x['url'])
      ..risk = str(x['risk'])
      ..mode = str(x['mode'])
      ..output = str(x['output'])
      ..timeout = str(x['timeout'])
      ..maxKb = str(x['maxKb'])
      ..help = str(x['help'])
      ..headers = asMap(x['headers']).entries.map((e) => '${e.key}: ${e.value}').join('\n');
    final params = asMap(x['params']);
    final args = asList(x['args']).map(str).toList();
    final parsed = f.zip ? toolParseArgs(args, params) : null;
    f.raw = f.zip && parsed == null;
    f.argsText = args.join('\n');
    f.fixed = (parsed?.fixed ?? const <String>[]).map(toolQuote).join(' ');
    // 参数行按命令行里的顺序排（没用到的放后面）
    final order = parsed?.how.keys.toList() ?? <String>[];
    for (final k in [...order, ...params.keys.where((k) => !order.contains(k))]) {
      final p = asMap(params[k]);
      final h = parsed?.how[k];
      f.rows.add(ParamRow(
          name: k,
          desc: str(p['desc']),
          how: h?.how ?? (p['flag'] == true ? 'flag' : 'opt'),
          opt: h?.opt ?? '',
          def: str(p['default']),
          required: p['required'] == true,
          orig: p));
    }
    return f;
  }

  List<ParamRow> get namedRows => rows.where((r) => r.name.trim().isNotEmpty).toList();

  /// 生成好的启动参数
  List<String> get args => !zip
      ? const []
      : raw
          ? argsText.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
          : toolArgsFrom(toolSplitArgs(fixed), namedRows.where((r) => r.how == 'pos' || r.opt.trim().isNotEmpty).map(_trimmed).toList());

  static ParamRow _trimmed(ParamRow r) =>
      ParamRow(name: r.name.trim(), desc: r.desc.trim(), how: r.how, opt: r.opt.trim(), def: r.how == 'flag' ? '' : r.def, required: r.how != 'flag' && r.required, orig: r.orig);

  /// 表单下方实时显示的命令行
  String get preview => toolPreview(entry.trim(), toolSplitArgs(fixed), namedRows.where((r) => r.how == 'pos' || r.opt.trim().isNotEmpty).map(_trimmed).toList());

  /// 切到“自己写启动参数”：把现在参数表生成的写进去
  void toRaw() {
    argsText = args.join('\n');
    raw = true;
  }

  /// 改回用参数表：现在写的拆不开就返回 false
  bool toSimple() {
    final params = {for (final r in namedRows) r.name.trim(): r.how == 'flag' ? {'flag': true} : <String, dynamic>{}};
    final p = toolParseArgs(args, params);
    if (p == null) return false;
    fixed = p.fixed.map(toolQuote).join(' ');
    for (final r in rows) {
      final h = p.how[r.name.trim()];
      if (h != null) {
        r.how = h.how;
        r.opt = h.opt;
      }
    }
    raw = false;
    return true;
  }
}

/// 保存前的检查：有问题给 error；没问题给 SFU 要的 meta，confirms 是要用户再确认一下的提醒（都点“继续”才保存）
({Map<String, dynamic>? meta, String? error, List<String> confirms}) buildToolMeta(ToolForm f) {
  ({Map<String, dynamic>? meta, String? error, List<String> confirms}) err(String e) => (meta: null, error: e, confirms: const []);
  final name = f.name.trim(), desc = f.desc.trim(), entry = f.entry.trim(), url = f.url.trim(), output = f.output.trim(), mode = f.mode, risk = f.risk;
  if (!toolNameRe.hasMatch(name)) return err('名称只能用小写字母、数字、_、-，最长 64 位');
  if (desc.isEmpty) return err('请填写说明');
  if (f.zip && !toolEntryRe.hasMatch(entry)) return err('入口程序要是 .exe、.bat、.cmd 或 .ps1');
  if (!f.zip && !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return err('接口地址要以 http:// 或 https:// 开头');
  final rows = f.namedRows.map(ToolForm._trimmed).toList();
  final bad = rows.where((r) => !toolParamRe.hasMatch(r.name)).firstOrNull;
  if (bad != null) return err('参数名“${bad.name}”不行：只能用英文字母、数字、_、-（说明里可以写中文）');
  if (f.zip) {
    final rule = toolValueRule(risk, entry);
    final badDef = rows.where((r) => r.def.isNotEmpty && !rule.re.hasMatch(r.def)).firstOrNull;
    if (badDef != null) return err('参数“${badDef.name}”的默认值“${badDef.def}”不行：只能用${rule.text}');
  }
  final confirms = <String>[];
  final args = f.args;
  if (f.zip && !f.raw) {
    final r = rows.where((r) => r.how != 'pos' && r.opt.isEmpty).firstOrNull;
    if (r != null) return err('参数“${r.name}”要填“选项名”（比如 --${r.name}），程序靠它认出这是哪个参数；程序直接收值的话，“怎么传给程序”选“只传值”');
    final sp = rows.where((r) => RegExp(r'\s').hasMatch(r.opt)).firstOrNull;
    if (sp != null) return err('参数“${sp.name}”的选项名里不能有空格，只填选项本身（比如 --${sp.name}）');
  } else if (f.zip) {
    // 自己写的启动参数：参数登记了却没用到，AI 传了也到不了程序
    final text = args.join('\n');
    final unused = rows.where((r) => !text.contains('{${r.name}}') && !text.contains('?${r.name}:')).toList();
    if (unused.isNotEmpty) return err('参数 ${unused.map((r) => r.name).join('、')} 在启动参数里没用到，AI 传了值也到不了程序。请在启动参数里加上 {参数名}，或者删掉这个参数');
    final joined = args.where((a) => RegExp(r'^\S+\s+\{[\w-]+\}$').hasMatch(a)).firstOrNull;
    if (joined != null) confirms.add('启动参数“$joined”写在了一行里，程序会把它当成一整段收到（中间的空格不会分开），多数程序认不出来。一般应该分成两行。仍然这样保存吗？');
  }
  final meta = <String, dynamic>{'name': name, 'type': f.type, 'desc': desc};
  if (f.title.trim().isNotEmpty) meta['title'] = f.title.trim();
  final cat = cleanCategoryText(f.category);
  if (cat.isNotEmpty) meta['category'] = cat;
  if (f.zip) {
    meta['entry'] = entry;
    if (f.help.isNotEmpty) {
      if (!toolHelps.contains(f.help)) return err('帮助指令只能是 --help、-help、-h、help 之一');
      meta['help'] = f.help;
    }
    if (args.isNotEmpty) meta['args'] = args;
  } else {
    meta['url'] = url;
    final headers = <String, String>{};
    for (final line in f.headers.split('\n')) {
      final i = line.indexOf(':');
      if (i > 0) headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    if (headers.isNotEmpty) meta['headers'] = headers;
    if (f.maxKb.trim().isNotEmpty) {
      final n = num.tryParse(f.maxKb.trim());
      if (n == null || n <= 0) return err('最多读取要填正数');
      meta['maxKb'] = n;
    }
  }
  if (f.timeout.trim().isNotEmpty) {
    final n = num.tryParse(f.timeout.trim());
    if (n == null || n <= 0 || n > toolMaxTimeout) return err('超时要在 1 到 $toolMaxTimeout 秒之间');
    meta['timeout'] = n;
  }
  final params = <String, dynamic>{};
  for (final r in rows) {
    final p = Map<String, dynamic>.from(r.orig)..removeWhere((k, _) => const ['desc', 'default', 'required', 'flag'].contains(k));
    if (r.desc.isNotEmpty) p['desc'] = r.desc;
    if (r.def.isNotEmpty) p['default'] = r.def;
    if (r.required) p['required'] = true;
    if (r.how == 'flag') p['flag'] = true;
    params[r.name] = p;
  }
  if (params.isNotEmpty) meta['params'] = params;
  if (risk.isNotEmpty) meta['risk'] = risk;
  if (f.zip && mode.isNotEmpty) meta['mode'] = mode;
  if (f.zip && output.isNotEmpty && mode != 'interactive') {
    if (!RegExp(r'^\{(TMP|TOOLDIR)\}').hasMatch(output) && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(output)) {
      confirms.add('结果文件“$output”不是以 {TMP} 或 {TOOLDIR} 开头，会按助手程序自己的目录去找，多半找不到。仍然这样保存吗？');
    }
    meta['output'] = output;
  }
  // 显示窗口的工具：启动前临时目录就被删了，用不了 {TMP}
  if (f.zip && mode == 'interactive' && args.any((a) => a.contains('{TMP}'))) return err('“显示窗口”的工具用不了 {TMP}（程序启动时临时目录已经被删了），需要目录请改用 {TOOLDIR}');
  // 模板里用到的参数都要登记过
  final text = [...args, str(meta['url']), str(meta['output']), ...asMap(meta['headers']).values.map(str)].join('\n');
  final used = {
    ...RegExp(r'\{([A-Za-z0-9_-]+)\}').allMatches(text).map((m) => m.group(1)!),
    ...RegExp(r'\?([A-Za-z0-9_-]+):').allMatches(text).map((m) => m.group(1)!),
  };
  final missing = used.where((k) => k != 'TOOLDIR' && k != 'TMP' && !params.containsKey(k)).toList();
  if (missing.isNotEmpty) return err('用到了没登记的参数：${missing.join('、')}，请在“参数”里添加');
  return (meta: meta, error: null, confirms: confirms);
}

/// 和 listview.dart 的 cleanCategory 一样（这里不依赖界面文件）
String cleanCategoryText(String v) => v
    .replaceAll(RegExp(r'[\r\n\t]'), ' ')
    .replaceAll(RegExp(r'[\\／]'), '/')
    .split('/')
    .map((s) => s.trim())
    .map((s) => s.length > 30 ? s.substring(0, 30) : s)
    .where((s) => s.isNotEmpty)
    .take(2)
    .join('/');

/// 工具详情里要标红的两种常见错误：参数没用到；“选项 值”写在了一段里
({List<String> unused, List<String> joined}) toolArgProblems(Map<String, dynamic> x) {
  if (x['type'] != 'zip') return (unused: const [], joined: const []);
  final args = asList(x['args']).map(str).toList();
  final text = args.join('\n');
  return (
    unused: asMap(x['params']).keys.where((k) => !text.contains('{$k}') && !text.contains('?$k:')).toList(),
    joined: args.where((a) => RegExp(r'^[^\s{}?]+\s+\{[\w-]+\}$').hasMatch(a)).toList(),
  );
}
