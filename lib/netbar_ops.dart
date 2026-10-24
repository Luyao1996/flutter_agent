/// 网吧经营管家·远程运维聊天组件
///
/// 用法：`NetbarOpsView(config: NetbarOpsConfig(baseUrl: ..., mcpUrl: ..., token: ...))`
/// Windows 用桌面布局，iOS 用苹果的设计语言，Android 用 Material 设计语言。
library;

export 'src/config.dart';
export 'src/models.dart' show AttachmentInfo, SessionSummary;
export 'src/controller.dart' show ChatController;
export 'src/view.dart';
