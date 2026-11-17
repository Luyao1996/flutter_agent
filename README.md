# netbar_ops：网吧经营管家·远程运维聊天组件（Flutter）

把网页版“远程运维”的全部功能做成一个 Flutter 组件，支持 **Windows、iOS、Android**。组件直接连接现有的网吧经营管家后台，后台不用改。

## 三个平台的界面

| | Windows | iOS | Android |
|---|---|---|---|
| 顶栏 | 机器名、连接状态、一排功能按钮（技能、工具、知识库、记忆、分享、历史对话、新对话） | 苹果导航栏：左边“历史”，中间对话名称和机器，右边“新对话”和“…” | Material 顶栏：右边“新对话”和更多菜单 |
| 历史对话 | 右侧抽屉 | 推入的整页，长按一项改名/删除 | 左侧抽屉，长按一项改名/删除 |
| 菜单 | 弹出菜单 | 底部操作表（Action Sheet） | 底部弹出面板（Bottom Sheet） |
| 管理面板（知识库、技能、工具、记忆） | 居中大对话框，左边列表右边详情（默认打开第一条），右上角刷新、关闭 | 推入整页，点列表项再推入详情页；iPad 横屏左右两栏 | 推入整页，点列表项再推入详情页；平板左右两栏 |
| 输入区 | 和网页版一样的输入卡片；Enter 发送、Shift+Enter 换行；Ctrl+V 粘贴截图和文件；可以把文件拖进聊天区；空着按 ↑ 编辑上一条 | 左边圆形“＋”（拍照、相册、文件、@、技能、总结），中间圆角输入框，右边没字时是麦克风、有字时是发送；回车换行 | 同 iOS，Material 样式 |
| 消息操作 | 每条回复下方一排按钮；选中文字右键“引用” | 长按消息弹出操作表（复制、选择文字、引用、反馈、重新生成） | 同 iOS，底部弹出面板 |
| 提示 | Snackbar | 顶部淡入淡出的提示条（iOS 没有 Snackbar） | Snackbar |
| 确认框 | AlertDialog | CupertinoAlertDialog | AlertDialog |

## 功能（和网页版一致）

- 对话：AI 回复边生成边显示（末尾有闪烁的光标）；AI 处理中可以继续发送（排队），排队的可以“立即处理”；停止
- 切换处理问题的 AI（Claude / Codex / DeepSeek，列表来自后台 `/api/harnesses`），下一条消息开始生效，选择会记住
- 操作确认：允许 / 本次会话始终允许 / 拒绝；高危操作每次都要确认；自动执行模式（isClient）
- 新对话开始时选择“帮我检查这台电脑”或“我自己描述问题”；自动检查后列出发现的问题供选择
- 附件：图片、PDF、文本、Word/Excel/PPT；上传进度、失败原因；粘贴超过 2000 字自动变成文本附件；看大图、保存
- 每条消息：复制、点赞/点踩（可填原因）、重新生成、编辑后重新发送、版本切换 ‹ 1/2 ›、引用追问
- 重新生成或编辑前，如果被替换的内容里已经在机器上执行过操作，会先提醒
- @ 推荐经验、背景知识或选技能，模糊搜索；技能手动运行
- 语音输入：暂时关闭（不显示麦克风按钮）。代码保留，把 lib/src/ui/composer.dart 里的 `voiceInputEnabled` 改成 true 可以重新打开
- **语音通话（前台 + 主管）**：像打电话一样和 AI 说话，随时打断。全屏通话界面（声波球随状态变化、你和 AI 的最近几句话用气泡显示并自动淡出）；左上角“收起”回到聊天界面、通话不中断，输入栏上方会出现小状态条，可随时展开或结束；通话中能切换说话的声音、开关麦克风。要动电脑的事交给当前选中的 AI 处理，确认高危操作、派发任务、播报结果都和文字对话打通。手机和 PC 都支持（实时音频：`record` 采集 16kHz，`flutter_soloud` 播放 24kHz）
- **操作本网吧其他电脑（多机 toolbox）**：传了 `toolboxToken` 等参数后，AI 可以连接并操作本网吧的其他电脑；输入框上方显示已连接的电脑，可单独或全部断开；开新对话/关闭组件时自动断开。需要后台 v1.22.0 及以上
- 分享只读链接（手机上用系统分享面板发出去）
- 记忆（这家网吧 / 这台机器）、知识库、技能的管理
  - 知识库分“经验 | 资料库”两页（默认经验；以前的背景知识已在后台并进资料库）
  - 知识库、技能、工具的列表按分类折叠（最多两级，如“云启动/日志”，后面显示条数，展开状态记在本机）；搜索也搜内容和分类，标出命中的字和内容里命中的那一句；“筛选”里有排序、分组方式、网吧属性、来源、归属、紧凑模式，用了的条件显示成小标签，点 ✕ 去掉；可以“置顶”常用的条目（只在这台设备上）；新增、修改时可以填分类，技能上传 md 前先选分类
  - 用密码打开时每条前面标出属于哪一套（toolbox / 银杏 / 云启动 / 管理员）；不能改的（比如登录用户看管理员建的）不显示修改、删除，并说明原因
  - 每个管理面板右上角有刷新按钮，正在编辑没保存时先确认；电脑上的历史对话抽屉也有刷新按钮
- **工具库**（顶部“技能”旁的“工具”）：管理网吧电脑上 AI 能用的工具（存在 SFU 上，两台 SFU 可以切换）。查询、新增、修改、删除；zip 程序包上传（带进度）和下载；http_get 接口工具；参数填表（怎么传给程序、选项名，表单下方实时显示“程序收到的命令行”），帮助指令、风险、运行方式、结果文件用中文选项；参数默认值的字符限制按风险和入口提示；特殊情况可以“自己写启动参数”。链接带登录令牌时不用密码，没有时先输入 SFU 管理密码（只记在内存里，关掉组件就要重输）。只有上传那一边能修改、删除，管理员上传的只有用管理密码打开的能改；详情里显示“某某 最后上传”和是哪边上传的。接入方可以调 `openToolsPanel(context, name: '工具名')` 直接打开某个工具的详情
- **资料库**（知识库的第二页）：文件夹树（层级不限），每个文件夹的“⋯”菜单里能新建子文件夹、上传到这里、新建文档、重命名、编辑说明、移动、删除；右边是当前文件夹的内容，可以上传多个文件、整个文件夹（电脑上）或 zip（自动解压，保留里面的文件夹），电脑上也能把文件拖进来；勾选多项批量移动、删除；能看的文件直接预览（md 按格式、图片、PDF/Word/Excel 读出的文字），可以下载、置顶；搜索文件名和内容，点结果后标出命中的地方；能移到另一套资料的最外层（会先提醒谁能看到）。手机和小窗口里文件夹树收进左上角的“文件夹”按钮
- 历史对话：查看、接着问、改名、调试模式下删除
- 重新打开组件时回到刚才的对话；AI 正在处理时重新打开，会接上正在执行的任务；没发出去的文字会保留

## 接入

在你的 Flutter 项目的 `pubspec.yaml` 里引用：

```yaml
dependencies:
  netbar_ops:
    git:
      url: https://github.com/Luyao1996/flutter_agent.git
      ref: main
```

然后运行 `flutter pub get`。以后组件更新了，运行 `flutter pub upgrade netbar_ops`。

在一个页面里放上组件（它自带顶栏和输入区，直接作为整页使用）：

```dart
import 'package:netbar_ops/netbar_ops.dart';

Navigator.of(context).push(MaterialPageRoute(builder: (_) => NetbarOpsView(
  // 云启动 / yx 网吧（env=cloud 或 yx）：
  config: NetbarOpsConfig(
    baseUrl: 'https://你的网吧经营管家地址',   // 网吧经营管家后台
    env: 'cloud',                               // cloud 或 yx
    token: '银杏令牌',
    root: '网吧编号密文',                       // SFU 的 /mcp_bar/encrypt 加密得到
    branch: 'x002',                             // 座位号；空 = 网吧服务端
    // role: 'client',  // 这台电脑的角色：client 客户机（所有操作直接执行）、console 控制台、server 服务端（要确认）
    netbarName: '远程部',
  ),
)));

// toolbox（远程运维后台，不传 env 也一样）：参数和以前完全一样
NetbarOpsConfig(
  baseUrl: 'https://你的网吧经营管家地址',
  mcpUrl: 'https://rtc2.03kan.com/mcp/xxxx', // 和网页版链接里的 mcp 一样
  token: '令牌',                              // 和网页版链接里的 token 一样（MCP 令牌）
  netbarGroup: '富贵测试组', netbarName: '远程部', netbarSeat: 'WIN-20260917', netbarIp: '192.168.11.110',
  // isClient: true,  // 自动执行模式（网页版 isclient=1）
  // 操作本网吧其他电脑（多机）——和网页版链接里的 toolboxToken / merchant_id / sfuroom / sfuaddr 一一对应；
  // 不传 toolboxToken 就没有多机功能：
  // toolboxToken: 'admin 登录令牌', merchantId: '网吧编号', sfuRoom: '当前电脑房间号', sfuAddr: '中转服务器地址',
)
```

两种写法都可以加 `isDebug: true`（调试模式，网页版 isdebug=1，可以删除对话）。
组件打开时会先请后台验证令牌、连上这台电脑（yx/cloud 的 AI 助手没在运行时会先启动，可能要等几十秒），后台重启过也会自动重新连接。

- 界面风格默认按平台自动选择，也可以用 `uiStyle: NetbarUiStyle.cupertino` 等强制指定。
- 颜色跟随你的应用主题（亮色/暗色）。
- 只有旧链接里的 `name` 时，传 `name: '富贵测试组-远程部-WIN-20260917-192.168.11.110'`，会自动拆分。

## 连接参数从哪里来

`baseUrl` 是网吧经营管家后台地址，固定的：`https://e2e7eb00512d98de5d216730825b1499.app.wbtun.com`。其余按环境分两套：

**env=cloud / yx**（必填 `token`、`root`）：

| 参数 | 是什么 |
|---|---|
| `env` | `cloud`（云启动网吧）或 `yx` |
| `token` | 银杏令牌 |
| `root` | 网吧编号密文（SFU `/mcp_bar/encrypt` 加密得到） |
| `branch` | 座位号；空 = 网吧服务端 |
| `role` | 这台电脑的角色：`client` 客户机（所有操作直接执行）、`console` 控制台、`server` 服务端（这两种要确认）；不填按有没有座位号推断，要确认 |

**env=toolbox 或不传 env**（必填 `mcpUrl`、`token`，和以前一样）：

| 参数 | 是什么 | 从哪里来 |
|---|---|---|
| `mcpUrl` | 这台机器的远程运维地址，形如 `https://rtc2.03kan.com/mcp/机器编号` | 由 03kan 远程运维系统生成 |
| `token` | 连接这台机器用的令牌 | 由 03kan 远程运维系统生成 |

网页版是 03kan 网站在 iframe 里打开 `…/ops?mcp=…&token=…&netbarGroup=…&netbarName=…&netbarSeat=…&netbarIp=…`，这些参数是 03kan 那边拼好传进来的。
Flutter 应用里要用同样的值：找到 03kan 生成这个远程运维链接的地方（通常在 03kan 的后台接口里，客户端代码里不一定搜得到），从那里拿 `mcp` 和 `token`。网吧分组、名称、机位、IP 是可选的，有的话也一起传。

## 版本要求

- Flutter 3.38 及以上（Dart 3.10 及以上）。已在 Flutter 3.38.4 和 3.47.7 上验证过。
- 依赖的插件都放宽了版本范围，方便和你的项目共存。已经验证过“全部用最低版本”和“全部用最高版本”两种情况都能编译通过：

| 插件 | 支持的版本 |
|---|---|
| file_picker | 9.2.3 – 9.x（用 `FilePicker.platform` 的写法） |
| share_plus | 10.1.4 – 10.x（用 `Share.share` / `Share.shareXFiles` 的写法） |
| desktop_drop | 0.7.1 – 0.8.x |
| http | 1.1 – 1.x |
| shared_preferences | 2.2 – 2.x |
| image_picker | 1.0 – 1.x |
| image | 4.1 – 4.x |
| speech_to_text | 7.0 – 7.x |
| pasteboard | 0.3 – 0.x |
| cupertino_icons | 1.0.6 – 2.x |

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
- 组件里没有网页版的“亮色/暗色切换按钮”，亮暗、字体、背景色跟随你的应用主题；输入框、按钮、列表等其他样式由组件自己决定，不受宿主主题影响。
- 提示条、对话框、管理面板都在组件自己的范围里显示（嵌在侧边栏里时不会盖住整个窗口）。

## 示例

`example/` 里是一个最小的示例应用，填上后台地址和连接信息就能运行：

```bash
cd example
flutter run -d windows   # 或 -d ios / -d android
```
