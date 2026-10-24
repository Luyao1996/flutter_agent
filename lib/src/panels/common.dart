// 管理面板共用的小部件：宽屏左右两栏 / 手机推入详情页、列表项、筛选按钮、详情里的属性格子
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../ui/adaptive.dart';

/// 面板够宽（电脑、平板横屏）时左右两栏；窄的时候只显示列表，点开推入详情页
/// 按面板实际的宽度算，不按窗口：组件放在宿主 820 宽的侧边栏里时，面板也只有那么宽
bool isWide(BuildContext context) {
  final w = PanelWidth.of(context) ?? MediaQuery.sizeOf(context).width;
  return w >= (NetbarScope.read(context).isCupertino ? 900 : 700);
}

class TwoPane extends StatelessWidget {
  const TwoPane({super.key, required this.side, required this.detail});
  final Widget side, detail;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: ((PanelWidth.of(context) ?? 1000) * .36).clamp(260.0, 330.0), child: side),
        VerticalDivider(width: 1, color: NetbarColors(context).line),
        Expanded(child: detail),
      ]);
}

/// 列表里的一项：iOS 是分组列表的行（带右箭头），Android 是 ListTile，电脑是可选中的卡片
class ListRow extends StatelessWidget {
  const ListRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.chips = const [],
      this.meta,
      this.selected = false,
      this.dimmed = false,
      required this.onTap,
      this.onLongPress,
      this.trailing});
  final String title;
  final String? subtitle, meta;
  final List<Widget> chips;
  final bool selected, dimmed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: s.isMobile ? NT.fBodyMobile : NT.fBody, fontWeight: FontWeight.w500, color: dimmed ? c.muted : c.text)),
      if (subtitle != null && subtitle!.isNotEmpty)
        Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: s.isMobile ? NT.fSmall : NT.fCaption, color: c.muted)),
      if (chips.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Wrap(spacing: 4, runSpacing: 3, children: chips)),
      if (meta != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.faint))),
    ]);
    if (s.isCupertino) {
      return GestureDetector(
        onLongPress: onLongPress,
        child:
            CupertinoListTile(title: body, onTap: onTap, trailing: trailing ?? const CupertinoListTileChevron(), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      );
    }
    if (s.isMaterial) {
      // 宿主的 ListTile 主题（内边距、底色）不要漏进来
      return ListTile(
        title: body,
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: trailing,
        selected: selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        tileColor: Colors.transparent,
        selectedTileColor: NT.accent.withValues(alpha: .08),
        selectedColor: c.accentText,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? NT.accent.withValues(alpha: .1) : c.card,
          borderRadius: BorderRadius.circular(NT.rSm + 2),
          border: Border.all(color: selected ? NT.accent.withValues(alpha: .5) : c.line),
        ),
        child: Pressable(
          radius: NT.rSm + 2,
          onTap: onTap,
          onLongPress: onLongPress,
          label: title,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [Expanded(child: body), ?trailing]),
          ),
        ),
      ),
    );
  }
}

/// 把一组列表项包起来：iOS 用圆角分组列表，其他直接排列
class RowGroup extends StatelessWidget {
  const RowGroup({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    if (s.isCupertino) return CupertinoListSection.insetGrouped(margin: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: children);
    if (s.isMaterial)
      return Column(children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(height: 1, indent: 16), children[i]]
      ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// 筛选按钮：点开从一组值里选一个（iOS 是带边框的文字按钮 + 底部操作表，其他平台是小胶囊 + 菜单）
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.allLabel});
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final String? allLabel;
  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final c = NetbarColors(context);
    final active = value.isNotEmpty;
    final col = active ? c.accentText : c.text2;
    Future<void> open(BuildContext bctx) async {
      final r = await actionSheet<String>(bctx, title: '按$label筛选', anchor: rectOf(bctx), actions: [
        SheetAction(allLabel ?? '全部$label', '', checked: !active),
        for (final o in options) SheetAction(o, o, checked: o == value),
      ]);
      if (r != null) onChanged(r);
    }

    return Builder(
      builder: (bctx) => DecoratedBox(
        decoration: BoxDecoration(
          color: active ? NT.accent.withValues(alpha: .08) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? NT.accent.withValues(alpha: .5) : c.line),
        ),
        child: Pressable(
          radius: 999,
          onTap: () => open(bctx),
          label: '按$label筛选',
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: s.isMobile ? 8 : 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(s.isCupertino ? CupertinoIcons.line_horizontal_3_decrease : Icons.filter_list, size: 15, color: col),
              const SizedBox(width: 4),
              Flexible(child: Text(active ? value : (allLabel ?? '全部$label'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fCaption, color: col))),
              Icon(s.isCupertino ? CupertinoIcons.chevron_down : Icons.arrow_drop_down, size: s.isCupertino ? 12 : 16, color: col),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 详情里的属性格子（分组、网吧、机位、调用次数…）
class PropGrid extends StatelessWidget {
  const PropGrid(this.props, {super.key});
  final List<(String, String)> props;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(NT.rSm + 2), border: Border.all(color: c.line)),
      child: Wrap(spacing: 22, runSpacing: 10, children: [
        for (final (k, v) in props)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 110, maxWidth: 220),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.muted)),
              const SizedBox(height: 2),
              Text(v.isEmpty ? '—' : v,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(size: 13, color: c.text)),
            ]),
          ),
      ]),
    );
  }
}

/// 列表上方的一行按钮（新增、上传…）
class ToolbarRow extends StatelessWidget {
  const ToolbarRow({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Wrap(spacing: 8, runSpacing: 6, children: children));
}

/// 编辑表单的排版：空间够时正文输入框撑满剩下的高度；
/// 空间不够（手机上弹出键盘、横屏）时整个表单可以滚动，正文输入框给固定的行数，不会挤出界
class EditorLayout extends StatelessWidget {
  const EditorLayout({super.key, required this.top, required this.body, required this.bottom});
  final List<Widget> top, bottom;

  /// expands = true 时要撑满；false 时给固定行数
  final Widget Function(bool expands) body;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, box) {
        final roomy = box.maxHeight >= 460;
        final col = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: roomy ? MainAxisSize.max : MainAxisSize.min, children: [
          ...top,
          if (roomy) Expanded(child: body(true)) else body(false),
          ...bottom,
        ]);
        const pad = EdgeInsets.fromLTRB(20, 16, 20, 16);
        return roomy ? Padding(padding: pad, child: col) : SingleChildScrollView(padding: pad, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, child: col);
      });
}
