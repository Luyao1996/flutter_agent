// 管理面板共用的小部件：宽屏左右两栏 / 手机推入详情页、列表项、筛选按钮、详情里的属性格子
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../ui/adaptive.dart';

/// 宽屏（电脑、平板横屏）左右两栏；手机只显示列表，点开推入详情页
/// （iPad 横屏也用两栏，iPhone 一律推入详情页）
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= (NetbarScope.of(context).isCupertino ? 900 : 720);

class TwoPane extends StatelessWidget {
  const TwoPane({super.key, required this.side, required this.detail});
  final Widget side, detail;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 310, child: side),
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
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: s.isMobile ? 15 : 13, fontWeight: FontWeight.w500, color: dimmed ? c.muted : c.text)),
      if (subtitle != null && subtitle!.isNotEmpty)
        Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: s.isMobile ? 13 : 11.5, color: c.muted)),
      if (chips.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Wrap(spacing: 4, runSpacing: 3, children: chips)),
      if (meta != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.faint))),
    ]);
    if (s.isCupertino) {
      return GestureDetector(
        onLongPress: onLongPress,
        child:
            CupertinoListTile(title: body, onTap: onTap, trailing: trailing ?? const CupertinoListTileChevron(), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      );
    }
    if (s.isMaterial) return ListTile(title: body, onTap: onTap, onLongPress: onLongPress, trailing: trailing, selected: selected);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? NetbarColors.accent.withValues(alpha: .1) : c.fill,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: selected ? NetbarColors.accent.withValues(alpha: .5) : c.line)),
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

/// 筛选按钮：点开从一组值里选一个
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.allLabel});
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final String? allLabel;
  @override
  Widget build(BuildContext context) {
    final c = NetbarColors(context);
    final active = value.isNotEmpty;
    return ActionChip(
      label: Text(active ? value : (allLabel ?? '全部$label'), overflow: TextOverflow.ellipsis),
      avatar: Icon(Icons.filter_list, size: 15, color: active ? c.accentText : c.muted),
      labelStyle: TextStyle(fontSize: 12, color: active ? c.accentText : c.text2),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: active ? NetbarColors.accent.withValues(alpha: .5) : c.line),
      onPressed: () async {
        final box = context.findRenderObject() as RenderBox?;
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
        RelativeRect? anchor;
        if (box != null && overlay != null) {
          final p = box.localToGlobal(Offset.zero, ancestor: overlay);
          anchor = RelativeRect.fromLTRB(p.dx, p.dy + box.size.height, overlay.size.width - p.dx - box.size.width, 0);
        }
        final r = await actionSheet<String>(context, title: '按$label筛选', anchor: anchor, actions: [
          SheetAction(allLabel ?? '全部$label', ''),
          for (final o in options) SheetAction(o, o),
        ]);
        if (r != null) onChanged(r);
      },
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
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
      child: Wrap(spacing: 22, runSpacing: 10, children: [
        for (final (k, v) in props)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 110, maxWidth: 220),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c.muted)),
              const SizedBox(height: 2),
              Text(v.isEmpty ? '—' : v,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.text, fontFamily: monoFont, fontFamilyFallback: monoFallback)),
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
