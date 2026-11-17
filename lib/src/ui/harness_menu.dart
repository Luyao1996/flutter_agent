// 切换 AI 的三级菜单：AI → 模型 → 思考深度（和网页版一致）
// 电脑：级联菜单。鼠标移上去只展开下一级（不改变什么）；点哪一级就直接用它（后面没选的按默认），点完立刻收起
//       触摸屏点第一、二级时先不收起，把下一级展开，不然选不到模型和思考深度
// 手机：底部分级面板。点 AI 或模型立即生效并进入下一级，点思考深度生效并关闭；左上角返回上一级，点空白处关闭
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../harness.dart';
import 'adaptive.dart';

/// 按钮上的短说明：选过的模型和思考深度（都按默认时为空）
String harnessDetail(ChatController ctl) {
  final p = ctl.harnessPick;
  return [if (p.model.isNotEmpty) shortModel(p.model), if (p.effort.isNotEmpty) p.effort].join(' · ');
}

String harnessTooltip(ChatController ctl) {
  final h = ctl.harness;
  final p = ctl.harnessPick;
  return '处理问题的 AI：${h?.name ?? ''}，模型 ${p.model.isNotEmpty ? p.model : (h?.model.isNotEmpty == true ? '${h!.model}（默认）' : '默认')}，'
      '思考深度 ${p.effort.isEmpty ? 'default' : p.effort}。点击切换：点哪一项就直接用它，后面的按默认，下一条消息开始生效';
}

String _unavailable(Harness h) => !h.available ? '这台服务器上没有安装或没有登录' : '正在读取可用的模型…';
bool _usable(Harness h) => h.available && h.models.isNotEmpty;

/// 当前用的模型（选过的，没选就是默认的）
String _effectiveModel(ChatController ctl, Harness h) {
  final p = ctl.pickOf(h);
  return p.model.isNotEmpty ? p.model : h.model;
}

List<({String id, String desc})> _effortItems(Harness h, HarnessModel m) => [
      (id: '', desc: m.defaultEffort.isNotEmpty ? '默认用 ${m.defaultEffort}' : '不指定，用 ${h.name} 自己的默认'),
      for (final e in m.efforts) (id: e, desc: m.effortDescs[e] ?? ''),
    ];

// ---------- 电脑：级联菜单 ----------
/// 包住输入区工具栏上的“AI”按钮；builder 里拿到打开/收起菜单的回调
class HarnessMenuAnchor extends StatefulWidget {
  const HarnessMenuAnchor({super.key, required this.builder});
  final Widget Function(BuildContext context, VoidCallback toggle) builder;
  @override
  State<HarnessMenuAnchor> createState() => _HarnessMenuAnchorState();
}

class _HarnessMenuAnchorState extends State<HarnessMenuAnchor> {
  final _menu = MenuController();

  void _toggle() {
    final ctl = NetbarScope.read(context).controller;
    if (_menu.isOpen) return _menu.close();
    _menu.open();
    // 模型目录可能更新了（Codex 第一次读要几秒）：后台刷新一下
    ctl.loadHarnesses();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = NetbarScope.of(context).controller;
    final c = NetbarColors(context);
    final style = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(c.raised),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      side: WidgetStatePropertyAll(BorderSide(color: c.line)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(NT.rMd))),
      maximumSize: const WidgetStatePropertyAll(Size(340, 520)),
    );
    Widget title(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6), child: Text(t, style: TextStyle(fontSize: NT.fCaption, fontWeight: FontWeight.w700, color: c.muted)));
    Widget label(bool on, String name, {Widget? chip, String? sub, bool mono = false}) => ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 20, child: on ? Icon(Icons.check, size: 15, color: c.accentText) : null),
                Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: NT.fSmall, fontWeight: FontWeight.w600, color: on ? c.accentText : c.text))),
                if (chip != null) ...[const SizedBox(width: 6), chip],
              ]),
              if (sub != null && sub.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Text(sub,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: mono ? monoStyle(size: 11, color: c.muted) : TextStyle(fontSize: 11.5, color: c.muted))),
            ]),
          ),
        );
    Widget chip(String t, {bool mono = true}) => Container(
          constraints: const BoxConstraints(maxWidth: 140),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(6)),
          child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono ? monoStyle(size: 10.5, color: c.muted) : TextStyle(fontSize: 10.5, color: c.muted)),
        );

    List<Widget> efforts(Harness h, HarnessModel m) {
      final p = ctl.pickOf(h);
      final same = h.id == ctl.harnessId && m.id == _effectiveModel(ctl, h);
      return [
        title('思考深度'),
        for (final x in _effortItems(h, m))
          MenuItemButton(
            onPressed: () => ctl.setHarnessEffort(h, m, x.id),
            child: label(same && x.id == p.effort, x.id.isEmpty ? 'default' : x.id, sub: x.desc),
          ),
        if (m.efforts.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 4), child: Text('这个模型不能调思考深度', style: TextStyle(fontSize: 11.5, color: c.muted))),
      ];
    }

    List<Widget> models(Harness h) {
      final chosen = _effectiveModel(ctl, h);
      return [
        title('${h.name} 的模型'),
        for (final m in h.models)
          _ClickToPick(
            menu: _menu,
            onPick: () => ctl.setHarnessModel(h, m),
            child: SubmenuButton(
              menuStyle: style,
              menuChildren: efforts(h, m),
              child: label(m.id == chosen && h.id == ctl.harnessId, m.name, chip: m.id == h.model ? chip('默认', mono: false) : null, sub: m.name != m.id ? m.id : null, mono: true),
            ),
          ),
      ];
    }

    return MenuAnchor(
      controller: _menu,
      style: style,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        title('用哪个 AI 处理'),
        for (final h in ctl.harnesses)
          if (!_usable(h))
            MenuItemButton(onPressed: null, child: label(false, h.name, sub: _unavailable(h)))
          else
            _ClickToPick(
              menu: _menu,
              onPick: () => ctl.setHarness(h.id),
              child: SubmenuButton(
                menuStyle: style,
                menuChildren: models(h),
                // 名字后面显示这个 AI 现在用的模型
                child: label(h.id == ctl.harnessId, h.name, chip: _effectiveModel(ctl, h).isEmpty ? null : chip(_effectiveModel(ctl, h)), sub: h.desc),
              ),
            ),
      ],
      builder: (context, menu, _) => widget.builder(context, _toggle),
    );
  }
}

/// 让第一、二级“点一下就选中”：鼠标点完收起整个菜单；触摸屏点完不收起，由 SubmenuButton 自己展开下一级
/// 用 Listener 只旁听点击，不和 SubmenuButton 抢手势；鼠标只是划过不会改变选择
class _ClickToPick extends StatefulWidget {
  const _ClickToPick({required this.menu, required this.onPick, required this.child});
  final MenuController menu;
  final VoidCallback onPick;
  final Widget child;
  @override
  State<_ClickToPick> createState() => _ClickToPickState();
}

class _ClickToPickState extends State<_ClickToPick> {
  PointerDeviceKind? _down;
  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) => _down = (e.buttons & kPrimaryButton) != 0 || e.kind == PointerDeviceKind.touch ? e.kind : null,
        onPointerCancel: (_) => _down = null,
        onPointerUp: (e) {
          final kind = _down;
          _down = null;
          if (kind == null) return;
          // 等这次点击在菜单里处理完再动
          Future.microtask(() {
            widget.onPick();
            if (kind != PointerDeviceKind.touch && kind != PointerDeviceKind.stylus) widget.menu.close();
          });
        },
        child: widget.child,
      );
}

// ---------- 手机：分级面板 ----------
Future<void> showHarnessSheet(BuildContext context) async {
  final s = NetbarScope.read(context);
  final ctl = s.controller;
  if (ctl.harnesses.isEmpty) await ctl.loadHarnesses();
  if (!context.mounted) return;
  if (ctl.harnesses.isEmpty) return showToast(context, '没有取到可用的 AI 列表，请稍后再试');
  // 模型目录可能更新了：后台刷新一下，面板跟着变
  ctl.loadHarnesses();
  if (s.isCupertino) {
    return showCupertinoModalPopup<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => s.copyWith(
          child: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7, maxWidth: 560),
            decoration: BoxDecoration(color: CupertinoColors.systemBackground.resolveFrom(ctx), borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.antiAlias,
            child: const SafeArea(top: false, child: HarnessPanel()),
          ),
        ),
      )),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    useRootNavigator: false,
    builder: (ctx) => s.copyWith(
        child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7), child: const SafeArea(top: false, child: HarnessPanel()))),
  );
}

/// 分级面板的内容：第一级 AI、第二级模型、第三级思考深度
class HarnessPanel extends StatefulWidget {
  const HarnessPanel({super.key});
  @override
  State<HarnessPanel> createState() => _HarnessPanelState();
}

class _HarnessPanelState extends State<HarnessPanel> {
  String? _hid; // 正在看哪个 AI 的模型
  String? _mid; // 正在看哪个模型的思考深度

  @override
  Widget build(BuildContext context) {
    final s = NetbarScope.of(context);
    final ctl = s.controller;
    final c = NetbarColors(context);
    final h = ctl.harnesses.where((x) => x.id == _hid).firstOrNull;
    final m = h?.models.where((x) => x.id == _mid).firstOrNull;
    final level = h == null ? 0 : (m == null ? 1 : 2);

    Widget row({required bool on, required String title, String? sub, String? tag, bool enabled = true, bool more = false, required VoidCallback onTap}) {
      final col = !enabled ? c.faint : (on ? c.accentText : c.text);
      return Pressable(
        onTap: enabled ? onTap : null,
        label: title,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            SizedBox(width: 26, child: on ? Icon(s.isCupertino ? CupertinoIcons.checkmark_alt : Icons.check, size: 20, color: c.accentText) : null),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fBodyMobile + 1, fontWeight: FontWeight.w600, color: col))),
                if (tag != null) ...[const SizedBox(width: 6), Flexible(child: Tag(tag, color: c.muted))],
              ]),
              if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: NT.fSmall, color: c.muted)),
            ])),
            if (more) Icon(s.isCupertino ? CupertinoIcons.chevron_right : Icons.chevron_right, size: 18, color: c.faint),
          ]),
        ),
      );
    }

    final rows = <Widget>[];
    String title;
    if (level == 0) {
      title = '用哪个 AI 处理';
      for (final x in ctl.harnesses) {
        final model = _effectiveModel(ctl, x);
        rows.add(row(
          on: x.id == ctl.harnessId,
          title: x.name,
          tag: _usable(x) && model.isNotEmpty ? model : null,
          sub: _usable(x) ? x.desc : _unavailable(x),
          enabled: _usable(x),
          more: true,
          onTap: () {
            // 点一下：直接换成这个 AI（后面按默认），再展开它的模型，想细调可以接着点
            ctl.setHarness(x.id);
            setState(() => _hid = x.id);
          },
        ));
      }
    } else if (level == 1) {
      title = '${h!.name} 的模型';
      final chosen = _effectiveModel(ctl, h);
      for (final x in h.models) {
        rows.add(row(
          on: h.id == ctl.harnessId && x.id == chosen,
          title: x.name,
          tag: x.id == h.model ? '默认' : null,
          sub: x.name != x.id ? x.id : null,
          more: true,
          onTap: () {
            ctl.setHarnessModel(h, x);
            setState(() => _mid = x.id);
          },
        ));
      }
    } else {
      title = '思考深度';
      final p = ctl.pickOf(h);
      final same = h!.id == ctl.harnessId && m!.id == _effectiveModel(ctl, h);
      for (final x in _effortItems(h, m!)) {
        rows.add(row(
          on: same && x.id == p.effort,
          title: x.id.isEmpty ? 'default' : x.id,
          sub: x.desc,
          onTap: () {
            ctl.setHarnessEffort(h, m, x.id);
            Navigator.pop(context);
          },
        ));
      }
      if (m.efforts.isEmpty) rows.add(Padding(padding: const EdgeInsets.fromLTRB(42, 4, 16, 8), child: Text('这个模型不能调思考深度', style: TextStyle(fontSize: NT.fSmall, color: c.muted))));
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(level == 0 ? 16 : 4, s.isCupertino ? 10 : 0, 8, 4),
        child: Row(children: [
          if (level > 0)
            AIconButton(
                icon: s.isCupertino ? CupertinoIcons.back : Icons.arrow_back,
                tooltip: '返回上一级',
                onPressed: () => setState(() => level == 2 ? _mid = null : _hid = null)),
          Expanded(child: Text(title, style: const TextStyle(fontSize: NT.fTitle, fontWeight: FontWeight.w600))),
          AIconButton(icon: s.isCupertino ? CupertinoIcons.xmark : Icons.close, tooltip: '关闭', onPressed: () => Navigator.pop(context)),
        ]),
      ),
      if (level == 0) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 6), child: Text('点哪一项就直接用它，后面的按默认，下一条消息开始生效', style: TextStyle(fontSize: NT.fSmall, color: c.muted))),
      Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows))),
      const SizedBox(height: 8),
    ]);
  }
}
