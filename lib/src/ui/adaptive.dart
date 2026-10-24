// 跟着平台变的基础控件：颜色、按钮、对话框、底部菜单、提示、整页面板
// iOS 用苹果的样式（提醒框、底部操作表、顶部提示条、推入整页），Android 用 Material 3，Windows 用桌面弹窗
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../controller.dart';
import '../services.dart';

/// 组件内共享：聊天逻辑、界面风格、朗读、语音输入
class NetbarScope extends InheritedNotifier<ChatController> {
  const NetbarScope({super.key, required ChatController controller, required this.style, required this.reader, required this.dictation, required super.child})
      : super(notifier: controller);
  final NetbarUiStyle style;
  final Reader reader;
  final Dictation dictation;

  ChatController get controller => notifier!;
  bool get isCupertino => style == NetbarUiStyle.cupertino;
  bool get isMaterial => style == NetbarUiStyle.material;
  bool get isDesktop => style == NetbarUiStyle.desktop;
  bool get isMobile => !isDesktop;

  static NetbarScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NetbarScope>()!;

  /// 只取一次，不跟着刷新（按钮回调里用）
  static NetbarScope read(BuildContext context) => context.getInheritedWidgetOfExactType<NetbarScope>()!;
}

/// 组件用到的颜色：跟着宿主应用的亮色 / 暗色主题
class NetbarColors {
  NetbarColors(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark,
        scheme = Theme.of(context).colorScheme;
  final bool dark;
  final ColorScheme scheme;
  static const accent = Color(0xFF3B82F6);
  static const accentStrong = Color(0xFF2563EB);
  static const danger = Color(0xFFEF4444);
  static const warn = Color(0xFFF59E0B);
  static const ok = Color(0xFF10B981);
  Color get accentText => dark ? const Color(0xFF60A5FA) : accentStrong;
  Color get dangerText => dark ? const Color(0xFFF87171) : const Color(0xFFDC2626);
  Color get warnText => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
  Color get okText => dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
  Color get text => scheme.onSurface;
  Color get text2 => scheme.onSurface.withValues(alpha: .8);
  Color get muted => scheme.onSurface.withValues(alpha: .55);
  Color get faint => scheme.onSurface.withValues(alpha: .38);
  Color get line => scheme.onSurface.withValues(alpha: .12);
  Color get fill => scheme.onSurface.withValues(alpha: .05);
  Color get bubble => dark ? const Color(0xFF17181B) : Colors.white;
  Color get codeBg => dark ? const Color(0xFF0B0C0E) : const Color(0xFFF4F5F7);
  Color get background => dark ? const Color(0xFF050505) : const Color(0xFFF4F5F7);
}

const monoFont = 'monospace';
const monoFallback = ['Consolas', 'Menlo', 'Courier New', 'monospace'];

// ---------- 按钮 ----------
enum BtnKind { primary, normal, danger, text }

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
    final child = Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: small ? 15 : 17), const SizedBox(width: 5)],
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
    ]);
    if (s.isCupertino) {
      final pad = EdgeInsets.symmetric(horizontal: small ? 12 : 16, vertical: small ? 6 : 10);
      final color = kind == BtnKind.danger ? CupertinoColors.destructiveRed : null;
      if (kind == BtnKind.primary) return CupertinoButton.filled(padding: pad, minimumSize: Size(0, small ? 32 : 44), onPressed: onPressed, child: child);
      return CupertinoButton(
          padding: pad,
          minimumSize: Size(0, small ? 32 : 44),
          onPressed: onPressed,
          child: DefaultTextStyle.merge(style: TextStyle(color: color, fontSize: small ? 14 : 16), child: IconTheme.merge(data: IconThemeData(color: color), child: child)));
    }
    final dense = s.isDesktop || small;
    final style = ButtonStyle(
      visualDensity: dense ? VisualDensity.compact : null,
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: dense ? 12 : 18, vertical: dense ? 6 : 10)),
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: dense ? 13 : 14, fontWeight: FontWeight.w500)),
    );
    switch (kind) {
      case BtnKind.primary:
        return FilledButton(
            style: style.copyWith(backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.disabled) ? null : NetbarColors.accent)),
            onPressed: onPressed,
            child: child);
      case BtnKind.danger:
        return OutlinedButton(style: style.copyWith(foregroundColor: WidgetStatePropertyAll(c.dangerText)), onPressed: onPressed, child: child);
      case BtnKind.text:
        return TextButton(style: style, onPressed: onPressed, child: child);
      case BtnKind.normal:
        return s.isMaterial ? FilledButton.tonal(style: style, onPressed: onPressed, child: child) : OutlinedButton(style: style, onPressed: onPressed, child: child);
    }
  }
}

/// 小图标按钮（消息下方的复制、朗读等）
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
    final c = color ?? NetbarColors(context).muted;
    if (s.isCupertino) {
      return CupertinoButton(
          padding: const EdgeInsets.all(6),
          minimumSize: const Size(34, 34),
          onPressed: onPressed,
          child: Icon(icon, size: size + 2, color: onPressed == null ? c.withValues(alpha: .3) : c));
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: size),
      color: c,
      visualDensity: s.isDesktop ? VisualDensity.compact : null,
      constraints: s.isDesktop ? const BoxConstraints(minWidth: 30, minHeight: 30) : null,
      padding: s.isDesktop ? const EdgeInsets.all(5) : null,
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
      : SizedBox(width: size, height: size, child: const CircularProgressIndicator(strokeWidth: 2, color: NetbarColors.accent));
}

// ---------- 提示 ----------
/// 小提示：iOS 在顶部显示一个淡入淡出的提示条（iOS 没有 Snackbar），其他平台用 Snackbar
void showToast(BuildContext context, String message) {
  final s = NetbarScope.read(context);
  if (!s.isCupertino) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m != null) {
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(
          content: Text(message), behavior: SnackBarBehavior.floating, duration: Duration(milliseconds: message.length > 30 ? 4500 : 2200), width: s.isDesktop ? 520 : null));
      return;
    }
  }
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (ctx) => _ToastBanner(message: message, onDone: () => entry.remove()));
  overlay.insert(entry);
}

class _ToastBanner extends StatefulWidget {
  const _ToastBanner({required this.message, required this.onDone});
  final String message;
  final VoidCallback onDone;
  @override
  State<_ToastBanner> createState() => _ToastBannerState();
}

class _ToastBannerState extends State<_ToastBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.message.length > 30 ? 4200 : 2000), () async {
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
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: (dark ? const Color(0xFF2C2C2E) : Colors.white).withValues(alpha: .96),
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
    );
  }
}

// ---------- 对话框 ----------
/// 确认框：iOS 用 CupertinoAlertDialog，其他用 AlertDialog。content 可以放更复杂的说明
Future<bool> confirmDialog(BuildContext context,
    {required String title, String? message, Widget? content, String ok = '确定', String cancel = '取消', bool destructive = false}) async {
  final s = NetbarScope.read(context);
  final body = content ?? (message == null ? null : Text(message));
  bool? r;
  if (s.isCupertino) {
    r = await showCupertinoDialog<bool>(
        context: context,
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
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: body == null ? null : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: SingleChildScrollView(child: body)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel)),
                FilledButton(
                  style: destructive ? FilledButton.styleFrom(backgroundColor: NetbarColors.danger) : FilledButton.styleFrom(backgroundColor: NetbarColors.accent),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ok),
                ),
              ],
            ));
  }
  return r == true;
}

/// 输入一段文字：取消返回 null
Future<String?> promptText(BuildContext context,
    {required String title, String? message, String initial = '', String hint = '', int maxLength = 500, bool multiline = false, String ok = '确定'}) async {
  final s = NetbarScope.read(context);
  final ctl = TextEditingController(text: initial);
  String? r;
  if (s.isCupertino) {
    r = await showCupertinoDialog<String>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
              title: Text(title),
              content: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(children: [
                  if (message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(message)),
                  CupertinoTextField(controller: ctl, autofocus: true, placeholder: hint, maxLength: maxLength, minLines: multiline ? 3 : 1, maxLines: multiline ? 5 : 1),
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
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 420,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (message != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(message)),
                  TextField(
                      controller: ctl,
                      autofocus: true,
                      maxLength: maxLength,
                      minLines: multiline ? 3 : 1,
                      maxLines: multiline ? 6 : 1,
                      decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
                      onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v)),
                ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                FilledButton(style: FilledButton.styleFrom(backgroundColor: NetbarColors.accent), onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(ok)),
              ],
            ));
  }
  ctl.dispose();
  return r;
}

/// 菜单项
class SheetAction<T> {
  const SheetAction(this.label, this.value, {this.icon, this.destructive = false, this.enabled = true, this.subtitle});
  final String label;
  final T value;
  final IconData? icon;
  final bool destructive, enabled;
  final String? subtitle;
}

/// 一组操作：iOS 用底部操作表，Android 用底部弹出面板，Windows 用小对话框（或在 anchor 处弹出菜单）
Future<T?> actionSheet<T>(BuildContext context, {String? title, String? message, required List<SheetAction<T>> actions, RelativeRect? anchor}) async {
  final s = NetbarScope.read(context);
  final c = NetbarColors(context);
  final items = actions.where((a) => a.enabled).toList();
  if (s.isCupertino) {
    return showCupertinoModalPopup<T>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
              title: title == null ? null : Text(title),
              message: message == null ? null : Text(message),
              actions: [for (final a in items) CupertinoActionSheetAction(isDestructiveAction: a.destructive, onPressed: () => Navigator.pop(ctx, a.value), child: Text(a.label))],
              cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            ));
  }
  if (s.isDesktop && anchor != null) {
    return showMenu<T>(context: context, position: anchor, items: [
      for (final a in items)
        PopupMenuItem<T>(
            value: a.value,
            height: 38,
            child: Row(children: [
              if (a.icon != null) ...[Icon(a.icon, size: 16, color: a.destructive ? c.dangerText : c.muted), const SizedBox(width: 10)],
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(a.label, style: TextStyle(fontSize: 13, color: a.destructive ? c.dangerText : null)),
                if (a.subtitle != null) Text(a.subtitle!, style: TextStyle(fontSize: 11, color: c.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
            ])),
    ]);
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: s.isDesktop ? const BoxConstraints(maxWidth: 480) : null,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(title, style: Theme.of(ctx).textTheme.titleMedium)),
          if (message != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(message, style: TextStyle(color: c.muted))),
          for (final a in items)
            ListTile(
              leading: a.icon == null ? null : Icon(a.icon, color: a.destructive ? c.dangerText : null),
              title: Text(a.label, style: TextStyle(color: a.destructive ? c.dangerText : null)),
              subtitle: a.subtitle == null ? null : Text(a.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, a.value),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    ),
  );
}

// ---------- 整页面板 ----------
/// 打开一个管理面板：手机上推入整页（iOS 带返回手势的导航栏，Android 带 AppBar），Windows 上是居中的大对话框
Future<T?> pushPanel<T>(BuildContext context,
    {required String title, required WidgetBuilder builder, List<Widget> Function(BuildContext)? actions, double width = 1000, double height = 720}) {
  final s = NetbarScope.read(context);
  Widget scoped(BuildContext ctx, Widget child) => NetbarScope(controller: s.controller, style: s.style, reader: s.reader, dictation: s.dictation, child: child);
  if (s.isCupertino) {
    return Navigator.of(context).push<T>(CupertinoPageRoute(
        builder: (ctx) => scoped(
            ctx,
            Builder(
                builder: (ctx) => CupertinoPageScaffold(
                      navigationBar: CupertinoNavigationBar(
                          middle: Text(title), previousPageTitle: '返回', trailing: actions == null ? null : Row(mainAxisSize: MainAxisSize.min, children: actions(ctx))),
                      child: SafeArea(child: Material(type: MaterialType.transparency, child: builder(ctx))),
                    )))));
  }
  if (s.isMaterial) {
    return Navigator.of(context).push<T>(MaterialPageRoute(
        builder: (ctx) => scoped(
            ctx,
            Builder(
                builder: (ctx) => Scaffold(
                      appBar: AppBar(title: Text(title), actions: actions?.call(ctx)),
                      body: SafeArea(child: builder(ctx)),
                    )))));
  }
  return showDialog<T>(
      context: context,
      builder: (ctx) => scoped(
          ctx,
          Builder(
              builder: (ctx) => Dialog(
                    clipBehavior: Clip.antiAlias,
                    insetPadding: const EdgeInsets.all(24),
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: ScaffoldMessenger(
                          child: Scaffold(
                        backgroundColor: Colors.transparent,
                        body: Column(children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                            child: Row(children: [
                              Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                              ...?actions?.call(ctx),
                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
                            ]),
                          ),
                          const Divider(height: 1),
                          Expanded(child: builder(ctx)),
                        ]),
                      )),
                    ),
                  ))));
}

// ---------- 表单里的小控件 ----------
/// 搜索框
class ASearchField extends StatelessWidget {
  const ASearchField({super.key, required this.onChanged, this.placeholder = '搜索'});
  final ValueChanged<String> onChanged;
  final String placeholder;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    if (s.isCupertino) return CupertinoSearchTextField(placeholder: placeholder, onChanged: onChanged);
    if (s.isMaterial) return SearchBar(hintText: placeholder, onChanged: onChanged, leading: const Icon(Icons.search), elevation: const WidgetStatePropertyAll(0));
    return TextField(
        onChanged: onChanged,
        decoration: InputDecoration(hintText: placeholder, prefixIcon: const Icon(Icons.search, size: 18), isDense: true, border: const OutlineInputBorder()));
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
          children: {for (final e in segments.entries) e.key: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(e.value))},
          onValueChanged: (v) {
            if (v != null) onChanged(v);
          });
    }
    return SegmentedButton<T>(
      segments: [for (final e in segments.entries) ButtonSegment(value: e.key, label: Text(e.value))],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (v) => onChanged(v.first),
      style: s.isDesktop ? const ButtonStyle(visualDensity: VisualDensity.compact) : null,
    );
  }
}

/// 表单输入框
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
      this.expands = false});
  final TextEditingController controller;
  final String? label;
  final String hint;
  final int? maxLines, minLines, maxLength;
  final bool mono, autofocus, expands;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final style = mono ? const TextStyle(fontFamily: monoFont, fontFamilyFallback: monoFallback, fontSize: 13) : null;
    if (s.isCupertino) {
      final field = CupertinoTextField(
          controller: controller,
          placeholder: hint,
          maxLines: expands ? null : maxLines,
          minLines: expands ? null : minLines,
          maxLength: maxLength,
          style: style,
          autofocus: autofocus,
          expands: expands,
          textAlignVertical: TextAlignVertical.top,
          padding: const EdgeInsets.all(10));
      if (label == null) return field;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: expands ? MainAxisSize.max : MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(label!, style: TextStyle(fontSize: 13, color: NetbarColors(context).muted))),
        expands ? Expanded(child: field) : field,
      ]);
    }
    return TextField(
        controller: controller,
        maxLines: expands ? null : maxLines,
        minLines: expands ? null : minLines,
        maxLength: maxLength,
        style: style,
        autofocus: autofocus,
        expands: expands,
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: s.isDesktop, alignLabelWithHint: true));
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
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: NetbarColors(context).muted, fontSize: 13)),
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
      decoration: BoxDecoration(color: c.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 11, color: c), const SizedBox(width: 3)],
        Flexible(child: Text(text, style: TextStyle(fontSize: 11, color: c), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
