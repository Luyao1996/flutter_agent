// 逻辑测试：切换 AI 的模型和思考深度、进度条和处理过程、额度用完自动换 AI、目标模式
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netbar_ops/netbar_ops.dart';
import 'package:netbar_ops/src/api.dart';
import 'package:netbar_ops/src/goal.dart';
import 'package:netbar_ops/src/harness.dart';
import 'package:netbar_ops/src/progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_backend.dart';

const cfg = NetbarOpsConfig(baseUrl: 'http://fake', mcpUrl: 'https://rtc2.03kan.com/mcp/WIN-TEST', token: 'test-token-123', netbarName: '测试网吧');

Future<void> settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<(ChatController, FakeBackend)> started() async {
  final be = FakeBackend();
  final ctl = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
  await ctl.start();
  await settle();
  return (ctl, be);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('记住的模型、思考深度不在名单里当没选（比如以前选过的 Fable、Claude 的 max）', () {
    final models = [
      HarnessModel(id: 'claude-opus-5-5', name: 'claude-opus-5-5', efforts: ['low', 'medium', 'high']),
      HarnessModel(id: 'claude-haiku-5', name: 'claude-haiku-5'),
    ];
    expect(validPick('claude-opus-5-5', models, {'model': 'claude-fable-5', 'effort': 'high'}), (model: '', effort: 'high'));
    expect(validPick('claude-opus-5-5', models, {'model': '', 'effort': 'max'}), (model: '', effort: ''));
    expect(validPick('claude-opus-5-5', models, {'model': 'claude-haiku-5', 'effort': 'high'}), (model: 'claude-haiku-5', effort: ''));
    expect(validPick('claude-opus-5-5', models, null), (model: '', effort: ''));
    expect(shortModel('claude-opus-5-5'), 'opus-5-5');
    expect(shortModel('deepseek-flash'), 'flash');
  });

  test('三级选择：点哪一级就用哪一级，后面按默认；记住选择，发送时带上 model / effort', () async {
    final (ctl, be) = await started();
    expect(ctl.harnessId, 'claude');
    expect(ctl.harness!.models.length, 2);
    expect(ctl.harness!.model, 'claude-opus-5-5');
    final codex = ctl.harnesses[1];
    await ctl.setHarnessEffort(codex, codex.models[0], 'high');
    expect(ctl.harnessId, 'codex');
    // 选的是默认模型：不记具体名字（服务器换了默认模型也跟着换）
    expect(ctl.harnessPick, (model: '', effort: 'high'));
    await ctl.setHarnessModel(codex, codex.models[1]);
    expect(ctl.harnessPick, (model: 'gpt-5.1-codex', effort: ''));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('netbar_ops.harness'), 'codex');
    expect(jsonDecode(prefs.getString('netbar_ops.harnessPick')!)['codex'], {'model': 'gpt-5.1-codex', 'effort': ''});
    ctl.input.text = '看看网络';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last['harness'], 'codex');
    expect(be.chatBodies.last['model'], 'gpt-5.1-codex');
    expect(be.chatBodies.last['effort'], '');
    // 第一级：换 AI，模型和思考深度回到默认
    await ctl.setHarness('claude');
    expect(ctl.harnessPick, (model: '', effort: ''));
    // 重新打开：选择还在
    final ctl2 = ChatController(cfg, api: NetbarApi(cfg, newClient: be.client));
    await ctl2.start();
    await settle();
    expect(ctl2.pickOf(ctl2.harnesses[1]).model, 'gpt-5.1-codex');
    ctl.dispose();
    ctl2.dispose();
  });

  test('处理过程：思考、工具调用从记录里取，正在想的一段不进记录；进度条的一行', () async {
    final (ctl, be) = await started();
    be.withThinking = true;
    ctl.input.text = '电脑很卡';
    ctl.sendComposer();
    await settle(30);
    // 正在想的这一段只在进度条上
    expect(ctl.events.any((e) => e.e == 'thinking_delta'), isFalse);
    await settle();
    final t = ctl.path.single;
    final steps = thinkSteps(t);
    expect(steps.map((x) => x.type), ['think', 'tool']);
    expect(steps[1].state, 'ok');
    expect(steps[1].result, 'notepad 12%');
    final done = progressLine(running: false, ai: 'Claude', steps: steps, act: const RunAct());
    expect(done.title, '处理过程');
    expect(done.detail, '思考 1 段，调用工具 1 次：先看看进程列表，找出占用高的程序');
    ctl.dispose();
  });

  test('进度条文字：正在思考、正在调用工具（中文名称）、在等你确认、排队', () {
    final tool = ThinkStep.tool(id: 'a', name: 'mcp__remote__run_powershell', input: {'command': 'Get-Process'});
    expect(progressLine(running: true, ai: 'Claude', steps: [tool], act: const RunAct('tool')).title, 'Claude 正在执行 PowerShell 命令');
    expect(progressLine(running: true, ai: 'Claude', steps: [tool], act: const RunAct('tool')).detail, 'Get-Process');
    expect(progressLine(running: true, ai: 'Codex', steps: [ThinkStep.think('想一想', live: true)], act: const RunAct('work')).title, 'Codex 正在思考');
    expect(progressLine(running: true, ai: 'Claude', steps: [], act: const RunAct('wait', '', '结束进程：notepad.exe')).title, 'Claude 在等你确认');
    expect(progressLine(running: true, ai: 'Claude', steps: [], act: const RunAct('work', '排队中，前面还有 2 个对话…')).title, 'Claude 排队中，前面还有 2 个对话');
    expect(progressLine(running: true, ai: 'Claude', steps: [], act: const RunAct('work', 'AI 正在处理…')).title, 'Claude 正在处理');
    // 问诊工具按服务名认
    expect(toolLabel('mcp__diag__start'), '开问诊单');
    expect(toolLabel('mcp__diag__whatever'), '问诊');
    expect(toolLabel('mcp__kb__kb_search'), '查知识库');
    expect(toolLabel('unknown_tool'), 'unknown_tool');
    expect(fmtElapsed(const Duration(seconds: 75)), '1 分 15 秒');
  });

  test('额度用完、这一轮没做完：AI 自动换成 Codex；“重试”用新的 AI 重发，失败的那轮留在 1/2', () async {
    final (ctl, be) = await started();
    be.quotaFail = true;
    ctl.input.text = '修好菜单';
    ctl.sendComposer();
    await settle();
    expect(ctl.harnessId, 'codex');
    expect((await SharedPreferences.getInstance()).getString('netbar_ops.harness'), 'codex');
    final failed = ctl.path.single;
    expect(failed.events.any((e) => e.e == 'harness_switch' && e.d['retry'] == false), isTrue);
    await ctl.regenerate(failed);
    await settle();
    expect(be.chatBodies.last['harness'], 'codex');
    expect(be.chatBodies.last['message'], '修好菜单');
    expect(ctl.tree.siblings(ctl.path.single), [failed.id, ctl.path.single.id]);
    ctl.dispose();
  });

  test('目标模式：“/目标 内容”设定目标，一轮结束后倒数自动继续；暂停、继续、清除', () async {
    expect(parseGoalCommand('/目标 修好菜单'), '修好菜单');
    expect(parseGoalCommand('／goal  看看'), '看看');
    expect(parseGoalCommand('/目标'), '');
    expect(parseGoalCommand('目标 修好'), isNull);
    final (ctl, be) = await started();
    var opened = 0;
    ctl.goal.onOpenDialog = () => opened++;
    ctl.input.text = '/目标';
    ctl.sendComposer();
    expect(opened, 1);
    expect(be.chatBodies, isEmpty);

    ctl.input.text = '/目标 修好12号机的菜单';
    ctl.sendComposer();
    await settle();
    expect(be.chatBodies.last['message'], '修好12号机的菜单');
    expect(be.chatBodies.last['goal'], {'objective': '修好12号机的菜单', 'maxTurns': goalDefaultTurns});
    expect(ctl.goal.goal!.objective, '修好12号机的菜单');
    expect(ctl.goal.goal!.turnsUsed, 1);
    // 一轮结束：倒数几秒自动接着做
    expect(ctl.goal.counting, isTrue);
    // 已经有没完成的目标：不能再设新的
    ctl.input.text = '/目标 别的';
    ctl.sendComposer();
    expect(be.chatBodies.length, 1);
    ctl.input.text = '';

    await ctl.goal.pause();
    expect(ctl.goal.counting, isFalse);
    expect(ctl.goal.goal!.status, 'paused');
    // 继续：后台没有任务在跑，马上推进一轮（没有用户消息的“继续推进目标”）
    await ctl.goal.resume();
    await settle();
    expect(be.chatBodies.last['goalContinue'], isTrue);
    expect(ctl.path.last.kind, 'goal');
    expect(ctl.goal.goal!.turnsUsed, 2);
    ctl.goal.cancelAuto();

    await ctl.goal.clear();
    expect(ctl.goal.goal, isNull);
    expect(be.goalActions.map((a) => a['action']), ['pause', 'resume', 'clear']);
    ctl.dispose();
  });

  test('目标模式：打开旧对话时目标在进行中，先不自动推进；轮数用完停下', () async {
    final (ctl, be) = await started();
    be.goal = {'objective': '修好菜单', 'status': 'active', 'maxTurns': 1, 'turnsUsed': 0, 'timeUsedMs': 0};
    await ctl.openSession('session-9');
    expect(ctl.goal.goal!.active, isTrue);
    expect(ctl.goal.hold, isTrue);
    expect(ctl.goal.counting, isFalse);
    ctl.goal.continueNow();
    await settle();
    expect(ctl.goal.goal!.status, 'budget_limited');
    expect(ctl.goal.counting, isFalse);
    ctl.dispose();
  });
}
