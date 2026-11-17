/// 网吧经营管家·远程运维聊天组件
///
/// 用法：`NetbarOpsView(config: NetbarOpsConfig(baseUrl: ..., env: 'cloud', token: ..., root: ..., branch: ...))`，
/// toolbox 照旧：`NetbarOpsConfig(baseUrl: ..., mcpUrl: ..., token: ...)`；toolbox 新格式：`env: 'toolbox', token: ..., root: ..., branch: ..., role: ...`（mcp 可不带）；
/// 口令远程：`NetbarOpsConfig(baseUrl: ..., env: 'pass', mcpUrl: ..., mcpToken: ...)`
/// Windows 用桌面布局，iOS 用苹果的设计语言，Android 用 Material 设计语言。
library;

export 'src/config.dart';
export 'src/models.dart' show AttachmentInfo, SessionSummary;
export 'src/controller.dart' show ChatController;
export 'src/connection.dart' show StartInfo, BorrowedBar, whoNames;
export 'src/view.dart';
