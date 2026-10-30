// 组件的连接配置：对应网页版链接里的参数
// env=yx / cloud：token（银杏令牌）、root（网吧编号密文）、branch（座位号，空 = 网吧服务端）、
//   role（这台电脑的角色：client 客户机——所有操作不用确认；console 控制台、server 服务端——要确认；不传按有没有座位号推断）
// env=toolbox 或不传 env：以前的参数——mcp、token（MCP 令牌）、isclient，多机另带 toolboxToken、merchant_id、sfuroom、sfuaddr
// 另有网吧分组/名称/机位/IP、isdebug。打开时由后台 /api/start 验证、连上（必要时启动）电脑，换回一个连接编号（见 api.dart）
import 'package:flutter/foundation.dart';

/// 界面风格：桌面（Windows）、苹果（iOS）、安卓（Android）。不指定时按运行的平台自动选择
enum NetbarUiStyle { desktop, cupertino, material }

/// 远程运维聊天组件的配置
@immutable
class NetbarOpsConfig {
  const NetbarOpsConfig({
    required this.baseUrl,
    this.env = '',
    this.mcpUrl = '',
    required this.token,
    this.root = '',
    this.branch = '',
    this.role = '',
    this.netbarGroup = '',
    this.netbarName = '',
    this.netbarSeat = '',
    this.netbarIp = '',
    this.name = '',
    this.barId = '',
    this.isClient = false,
    this.isDebug = false,
    this.toolboxToken = '',
    this.merchantId = '',
    this.sfuRoom = '',
    this.sfuAddr = '',
    this.uiStyle,
  });

  /// 网吧经营管家后台的地址，例如 https://xxx.app.wbtun.com
  final String baseUrl;

  /// 网吧环境：yx、cloud，或 toolbox（不填就是 toolbox）
  final String env;

  /// toolbox：远程机器的 MCP 地址和令牌（网页版链接里的 mcp、token）；yx/cloud：mcpUrl 不用填，token 是银杏令牌
  final String mcpUrl;
  final String token;

  /// yx/cloud：网吧编号密文（root）、座位号（branch，空 = 网吧服务端）、这台电脑的角色（role）：
  /// client 客户机（所有操作直接执行）、console 控制台、server 服务端（要确认）；不传按有没有座位号推断，要确认
  final String root;
  final String branch;
  final String role;

  /// 网吧分组、网吧名称、机位、IP（网页版链接里的 netbarGroup、netbarName、netbarSeat、netbarIp）
  final String netbarGroup;
  final String netbarName;
  final String netbarSeat;
  final String netbarIp;

  /// 旧链接只带 name（如“富贵测试组-远程部-WIN-20260917-192.168.11.110”）时传这个，会自动拆分
  final String name;

  /// 网吧编号；不传就用“分组/网吧名称”区分“这家网吧”的记忆
  final String barId;

  /// toolbox 的自动执行模式（网页版 isclient=1）：所有操作直接执行，不弹确认；yx/cloud 用 role
  final bool isClient;

  /// 调试模式（网页版 isdebug=1）：可以删除对话
  final bool isDebug;

  /// 操作本网吧其他电脑（网页版链接里的 toolboxToken、merchant_id、sfuroom、sfuaddr）：
  /// admin 登录令牌、网吧编号、当前电脑的房间号、中转服务器地址。不传 toolboxToken 就没有多机功能。
  final String toolboxToken;
  final String merchantId;
  final String sfuRoom;
  final String sfuAddr;

  /// 指定界面风格；不填按平台自动选择
  final NetbarUiStyle? uiStyle;

  /// yx/cloud 用新参数，其余（toolbox、不填）用以前的参数
  bool get isNewEnv => env.trim() == 'yx' || env.trim() == 'cloud';

  bool get isValid => isNewEnv ? token.trim().isNotEmpty && root.trim().isNotEmpty : mcpUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  /// 自动执行模式：所有操作直接执行，不弹确认（后台按 /api/start 时的参数为准）
  bool get autoRun => isNewEnv ? role.trim() == 'client' : isClient;

  /// 能不能操作本网吧其他电脑：yx/cloud 都能；toolbox 要传 toolboxToken
  bool get hasMulti => isNewEnv || toolboxToken.trim().isNotEmpty;

  /// 打开时交给后台 /api/start 的连接参数（和网页版链接参数同名）
  Map<String, dynamic> get startBody => isNewEnv
      ? {'env': env.trim(), 'token': token.trim(), 'root': root.trim(), 'branch': branch.trim(), if (role.trim().isNotEmpty) 'role': role.trim()}
      : {
          'env': 'toolbox',
          'mcp': mcpUrl.trim(),
          'token': token.trim(),
          if (isClient) 'isclient': '1',
          if (toolboxToken.trim().isNotEmpty) ...{
            'toolboxToken': toolboxToken.trim(),
            'merchant_id': merchantId.trim(),
            'sfuroom': sfuRoom.trim(),
            'sfuaddr': sfuAddr.trim(),
          },
        };

  /// 在本机记住草稿、当前对话时用的“这台电脑”标识
  String get storeKey => isNewEnv ? '${env.trim()}/${root.trim()}/${branch.trim()}' : mcpUrl.trim();

  /// 网吧属性：没传分组/名称/机位/IP 时从 name 里拆；机位还是空就用 MCP 地址最后一段
  Map<String, String> get netbar {
    var nb = {'netbarGroup': netbarGroup.trim(), 'netbarName': netbarName.trim(), 'netbarSeat': netbarSeat.trim(), 'netbarIp': netbarIp.trim()};
    if (nb.values.every((v) => v.isEmpty)) nb = splitName(name);
    if (nb['netbarSeat']!.isEmpty && isNewEnv) nb['netbarSeat'] = branch.trim().isEmpty || role.trim() == 'server' ? '服务端' : branch.trim();
    if (nb['netbarSeat']!.isEmpty && mcpUrl.isNotEmpty) {
      final parts = mcpUrl.replaceAll(RegExp(r'/+$'), '').split('/');
      nb['netbarSeat'] = Uri.decodeComponent(parts.last);
    }
    return nb;
  }

  /// 页面上显示、发给后台的机器名称：分组-网吧-机位-IP
  String get machineName => netbarFields.map((k) => netbar[k]!).where((v) => v.isNotEmpty).join('-');

  /// “这家网吧”的标识：有网吧编号用编号，没有就用“分组/网吧名称”（都没有时 yx/cloud 连上后用“环境-网吧号”，见 ChatController.barKey）
  String get barKey {
    if (barId.trim().isNotEmpty) return barId.trim();
    final nb = netbar;
    if (nb['netbarName']!.isEmpty) return '';
    return [nb['netbarGroup']!, nb['netbarName']!].where((v) => v.isNotEmpty).join('/');
  }

  /// 页面上称呼这家网吧
  String get barName => netbar['netbarName']!.isNotEmpty ? netbar['netbarName']! : barKey;

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
        env: env,
        mcpUrl: mcpUrl,
        token: token,
        root: root,
        branch: branch,
        role: role,
        netbarGroup: netbarGroup,
        netbarName: netbarName,
        netbarSeat: netbarSeat,
        netbarIp: netbarIp,
        name: name,
        barId: barId,
        isClient: isClient,
        isDebug: isDebug ?? this.isDebug,
        toolboxToken: toolboxToken,
        merchantId: merchantId,
        sfuRoom: sfuRoom,
        sfuAddr: sfuAddr,
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
