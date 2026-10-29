// 和网吧经营管家后台通信：普通请求、实时返回（SSE）、上传附件（带进度）、下载附件
// 所有请求都有超时；实时返回 60 秒没有任何数据（服务端每 20 秒发一次心跳）就当连接断了
// 连接：先用配置里的参数调 /api/start（open），拿到“这台电脑”的标识和连接编号，之后每个请求带上；
// 后台重启过、编号失效时（错误以“连接已过期”开头）自动重新 open 再试一次
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

/// 接口返回的错误（message 是给用户看的中文）
class ApiError implements Exception {
  ApiError(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// 可以切换的 AI（Claude、Codex、DeepSeek）
class Harness {
  Harness({required this.id, required this.name, required this.desc, required this.available});
  final String id, name, desc;
  final bool available;
  factory Harness.fromJson(Map<String, dynamic> j) => Harness(id: str(j['id']), name: str(j['name']), desc: str(j['desc']), available: j['available'] == true);
}

/// 上传用的请求：服务端读多少就交多少，进度是真实的发送进度
class _UploadRequest extends http.BaseRequest {
  _UploadRequest(Uri url, this.bytes, this.onProgress) : super('POST', url) {
    contentLength = bytes.length;
  }
  final Uint8List bytes;
  final void Function(double)? onProgress;
  static const _chunk = 64 * 1024;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    for (var i = 0; i < bytes.length; i += _chunk) {
      final end = min(i + _chunk, bytes.length);
      yield bytes.sublist(i, end);
      onProgress?.call(end / bytes.length);
    }
  }
}

class NetbarApi {
  /// newClient：测试时可以换成假的后台
  NetbarApi(this.config, {http.Client Function()? newClient}) : _newClient = newClient ?? http.Client.new {
    _client = _newClient();
  }
  final NetbarOpsConfig config;
  final http.Client Function() _newClient;
  late final http.Client _client;

  static const requestTimeout = Duration(seconds: 20);
  // 打开连接时电脑上的 AI 助手可能要先启动，最多等一分多钟
  static const startTimeout = Duration(seconds: 100);

  /// /api/start 给的“这台电脑”标识和连接编号；没连上时为空
  String key = '';
  String conn = '';

  /// yx/cloud 连上后解密出的网吧号（“环境-网吧号”），没传网吧编号和名称时用来区分网吧记忆
  String startedBarKey = '';

  /// 每个请求都要带上的连接信息
  Map<String, dynamic> get connBody => {'mcpUrl': key, 'token': conn};

  bool get isOpen => conn.isNotEmpty;

  Future<void>? _opening;

  /// 按配置连上当前这台电脑（同时只发一次）；出错抛 ApiError
  Future<void> open() => _opening ??= _open().whenComplete(() => _opening = null);
  Future<void> _open() async {
    final d = _json(await _guard(
        _client.post(_uri('/api/start'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(config.startBody)), startTimeout));
    key = str(d['key']);
    conn = str(d['token']);
    if (config.isNewEnv && str(d['barId']).isNotEmpty) startedBarKey = '${str(d['env'])}-${str(d['barId'])}';
  }

  static bool _expired(ApiError e) => e.message.startsWith('连接已过期');

  /// 连接已过期：重新连上后再做一次
  Future<T> _retry<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on ApiError catch (e) {
      if (!_expired(e)) rethrow;
      await open();
      return f();
    }
  }
  static const downloadTimeout = Duration(seconds: 90);
  static const streamIdleTimeout = Duration(seconds: 60);

  Uri _uri(String path) => Uri.parse(config.baseUrl.replaceAll(RegExp(r'/+$'), '') + path);

  static String _errorOf(List<int> body, int status) {
    try {
      final e = str(asMap(jsonDecode(utf8.decode(body)))['error']);
      if (e.isNotEmpty) return e;
    } catch (_) {}
    return '请求失败（$status）';
  }

  Map<String, dynamic> _json(http.Response res) {
    if (res.statusCode >= 400) throw ApiError(_errorOf(res.bodyBytes, res.statusCode), res.statusCode);
    try {
      return asMap(jsonDecode(utf8.decode(res.bodyBytes)));
    } catch (_) {
      throw ApiError('服务器返回的内容看不懂，请稍后再试', res.statusCode);
    }
  }

  Future<T> _guard<T>(Future<T> f, Duration timeout) async {
    try {
      return await f.timeout(timeout);
    } on TimeoutException {
      throw ApiError('服务器没有响应，请检查网络后再试');
    } on ApiError {
      rethrow;
    } catch (_) {
      throw ApiError('连不上服务器，请检查网络');
    }
  }

  /// 普通接口：自动带上连接信息，出错抛 ApiError
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic> body = const {}]) => _retry(() async =>
      _json(await _guard(_client.post(_uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode({...connBody, ...body})), requestTimeout)));

  /// 不需要连接信息的查询（例如可用的 AI 列表）
  Future<Map<String, dynamic>> get(String path) async => _json(await _guard(_client.get(_uri(path)), requestTimeout));

  /// 实时返回的接口（/api/chat、/api/chat/attach）：逐条给出 (事件类型, 内容)
  /// 连接建立失败、接口报错、中途断开都抛 ApiError；cancel 完成时安静地结束
  Stream<(String, Map<String, dynamic>)> stream(String path, Map<String, dynamic> body, {Future<void>? cancel}) async* {
    // 连接已过期只会在一开始（还没收到任何内容）报出来，这时重新连上再发一次
    var got = false;
    try {
      await for (final ev in _stream(path, body, cancel: cancel)) {
        got = true;
        yield ev;
      }
    } on ApiError catch (e) {
      if (got || !_expired(e)) rethrow;
      await open();
      yield* _stream(path, body, cancel: cancel);
    }
  }

  Stream<(String, Map<String, dynamic>)> _stream(String path, Map<String, dynamic> body, {Future<void>? cancel}) async* {
    final req = http.Request('POST', _uri(path))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({...connBody, ...body});
    // 每个实时请求单独一个连接，断开时不影响别的请求
    final client = _newClient();
    var cancelled = false, idle = false;
    // 一段时间没有任何数据（连心跳都没有）就断开
    Timer? idleTimer;
    cancel?.then((_) {
      cancelled = true;
      idleTimer?.cancel();
      client.close();
    });
    void touch() {
      idleTimer?.cancel();
      if (cancelled) return;
      idleTimer = Timer(streamIdleTimeout, () {
        idle = true;
        client.close();
      });
    }

    try {
      final res = await _guard(client.send(req), requestTimeout);
      if (res.statusCode >= 400) throw ApiError(_errorOf(await res.stream.toBytes(), res.statusCode), res.statusCode);
      touch();
      var buf = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        touch();
        buf += chunk.replaceAll('\r\n', '\n');
        int i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          final block = buf.substring(0, i);
          buf = buf.substring(i + 2);
          String? event;
          final data = <String>[];
          for (final line in block.split('\n')) {
            if (line.startsWith('event:')) event = line.substring(6).trim();
            if (line.startsWith('data:')) data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
          }
          if (event == null) continue; // 心跳（: ping）
          Map<String, dynamic> d = {};
          try {
            d = asMap(jsonDecode(data.isEmpty ? '{}' : data.join('\n')));
          } catch (_) {}
          yield (event, d);
        }
      }
      if (idle && !cancelled) throw ApiError(_dropped);
    } on ApiError {
      if (!cancelled) rethrow;
    } catch (_) {
      // 自己断开的（切换对话、关闭）安静结束；其他情况是网络断了
      if (!cancelled) throw ApiError(_dropped);
    } finally {
      idleTimer?.cancel();
      client.close();
    }
  }

  static const _dropped = '和服务器的连接断开了，AI 可能还在处理，可以稍后重新打开这个对话查看最新内容';

  /// 上传一个附件，onProgress 报告 0~1 的真实发送进度；返回服务端给的附件信息
  Future<AttachmentInfo> upload(Uint8List bytes, String name, String group, {bool pasted = false, void Function(double)? onProgress, Future<void>? cancel}) =>
      _retry(() => _upload(bytes, name, group, pasted: pasted, onProgress: onProgress, cancel: cancel));
  Future<AttachmentInfo> _upload(Uint8List bytes, String name, String group, {bool pasted = false, void Function(double)? onProgress, Future<void>? cancel}) async {
    final req = _UploadRequest(_uri('/api/upload'), bytes, onProgress)
      ..headers.addAll({
        'X-Mcp-Url': key,
        'X-Mcp-Token': conn,
        'X-File-Name': Uri.encodeComponent(name),
        'X-Upload-Group': group,
        if (pasted) 'X-Pasted': '1',
      });
    final client = _newClient();
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      client.close();
    });
    try {
      // 大文件按 100KB/s 估算，至少给 60 秒
      final timeout = Duration(seconds: max(60, bytes.length ~/ (100 * 1024)));
      final res = await _guard(client.send(req).then(http.Response.fromStream), timeout);
      final data = _json(res);
      if (data['file'] == null) throw ApiError('上传失败（服务器没有返回附件信息）');
      return AttachmentInfo.fromJson(asMap(data['file']));
    } on ApiError {
      if (cancelled) throw ApiError('已取消');
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 下载附件的原文件（只有同一台机器能下载）
  Future<Uint8List> download(AttachmentInfo a) => _retry(() async {
        final res = await _guard(
            _client.post(_uri('/api/uploads/get'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({...connBody, 'group': a.group, 'id': a.id})),
            downloadTimeout);
        if (res.statusCode != 200) throw ApiError(_errorOf(res.bodyBytes, res.statusCode), res.statusCode);
        return res.bodyBytes;
      });

  /// 分享链接的网址
  String shareUrl(String id) => '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/share/$id';

  void close() => _client.close();
}
