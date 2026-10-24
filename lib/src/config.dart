// 组件的连接配置：对应网页版链接里的参数（mcp、token、网吧分组/名称/机位/IP、isclient、isdebug）
import 'package:flutter/foundation.dart';

/// 界面风格：桌面（Windows）、苹果（iOS）、安卓（Android）。不指定时按运行的平台自动选择
enum NetbarUiStyle { desktop, cupertino, material }

/// 远程运维聊天组件的配置
@immutable
class NetbarOpsConfig {
  const NetbarOpsConfig({
    required this.baseUrl,
    required this.mcpUrl,
    required this.token,
    this.netbarGroup = '',
    this.netbarName = '',
    this.netbarSeat = '',
    this.netbarIp = '',
    this.name = '',
    this.barId = '',
    this.isClient = false,
    this.isDebug = false,
    this.uiStyle,
  });

  /// 网吧经营管家后台的地址，例如 https://xxx.app.wbtun.com
  final String baseUrl;

  /// 远程机器的 MCP 地址和令牌（网页版链接里的 mcp、token）
  final String mcpUrl;
  final String token;

  /// 网吧分组、网吧名称、机位、IP（网页版链接里的 netbarGroup、netbarName、netbarSeat、netbarIp）
  final String netbarGroup;
  final String netbarName;
  final String netbarSeat;
  final String netbarIp;

  /// 旧链接只带 name（如“富贵测试组-远程部-WIN-20260917-192.168.11.110”）时传这个，会自动拆分
  final String name;

  /// 网吧编号；不传就用“分组/网吧名称”区分“这家网吧”的记忆
  final String barId;

  /// 自动执行模式（网页版 isclient=1）：所有操作直接执行，不弹确认
  final bool isClient;

  /// 调试模式（网页版 isdebug=1）：可以删除对话
  final bool isDebug;

  /// 指定界面风格；不填按平台自动选择
  final NetbarUiStyle? uiStyle;

  bool get isValid => mcpUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  /// 网吧属性：没传分组/名称/机位/IP 时从 name 里拆；机位还是空就用 MCP 地址最后一段
  Map<String, String> get netbar {
    var nb = {'netbarGroup': netbarGroup.trim(), 'netbarName': netbarName.trim(), 'netbarSeat': netbarSeat.trim(), 'netbarIp': netbarIp.trim()};
    if (nb.values.every((v) => v.isEmpty)) nb = splitName(name);
    if (nb['netbarSeat']!.isEmpty && mcpUrl.isNotEmpty) {
      final parts = mcpUrl.replaceAll(RegExp(r'/+$'), '').split('/');
      nb['netbarSeat'] = Uri.decodeComponent(parts.last);
    }
    return nb;
  }

  /// 页面上显示、发给后台的机器名称：分组-网吧-机位-IP
  String get machineName => netbarFields.map((k) => netbar[k]!).where((v) => v.isNotEmpty).join('-');

  /// “这家网吧”的标识：有网吧编号用编号，没有就用“分组/网吧名称”
  String get barKey {
    if (barId.trim().isNotEmpty) return barId.trim();
    final nb = netbar;
    if (nb['netbarName']!.isEmpty) return '';
    return [nb['netbarGroup']!, nb['netbarName']!].where((v) => v.isNotEmpty).join('/');
  }

  /// 页面上称呼这家网吧
  String get barName => netbar['netbarName']!.isNotEmpty ? netbar['netbarName']! : barKey;

  /// 每个请求都要带上的连接信息
  Map<String, dynamic> get connBody => {'mcpUrl': mcpUrl.trim(), 'token': token.trim()};

  /// 自动选择界面风格
  NetbarUiStyle resolveStyle(TargetPlatform platform) {
    if (uiStyle != null) return uiStyle!;
    switch (platform) {
      case TargetPlatform.iOS:
        return NetbarUiStyle.cupertino;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return NetbarUiStyle.material;
      default:
        return NetbarUiStyle.desktop;
    }
  }

  NetbarOpsConfig copyWith({bool? isDebug, NetbarUiStyle? uiStyle}) => NetbarOpsConfig(
        baseUrl: baseUrl,
        mcpUrl: mcpUrl,
        token: token,
        netbarGroup: netbarGroup,
        netbarName: netbarName,
        netbarSeat: netbarSeat,
        netbarIp: netbarIp,
        name: name,
        barId: barId,
        isClient: isClient,
        isDebug: isDebug ?? this.isDebug,
        uiStyle: uiStyle ?? this.uiStyle,
      );
}

const netbarFields = ['netbarGroup', 'netbarName', 'netbarSeat', 'netbarIp'];
const netbarNames = {'netbarGroup': '分组', 'netbarName': '网吧', 'netbarSeat': '机位', 'netbarIp': 'IP'};

final _ipRe = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// 旧链接的 name：最后一段是 IP 就拆成 IP，其余按前两个“-”拆成分组、网吧名称、机位
Map<String, String> splitName(String name) {
  final parts = name.split('-').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  var ip = '';
  if (parts.length > 1 && _ipRe.hasMatch(parts.last)) ip = parts.removeLast();
  if (parts.length >= 3) return {'netbarGroup': parts[0], 'netbarName': parts[1], 'netbarSeat': parts.sublist(2).join('-'), 'netbarIp': ip};
  if (parts.length == 2) return {'netbarGroup': '', 'netbarName': parts[0], 'netbarSeat': parts[1], 'netbarIp': ip};
  return {'netbarGroup': '', 'netbarName': '', 'netbarSeat': parts.isEmpty ? '' : parts[0], 'netbarIp': ip};
}
