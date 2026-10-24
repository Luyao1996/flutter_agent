// 跟着平台变的基础控件：主题隔离、颜色和尺寸、按钮、对话框、底部菜单、提示、整页面板
// iOS 用苹果的样式（提醒框、底部操作表、顶部提示条、推入整页、按下变淡），Android 用 Material 3，Windows 用桌面弹窗
// 组件嵌在别人的应用里用：宿主的输入框、按钮、列表等样式不能漏进来，只沿用宿主的亮/暗色、字体和背景色
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../controller.dart';
import '../services.dart';

/// 组件内共享：聊天逻辑、界面风格、朗读、语音输入、小提示显示在哪
class NetbarScope extends InheritedNotifier<ChatController> {
  const NetbarScope({super.key, required ChatController controller, required this.style, required this.reader, required this.dictation, required this.messengerKey, required super.child})
      : super(notifier: controller);
  final NetbarUiStyle style;
  final Reader reader;
  final Dictation dictation;

  /// 小提示（Snackbar）显示在组件自己的范围里，不跑到宿主应用的窗口底部
  final GlobalKey<ScaffoldMessengerState> messengerKey;

  ChatController get controller => notifier!;
  bool get isCupertino => style == NetbarUiStyle.cupertino;
  bool get isMaterial => style == NetbarUiStyle.material;
  bool get isDesktop => style == NetbarUiStyle.desktop;
  bool get isMobile => !isDesktop;

  NetbarScope copyWith({required Widget child, GlobalKey<ScaffoldMessengerState>? messengerKey}) =>
      NetbarScope(controller: controller, style: style, reader: reader, dictation: dictation, messengerKey: messengerKey ?? this.messengerKey, child: child);

  static NetbarScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NetbarScope>()!;

  /// 只取一次，不跟着刷新（按钮回调里、只用到不变内容的地方）
  static NetbarScope read(BuildContext context) => context.getInheritedWidgetOfExactType<NetbarScope>()!;
}

// ---------- 尺寸：统一的圆角和字号 ----------
class NT {
  static const rSm = 8.0, rMd = 12.0, rLg = 16.0;
  static const fCaption = 12.0, fSmall = 13.0, fBody = 14.0, fBodyMobile = 15.0, fTitle = 16.0;
  static const accent = Color(0xFF3B82F6);
  static const accentStrong = Color(0xFF2563EB);
  static const danger = Color(0xFFEF4444);
  static const warn = Color(0xFFF59E0B);
  static const ok = Color(0xFF10B981);
}

/// 组件自己的主题：只取宿主的亮/暗色、字体、背景色，其余（输入框、按钮、列表、对话框等样式）全部用组件自己的
ThemeData isolatedTheme(BuildContext host, NetbarUiStyle style) {
  final hostTheme = Theme.of(host);
  final hasMaterialHost = Localizations.of<MaterialLocalizations>(host, MaterialLocalizations) != null;
  final brightness = hasMaterialHost ? hostTheme.brightness : CupertinoTheme.brightnessOf(host);
  final dark = brightness == Brightness.dark;
  final hs = hostTheme.colorScheme;
  final sameBrightness = hasMaterialHost && hs.brightness == brightness;
  var scheme = ColorScheme.fromSeed(seedColor: NT.accent, brightness: brightness).copyWith(primary: dark ? const Color(0xFF60A5FA) : NT.accentStrong, onPrimary: Colors.white);
  if (sameBrightness) {
    // 背景跟宿主一致，嵌在宿主面板里不会出现一块颜色不一样的“洞”
    scheme = scheme.copyWith(
      surface: hs.surface,
      onSurface: hs.onSurface,
      onSurfaceVariant: hs.onSurfaceVariant,
      surfaceContainerLowest: hs.surfaceContainerLowest,
      surfaceContainerLow: hs.surfaceContainerLow,
      surfaceContainer: hs.surfaceContainer,
      surfaceContainerHigh: hs.surfaceContainerHigh,
      surfaceContainerHighest: hs.surfaceContainerHighest,
      outlineVariant: hs.outlineVariant,
    );
  }
  final desktop = style == NetbarUiStyle.desktop;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: hostTheme.textTheme.bodyMedium?.fontFamily,
    fontFamilyFallback: hostTheme.textTheme.bodyMedium?.fontFamilyFallback,
    platform: hostTheme.platform,
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    materialTapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: style == NetbarUiStyle.cupertino ? NoSplash.splashFactory : null,
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    dividerTheme: DividerThemeData(color: scheme.onSurface.withValues(alpha: .1), space: 1, thickness: 1),
    scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6), radius: const Radius.circular(3), thumbColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: .22))),
  );
}

/// 组件用到的颜色（在组件自己的主题里取）
class NetbarColors {
  NetbarColors(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark,
        scheme = Theme.of(context).colorScheme;
  final bool dark;
  final ColorScheme scheme;
  Color get accentText => dark ? const Color(0xFF60A5FA) : NT.accentStrong;
  Color get dangerText => dark ? const Color(0xFFF87171) : const Color(0xFFDC2626);
  Color get warnText => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
  Color get okText => dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
  Color get text => scheme.onSurface;
  Color get text2 => scheme.onSurface.withValues(alpha: .86);
  Color get muted => scheme.onSurface.withValues(alpha: .62);

  /// 只用于装饰（分隔点、占位图标），不用于要读的文字
  Color get faint => scheme.onSurface.withValues(alpha: .4);
  Color get line => scheme.onSurface.withValues(alpha: .1);
  Color get fill => scheme.onSurface.withValues(alpha: .05);
  Color get fill2 => scheme.onSurface.withValues(alpha: .08);
  Color get background => scheme.surface;

  /// 卡片、输入框、代码块的底色：比背景稍微凸起一点
  Color get card => Color.alphaBlend(scheme.onSurface.withValues(alpha: dark ? .06 : .035), scheme.surface);
  Color get codeBg => Color.alphaBlend(scheme.onSurface.withValues(alpha: dark ? .08 : .05), scheme.surface);
  Color get raised => dark ? Color.alphaBlend(Colors.white.withValues(alpha: .08), scheme.surface) : Colors.white;
}

const monoFont = 'monospace';
const monoFallback = ['Consolas', 'Menlo', 'SF Mono', 'Roboto Mono', 'Courier New', 'monospace'];
TextStyle monoStyle({double size = 12.5, Color? color}) => TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: size, color: color, height: 1.45);

// ---------- 可点的区域 ----------
/// 统一的“可以点”：iOS 按下变淡（没有水波纹），其他平台有水波纹；电脑上鼠标变小手、悬停有底色；带读屏标签
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, required this.onTap, this.onLongPress, this.label, this.radius = NT.rSm, this.hoverColor});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? label;
  final double radius;
  final Color? hoverColor;
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    Widget w;
    if (s.isCupertino) {
      w = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedOpacity(duration: const Duration(milliseconds: 120), opacity: _down ? .45 : 1, child: widget.child),
      );
    } else {
      w = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.radius),
          hoverColor: widget.hoverColor ?? NetbarColors(context).fill2,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          mouseCursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: widget.child,
        ),
      );
    }
    return Semantics(button: widget.onTap != null, label: widget.label, enabled: widget.onTap != null, child: w);
  }
}

// ---------- 按钮 ----------
enum BtnKind { primary, normal, danger, dangerFill, text }

class AButton extends StatelessWidget {
  const AButton({super.key, required this.label, required this.onPressed, this.icon, this.kind = BtnKind.normal, this.small = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final fontSize = s.isDesktop ? NT.fSmall : (small ? NT.fSmall : NT.fBody);
    final child = Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: fontSize + 2), const SizedBox(width: 5)],
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1)),
    ]);
    final (bg, fg, border) = switch (kind) {
      BtnKind.primary => (NT.accent, Colors.white, null),
      BtnKind.dangerFill => (NT.danger, Colors.white, null),
      BtnKind.danger => (Colors.transparent, c.dangerText, NT.danger.withValues(alpha: .45)),
      BtnKind.normal => (c.fill2, c.text2, c.line),
      BtnKind.text => (Colors.transparent, c.accentText, null),
    };
    if (s.isCupertino) {
      // iOS：高度至少 44（小按钮 36，但点击区域仍是 44）
      return CupertinoButton(
        padding: EdgeInsets.symmetric(horizontal: small ? 12 : 16, vertical: 0),
        minimumSize: Size(44, small ? 36 : 44),
        color: kind == BtnKind.primary || kind == BtnKind.dangerFill ? bg : (kind == BtnKind.normal ? c.fill2 : null),
        disabledColor: c.fill,
        borderRadius: BorderRadius.circular(small ? 9 : NT.rMd),
        onPressed: onPressed,
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: fontSize, color: onPressed == null ? c.faint : fg, fontWeight: FontWeight.w500),
          child: IconTheme.merge(data: IconThemeData(color: onPressed == null ? c.faint : fg), child: child),
        ),
      );
    }
    final h = s.isDesktop ? (small ? 30.0 : 34.0) : (small ? 36.0 : 44.0);
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, h)),
        maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 56)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: small || s.isDesktop ? 12 : 18)),
        tapTargetSize: s.isDesktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        // 在主题字体的基础上改字号，宿主设置的中文字体不会丢
        textStyle: WidgetStatePropertyAll((Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(fontSize: fontSize, fontWeight: FontWeight.w500)),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(s.isMaterial ? 20 : NT.rSm), side: border == null ? BorderSide.none : BorderSide(color: border))),
        backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.disabled) ? (bg == Colors.transparent ? null : c.fill) : bg),
        foregroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.disabled) ? c.faint : fg),
        overlayColor: WidgetStatePropertyAll(fg.withValues(alpha: .1)),
        mouseCursor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.disabled) ? SystemMouseCursors.forbidden : SystemMouseCursors.click),
      ),
      child: child,
    );
  }
}

/// 小图标按钮（消息下方的复制、朗读等）：手机上点击区域 44，图标本身小一些
class AIconButton extends StatelessWidget {
  const AIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.color, this.size = 17});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final base = color ?? NetbarColors(context).muted;
    final col = onPressed == null ? base.withValues(alpha: .35) : base;
    if (s.isCupertino) {
      return Semantics(
        button: true,
        label: tooltip,
        enabled: onPressed != null,
        child: CupertinoButton(padding: EdgeInsets.zero, minimumSize: const Size(44, 44), onPressed: onPressed, child: Icon(icon, size: size + 2, color: col)),
      );
    }
    final box = s.isDesktop ? 30.0 : 44.0;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: size, color: col),
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(box, box)),
        maximumSize: WidgetStatePropertyAll(Size(box, box)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: s.isDesktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
        iconSize: WidgetStatePropertyAll(size),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(s.isDesktop ? 6 : box / 2))),
        overlayColor: WidgetStatePropertyAll(base.withValues(alpha: .12)),
      ),
    );
  }
}

// ---------- 转圈 ----------
class ASpinner extends StatelessWidget {
  const ASpinner({super.key, this.size = 14});
  final double size;
  @override
  Widget build(BuildContext context) => NetbarScope.of(context).isCupertino
      ? CupertinoActivityIndicator(radius: size / 2)
      : SizedBox(width: size, height: size, child: const CircularProgressIndicator(strokeWidth: 2, color: NT.accent));
}

// ---------- 提示 ----------
/// 小提示：iOS 在顶部显示一个淡入淡出的提示条（iOS 没有 Snackbar），其他平台用组件自己范围内的 Snackbar
void showToast(BuildContext context, String message) {
  final s = NetbarScope.read(context);
  final duration = Duration(milliseconds: message.length > 30 ? 4500 : 2200);
  if (!s.isCupertino) {
    final m = s.messengerKey.currentState;
    if (m != null && m.mounted) {
      final width = MediaQuery.sizeOf(context).width;
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        // 宽屏时不要横跨整个窗口
        margin: s.isDesktop && width > 600 ? EdgeInsets.symmetric(horizontal: (width - 520) / 2, vertical: 16) : null,
      ));
      return;
    }
  }
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (ctx) => _ToastBanner(message: message, duration: duration, onDone: () => entry.remove()));
  overlay.insert(entry);
}

class _ToastBanner extends StatefulWidget {
  const _ToastBanner({required this.message, required this.duration, required this.onDone});
  final String message;
  final Duration duration;
  final VoidCallback onDone;
  @override
  State<_ToastBanner> createState() => _ToastBannerState();
}

class _ToastBannerState extends State<_ToastBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();
  @override
  void initState() {
    super.initState();
    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _a.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 16,
      right: 16,
      // 提示条只用来看，不挡住下面导航栏的按钮
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, -.4), end: Offset.zero).animate(CurvedAnimation(parent: _a, curve: Curves.easeOutCubic)),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: (dark ? const Color(0xFF2C2C2E) : Colors.white).withValues(alpha: .97),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6))],
                ),
                child: DefaultTextStyle(
                  style: TextStyle(fontSize: 14, color: dark ? Colors.white : Colors.black, decoration: TextDecoration.none, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                  child: Text(widget.message),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 对话框（都留在组件自己的范围里，不盖住宿主应用的其他部分） ----------
/// 确认框：iOS 用 CupertinoAlertDialog，其他用 AlertDialog。content 可以放更复杂的说明
Future<bool> confirmDialog(BuildContext context, {required String title, String? message, Widget? content, String ok = '确定', String cancel = '取消', bool destructive = false}) async {
  final s = NetbarScope.read(context);
  final body = content ?? (message == null ? null : Text(message));
  bool? r;
  if (s.isCupertino) {
    r = await showCupertinoDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => CupertinoAlertDialog(
              title: Text(title),
              content: body == null ? null : Padding(padding: const EdgeInsets.only(top: 8), child: body),
              actions: [
                CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel)),
                CupertinoDialogAction(isDestructiveAction: destructive, isDefaultAction: !destructive, onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
              ],
            ));
  } else {
    r = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => s.copyWith(
            child: AlertDialog(
              title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              scrollable: true,
              content: body == null
                  ? null
                  : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 14, height: 1.5), child: body)),
              actions: [
                AButton(label: cancel, kind: BtnKind.text, onPressed: () => Navigator.pop(ctx, false)),
                AButton(label: ok, kind: destructive ? BtnKind.dangerFill : BtnKind.primary, onPressed: () => Navigator.pop(ctx, true)),
              ],
            )));
  }
  return r == true;
}

/// 输入一段文字：取消返回 null
Future<String?> promptText(BuildContext context, {required String title, String? message, String initial = '', String hint = '', int maxLength = 500, bool multiline = false, String ok = '确定'}) async {
  final s = NetbarScope.read(context);
  final ctl = TextEditingController(text: initial);
  String? r;
  if (s.isCupertino) {
    r = await showCupertinoDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => CupertinoAlertDialog(
              title: Text(title),
              content: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(children: [
                  if (message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(message)),
                  CupertinoTextField(
                      controller: ctl,
                      autofocus: true,
                      placeholder: hint,
                      minLines: multiline ? 3 : 1,
                      maxLines: multiline ? 5 : 1,
                      inputFormatters: [LengthLimitingTextInputFormatter(maxLength)]),
                ]),
              ),
              actions: [
                CupertinoDialogAction(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(ok)),
              ],
            ));
  } else {
    r = await showDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => s.copyWith(
            child: AlertDialog(
              title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              scrollable: true,
              content: SizedBox(
                width: 420,
                child: Builder(
                    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (message != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(message, style: TextStyle(color: NetbarColors(ctx).muted))),
                          AField(
                              controller: ctl,
                              hint: hint,
                              maxLength: maxLength,
                              minLines: multiline ? 3 : 1,
                              maxLines: multiline ? 6 : 1,
                              autofocus: true,
                              onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v)),
                        ])),
              ),
              actions: [
                AButton(label: '取消', kind: BtnKind.text, onPressed: () => Navigator.pop(ctx)),
                AButton(label: ok, kind: BtnKind.primary, onPressed: () => Navigator.pop(ctx, ctl.text)),
              ],
            )));
  }
  ctl.dispose();
  return r;
}

/// 菜单项
class SheetAction<T> {
  const SheetAction(this.label, this.value, {this.icon, this.destructive = false, this.enabled = true, this.subtitle, this.checked = false});
  final String label;
  final T value;
  final IconData? icon;
  final bool destructive, enabled, checked;
  final String? subtitle;
}

/// 一组操作：iOS 用底部操作表，Android 用底部弹出面板，Windows 在按钮旁边弹出菜单（anchor 是按钮所在的区域）
Future<T?> actionSheet<T>(BuildContext context, {String? title, String? message, required List<SheetAction<T>> actions, Rect? anchor}) async {
  final s = NetbarScope.read(context);
  final c = NetbarColors(context);
  if (s.isCupertino) {
    return showCupertinoModalPopup<T>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => CupertinoActionSheet(
              title: title == null ? null : Text(title),
              message: message == null ? null : Text(message),
              actions: [
                for (final a in actions)
                  CupertinoActionSheetAction(
                    isDestructiveAction: a.destructive,
                    onPressed: a.enabled ? () => Navigator.pop(ctx, a.value) : () {},
                    child: Text(a.checked ? '✓ ${a.label}' : a.label, style: a.enabled ? null : TextStyle(color: CupertinoColors.inactiveGray.resolveFrom(ctx))),
                  ),
              ],
              cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            ));
  }
  if (s.isDesktop && anchor != null) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(anchor, Offset.zero & overlay.size);
    Widget row(SheetAction<T> a) => Row(children: [
          SizedBox(
              width: 22,
              child: a.checked ? Icon(Icons.check, size: 16, color: c.accentText) : (a.icon == null ? null : Icon(a.icon, size: 16, color: a.destructive ? c.dangerText : c.muted))),
          const SizedBox(width: 8),
          Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(a.label, style: TextStyle(fontSize: NT.fSmall, color: !a.enabled ? c.faint : a.destructive ? c.dangerText : c.text)),
            if (a.subtitle != null) Text(a.subtitle!, style: TextStyle(fontSize: NT.fCaption, color: c.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
        ]);
    return showMenu<T>(
      context: context,
      position: pos,
      useRootNavigator: false,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 340),
      items: [
        if (title != null || message != null)
          PopupMenuItem<T>(
            enabled: false,
            height: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (title != null) Text(title, style: TextStyle(fontSize: NT.fCaption, fontWeight: FontWeight.w700, color: c.muted)),
                if (message != null) Text(message, style: TextStyle(fontSize: NT.fCaption, color: c.muted)),
              ]),
            ),
          ),
        for (final a in actions) PopupMenuItem<T>(value: a.value, enabled: a.enabled, height: a.subtitle == null ? 36 : 48, child: row(a)),
      ],
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    useRootNavigator: false,
    constraints: s.isDesktop ? const BoxConstraints(maxWidth: 480) : null,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 4), child: Text(title, style: const TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600))),
          if (message != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(message, style: TextStyle(color: c.muted))),
          for (final a in actions)
            ListTile(
              enabled: a.enabled,
              leading: a.checked ? Icon(Icons.check, color: c.accentText) : (a.icon == null ? null : Icon(a.icon, color: a.destructive ? c.dangerText : c.text2)),
              title: Text(a.label, style: TextStyle(color: a.destructive ? c.dangerText : null)),
              subtitle: a.subtitle == null ? null : Text(a.subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, a.value),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    ),
  );
}

/// 一个控件在屏幕上占的区域（用来在按钮旁边弹出菜单）
Rect? rectOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
}

// ---------- 整页面板 ----------
/// 面板内容实际能用的宽度（组件嵌在宿主的窄侧边栏里时，比窗口窄得多）
class PanelWidth extends InheritedWidget {
  const PanelWidth({super.key, required this.width, required super.child});
  final double width;
  static double? of(BuildContext context) => context.getInheritedWidgetOfExactType<PanelWidth>()?.width;
  @override
  bool updateShouldNotify(PanelWidth old) => old.width != width;
}

Widget _panelBody(WidgetBuilder builder) => LayoutBuilder(builder: (ctx, box) => PanelWidth(width: box.maxWidth, child: Builder(builder: builder)));

/// 打开一个管理面板：手机上推入整页（iOS 带返回手势的导航栏，Android 带 AppBar），Windows 上是居中的大对话框
/// 都在组件自己的导航里打开：组件嵌在宿主的侧边栏里时，面板也留在侧边栏里
Future<T?> pushPanel<T>(BuildContext context, {required String title, required WidgetBuilder builder, List<Widget> Function(BuildContext)? actions, double width = 1000, double height = 720}) {
  final s = NetbarScope.read(context);
  // 面板有自己的小提示范围
  final messenger = GlobalKey<ScaffoldMessengerState>();
  Widget scoped(Widget child) => s.copyWith(messengerKey: messenger, child: ScaffoldMessenger(key: messenger, child: child));
  if (s.isCupertino) {
    return Navigator.of(context).push<T>(CupertinoPageRoute(
        builder: (ctx) => scoped(Builder(
            builder: (ctx) => CupertinoPageScaffold(
                  navigationBar: CupertinoNavigationBar(
                      middle: Text(title), previousPageTitle: '返回', trailing: actions == null ? null : Row(mainAxisSize: MainAxisSize.min, children: actions(ctx))),
                  child: SafeArea(child: Material(type: MaterialType.transparency, child: _panelBody(builder))),
                )))));
  }
  if (s.isMaterial) {
    return Navigator.of(context).push<T>(MaterialPageRoute(
        builder: (ctx) => scoped(Builder(
            builder: (ctx) => Scaffold(
                  appBar: AppBar(title: Text(title), actions: actions?.call(ctx)),
                  body: SafeArea(child: _panelBody(builder)),
                )))));
  }
  return showDialog<T>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => scoped(LayoutBuilder(
            builder: (ctx, box) => Dialog(
              clipBehavior: Clip.antiAlias,
              insetPadding: EdgeInsets.all(box.maxWidth < 700 ? 8 : 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NT.rLg)),
              child: SizedBox(
                width: width,
                height: height,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 10, 8),
                      child: Row(children: [
                        Expanded(child: Text(title, style: const TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600))),
                        ...?actions?.call(ctx),
                        AIconButton(icon: Icons.close, tooltip: '关闭', onPressed: () => Navigator.pop(ctx)),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(child: _panelBody(builder)),
                  ]),
                ),
              ),
            ),
          )));
}

// ---------- 表单里的小控件 ----------
/// 输入框的统一外观：明确写出所有边框，宿主的输入框主题漏不进来
InputDecoration fieldDecoration(BuildContext context, {String? label, String hint = '', bool dense = false, Widget? prefix}) {
  final c = NetbarColors(context);
  OutlineInputBorder b(Color col, [double w = 1]) => OutlineInputBorder(borderRadius: BorderRadius.circular(NT.rSm), borderSide: BorderSide(color: col, width: w));
  return InputDecoration(
    labelText: label,
    hintText: hint,
    hintStyle: TextStyle(color: c.muted),
    isDense: dense,
    filled: true,
    fillColor: c.card,
    prefixIcon: prefix,
    counterText: '',
    alignLabelWithHint: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 10 : 12),
    border: b(c.line),
    enabledBorder: b(c.line),
    disabledBorder: b(c.fill),
    focusedBorder: b(NT.accent.withValues(alpha: .7), 1.5),
    errorBorder: b(NT.danger),
    focusedErrorBorder: b(NT.danger, 1.5),
  );
}

/// 搜索框
class ASearchField extends StatelessWidget {
  const ASearchField({super.key, required this.onChanged, this.placeholder = '搜索'});
  final ValueChanged<String> onChanged;
  final String placeholder;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    if (s.isCupertino) return CupertinoSearchTextField(placeholder: placeholder, onChanged: onChanged);
    return TextField(
        onChanged: onChanged, style: const TextStyle(fontSize: NT.fBody), decoration: fieldDecoration(context, hint: placeholder, dense: true, prefix: const Icon(Icons.search, size: 18)));
  }
}

/// 分段切换（经验 / 背景知识、这家网吧 / 这台机器）
class ASegmented<T extends Object> extends StatelessWidget {
  const ASegmented({super.key, required this.value, required this.segments, required this.onChanged});
  final T value;
  final Map<T, String> segments;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    if (s.isCupertino) {
      return CupertinoSlidingSegmentedControl<T>(
          groupValue: value,
          children: {
            for (final e in segments.entries)
              e.key: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis))
          },
          onValueChanged: (v) {
            if (v != null) onChanged(v);
          });
    }
    return SegmentedButton<T>(
      segments: [for (final e in segments.entries) ButtonSegment(value: e.key, label: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis))],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (v) => onChanged(v.first),
      style: ButtonStyle(
        visualDensity: s.isDesktop ? VisualDensity.compact : VisualDensity.standard,
        textStyle: WidgetStatePropertyAll((Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(fontSize: NT.fSmall)),
        tapTargetSize: s.isDesktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
      ),
    );
  }
}

/// 表单输入框；maxLength 只限制长度，不显示“0/100”计数
class AField extends StatelessWidget {
  const AField(
      {super.key,
      required this.controller,
      this.label,
      this.hint = '',
      this.maxLines = 1,
      this.minLines,
      this.maxLength,
      this.mono = false,
      this.autofocus = false,
      this.expands = false,
      this.onSubmitted});
  final TextEditingController controller;
  final String? label;
  final String hint;
  final int? maxLines, minLines, maxLength;
  final bool mono, autofocus, expands;
  final ValueChanged<String>? onSubmitted;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final style = mono ? monoStyle(size: 13) : const TextStyle(fontSize: NT.fBody);
    final fmt = maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)];
    if (s.isCupertino) {
      final field = CupertinoTextField(
          controller: controller,
          placeholder: hint,
          maxLines: expands ? null : maxLines,
          minLines: expands ? null : minLines,
          inputFormatters: fmt,
          style: style.copyWith(color: NetbarColors(context).text),
          autofocus: autofocus,
          expands: expands,
          onSubmitted: onSubmitted,
          textAlignVertical: TextAlignVertical.top,
          padding: const EdgeInsets.all(10));
      if (label == null) return field;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: expands ? MainAxisSize.max : MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(label!, style: TextStyle(fontSize: NT.fSmall, color: NetbarColors(context).muted))),
        expands ? Expanded(child: field) : field,
      ]);
    }
    return TextField(
        controller: controller,
        maxLines: expands ? null : maxLines,
        minLines: expands ? null : minLines,
        inputFormatters: fmt,
        style: style,
        autofocus: autofocus,
        expands: expands,
        onSubmitted: onSubmitted,
        textAlignVertical: TextAlignVertical.top,
        decoration: fieldDecoration(context, label: label, hint: hint, dense: s.isDesktop));
  }
}

/// 空列表、加载中、出错时的居中提示
class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.loading = false, this.icon});
  final String text;
  final bool loading;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (loading) const ASpinner(size: 20) else if (icon != null) Icon(icon, size: 34, color: NetbarColors(context).faint),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: NetbarColors(context).muted, fontSize: NT.fSmall)),
          ]),
        ),
      );
}

/// 小标签（网吧属性、已分享、已停用）
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final c = color ?? NetbarColors(context).accentText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: c.withValues(alpha: .12), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 3)],
        Flexible(child: Text(text, style: TextStyle(fontSize: NT.fCaption, color: c), overflow: TextOverflow.ellipsis, maxLines: 1)),
      ]),
    );
  }
}
