// 切换 AI 的模型和思考深度（和网页版 ops.js“切换 AI、模型和思考深度”一致）
// 每个 AI 各记一份选择 {model, effort}；空字符串 = 默认（服务器设置的模型、AI 自己默认的思考深度）
// 能选哪些模型、思考深度由后台 /api/harnesses 给出（Claude 不给 Fable、不给 max，Codex 不给 ultra 都是后台定的），
// 记住的选择不在名单里就当没选
import 'models.dart';

/// 某个 AI 能选的一个模型
class HarnessModel {
  HarnessModel({required this.id, required this.name, this.efforts = const [], this.effortDescs = const {}, this.defaultEffort = ''});
  final String id, name, defaultEffort;

  /// 能选的思考深度（各 AI 自己的叫法：low、medium、high、xhigh…）
  final List<String> efforts;

  /// Codex 每一档自带的说明
  final Map<String, String> effortDescs;

  factory HarnessModel.fromJson(Map<String, dynamic> j) => HarnessModel(
        id: str(j['id']),
        name: str(j['name']).isEmpty ? str(j['id']) : str(j['name']),
        efforts: asList(j['efforts']).map(str).toList(),
        effortDescs: asMap(j['effortDescs']).map((k, v) => MapEntry(k, str(v))),
        defaultEffort: str(j['defaultEffort']),
      );
}

/// 处理这一轮的 AI 的名字（记录里只有编号；以前的记录没有，按 Claude）
const harnessNames = {'claude': 'Claude', 'codex': 'Codex', 'dsh': 'DeepSeek'};

/// 按钮上显示的短模型名：去掉 claude- / deepseek- 前缀
String shortModel(String id) => id.replaceFirst(RegExp(r'^claude-'), '').replaceFirst(RegExp(r'^deepseek-'), '');

/// 记住的选择里取出某个 AI 的模型和思考深度：模型不在名单里当没选，思考深度不在（选的或默认）模型的档位里当没选
({String model, String effort}) validPick(String defaultModel, List<HarnessModel> models, Map<String, dynamic>? saved) {
  final p = saved ?? const {};
  final m = models.where((x) => x.id == str(p['model'])).firstOrNull;
  final base = m ?? models.where((x) => x.id == defaultModel).firstOrNull;
  final e = str(p['effort']);
  return (model: m?.id ?? '', effort: base != null && base.efforts.contains(e) ? e : '');
}
