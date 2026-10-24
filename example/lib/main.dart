// 示例：填上后台地址和远程机器的连接信息，运行后就是完整的远程运维聊天界面
// Windows 用桌面布局，iPhone 用苹果的设计语言，安卓手机用 Material 设计语言
import 'package:flutter/material.dart';
import 'package:netbar_ops/netbar_ops.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '远程运维',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6)),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6), brightness: Brightness.dark),
      home: const NetbarOpsView(
        config: NetbarOpsConfig(
          // 网吧经营管家后台地址
          baseUrl: 'https://e2e7eb00512d98de5d216730825b1499.app.wbtun.com',
          // 和网页版远程运维链接里的 mcp、token 一样
          mcpUrl: 'https://rtc2.03kan.com/mcp/替换成机器编号',
          token: '替换成令牌',
          netbarGroup: '富贵测试组',
          netbarName: '远程部',
          netbarSeat: 'WIN-20260917',
          netbarIp: '192.168.11.110',
        ),
      ),
    );
  }
}
