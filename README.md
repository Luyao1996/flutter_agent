# netbar_ops：网吧经营管家·远程运维聊天组件（Flutter）

把网页版“远程运维”的全部功能做成一个 Flutter 组件，支持 **Windows、iOS、Android**。组件直接连接现有的网吧经营管家后台，后台不用改。

## 三个平台的界面

| | Windows | iOS | Android |
|---|---|---|---|
| 顶栏 | 机器名、连接状态、一排功能按钮（技能、分享、记忆、知识库、历史对话、新对话） | 苹果导航栏：左边“历史”，中间对话名称和机器，右边“新对话”和“…” | Material 顶栏：右边“新对话”和更多菜单 |
| 历史对话 | 右侧抽屉 | 推入的整页，长按一项改名/删除 | 左侧抽屉，长按一项改名/删除 |
| 菜单 | 弹出菜单 | 底部操作表（Action Sheet） | 底部弹出面板（Bottom Sheet） |
| 管理面板（知识库、技能、记忆） | 居中大对话框，左边列表右边详情 | 推入整页，点列表项再推入详情页；iPad 横屏左右两栏 | 推入整页，点列表项再推入详情页；平板左右两栏 |
| 输入区 | 和网页版一样的输入卡片；Enter 发送、Shift+Enter 换行；Ctrl+V 粘贴截图和文件；可以把文件拖进聊天区；空着按 ↑ 编辑上一条 | 左边圆形“＋”（拍照、相册、文件、@、技能、总结），中间圆角输入框，右边没字时是麦克风、有字时是发送；回车换行 | 同 iOS，Material 样式 |
| 消息操作 | 每条回复下方一排按钮；选中文字右键“引用” | 长按消息弹出操作表（复制、选择文字、引用、朗读、反馈、重新生成） | 同 iOS，底部弹出面板 |
| 提示 | Snackbar | 顶部淡入淡出的提示条（iOS 没有 Snackbar） | Snackbar |
| 确认框 | AlertDialog | CupertinoAlertDialog | AlertDialog |

## 功能（和网页版一致）

- 对话：实时显示 AI 回复；AI 处理中可以继续发送（排队），排队的可以“立即处理”；停止
- 操作确认：允许 / 本次会话始终允许 / 拒绝；高危操作每次都要确认；自动执行模式（isClient）
- 新对话开始时选择“帮我检查这台电脑”或“我自己描述问题”；自动检查后列出发现的问题供选择
- 附件：图片、PDF、文本、Word/Excel/PPT；上传进度、失败原因；粘贴超过 2000 字自动变成文本附件；看大图、保存
- 每条消息：复制、朗读、点赞/点踩（可填原因）、重新生成、编辑后重新发送、版本切换 ‹ 1/2 ›、引用追问
- 重新生成或编辑前，如果被替换的内容里已经在机器上执行过操作，会先提醒
- @ 推荐经验、背景知识或选技能，模糊搜索；技能手动运行
- 语音输入（系统语音识别，插到光标处，不自动发送）
- 分享只读链接（手机上用系统分享面板发出去）
- 记忆（这家网吧 / 这台机器）、知识库、技能的管理
- 历史对话：查看、接着问、改名、调试模式下删除
- 重新打开组件时回到刚才的对话；AI 正在处理时重新打开，会接上正在执行的任务；没发出去的文字会保留

## 接入

在你的 Flutter 项目的 `pubspec.yaml` 里引用（按实际位置改路径）：

```yaml
dependencies:
  netbar_ops:
    path: ../netbar_ops_flutter
```

在一个页面里放上组件（它自带顶栏和输入区，直接作为整页使用）：

```dart
import 'package:netbar_ops/netbar_ops.dart';

Navigator.of(context).push(MaterialPageRoute(builder: (_) => NetbarOpsView(
  config: NetbarOpsConfig(
    baseUrl: 'https://你的网吧经营管家地址',   // 网吧经营管家后台
    mcpUrl: 'https://rtc2.03kan.com/mcp/xxxx', // 和网页版链接里的 mcp 一样
    token: '令牌',                              // 和网页版链接里的 token 一样
    netbarGroup: '富贵测试组', netbarName: '远程部', netbarSeat: 'WIN-20260917', netbarIp: '192.168.11.110',
    // isClient: true,  // 自动执行模式（网页版 isclient=1）
    // isDebug: true,   // 调试模式（网页版 isdebug=1），可以删除对话
  ),
)));
```

- 界面风格默认按平台自动选择，也可以用 `uiStyle: NetbarUiStyle.cupertino` 等强制指定。
- 颜色跟随你的应用主题（亮色/暗色）。
- 只有旧链接里的 `name` 时，传 `name: '富贵测试组-远程部-WIN-20260917-192.168.11.110'`，会自动拆分。

## 各平台需要的权限设置

**iOS**（`ios/Runner/Info.plist`）：

```xml
<key>NSMicrophoneUsageDescription</key><string>语音输入需要使用麦克风</string>
<key>NSSpeechRecognitionUsageDescription</key><string>语音输入需要使用语音识别</string>
<key>NSCameraUsageDescription</key><string>拍照发给 AI 需要使用相机</string>
<key>NSPhotoLibraryUsageDescription</key><string>从相册选图片发给 AI 需要访问相册</string>
```

**Android**（`android/app/src/main/AndroidManifest.xml`）：

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<queries>
  <intent><action android:name="android.speech.RecognitionService"/></intent>
  <intent><action android:name="android.speech.action.RECOGNIZE_SPEECH"/></intent>
</queries>
```

**Windows**：不需要额外设置。语音输入用的是 Windows 自带的语音识别，需要在系统设置里装好中文语音包。

## 已知限制

- 语音输入依赖系统的语音识别：很多国产安卓手机没有谷歌语音服务，需要用手机自带的语音识别；识别不到时会给出中文提示。
- 分享出去的链接用浏览器打开（分享页是网页）。
- 组件里没有网页版的“亮色/暗色切换按钮”，颜色跟随你的应用主题。
- 依赖的插件：http、shared_preferences、file_picker、image_picker、image、flutter_tts、speech_to_text、share_plus、desktop_drop、pasteboard、path_provider。

## 示例

`example/` 里是一个最小的示例应用，填上后台地址和连接信息就能运行：

```bash
cd example
flutter run -d windows   # 或 -d ios / -d android
```
