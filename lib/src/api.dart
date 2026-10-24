// 和网吧经营管家后台通信：普通请求、实时返回（SSE）、上传附件（带进度）、下载附件
import 'dart:async';
import 'dart:convert';
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

class NetbarApi {
  /// newClient：测试时可以换成假的后台
  NetbarApi(this.config, {http.Client Function()? newClient}) : _newClient = newClient ?? http.Client.new {
    _client = _newClient();
  }
  final NetbarOpsConfig config;
  final http.Client Function() _newClient;
  late final http.Client _client;

  Uri _uri(String path) => Uri.parse(config.baseUrl.replaceAll(RegExp(r'/+$'), '') + path);

  /// 普通接口：自动带上连接信息，出错抛 ApiError
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic> body = const {}]) async {
    http.Response res;
    try {
      res = await _client.post(_uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode({...config.connBody, ...body}));
    } catch (e) {
      throw ApiError('连不上服务器，请检查网络');
    }
    Map<String, dynamic> data = {};
    try {
      data = asMap(jsonDecode(utf8.decode(res.bodyBytes)));
    } catch (_) {}
    if (res.statusCode >= 400) throw ApiError(str(data['error']).isEmpty ? '请求失败（${res.statusCode}）' : str(data['error']), res.statusCode);
    return data;
  }

  /// 实时返回的接口（/api/chat、/api/chat/attach）：逐条给出 (事件类型, 内容)
  /// 连接建立失败或接口报错时抛 ApiError；cancel 完成时断开
  Stream<(String, Map<String, dynamic>)> stream(String path, Map<String, dynamic> body, {Future<void>? cancel}) async* {
    final req = http.Request('POST', _uri(path))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({...config.connBody, ...body});
    // 每个实时请求单独一个连接，断开时不影响别的请求
    final client = _newClient();
    cancel?.then((_) => client.close());
    try {
      http.StreamedResponse res;
      try {
        res = await client.send(req);
      } catch (_) {
        throw ApiError('连不上服务器，请检查网络');
      }
      if (res.statusCode >= 400) {
        final text = await res.stream.bytesToString();
        String msg = '请求失败（${res.statusCode}）';
        try {
          msg = str(asMap(jsonDecode(text))['error']).isEmpty ? msg : str(asMap(jsonDecode(text))['error']);
        } catch (_) {}
        throw ApiError(msg, res.statusCode);
      }
      var buf = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        buf += chunk;
        int i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          final block = buf.substring(0, i);
          buf = buf.substring(i + 2);
          String? event;
          String? data;
          for (final line in block.split('\n')) {
            if (line.startsWith('event: ')) event = line.substring(7);
            if (line.startsWith('data: ')) data = line.substring(6);
          }
          if (event == null) continue;
          Map<String, dynamic> d = {};
          try {
            d = asMap(jsonDecode(data ?? '{}'));
          } catch (_) {}
          yield (event, d);
        }
      }
    } on ApiError {
      rethrow;
    } catch (_) {
      // 主动断开（切换对话、关闭页面）或网络中断：结束即可
    } finally {
      client.close();
    }
  }

  /// 上传一个附件，onProgress 报告 0~1 的进度；返回服务端给的附件信息
  Future<AttachmentInfo> upload(Uint8List bytes, String name, String group, {bool pasted = false, void Function(double)? onProgress, Future<void>? cancel}) async {
    final req = http.StreamedRequest('POST', _uri('/api/upload'))
      ..headers.addAll({
        'X-Mcp-Url': config.mcpUrl.trim(),
        'X-Mcp-Token': config.token.trim(),
        'X-File-Name': Uri.encodeComponent(name),
        'X-Upload-Group': group,
        if (pasted) 'X-Pasted': '1',
      })
      ..contentLength = bytes.length;
    final client = _newClient();
    cancel?.then((_) => client.close());
    final sending = client.send(req);
    // 分块写入，边写边报进度
    const chunk = 64 * 1024;
    for (var i = 0; i < bytes.length; i += chunk) {
      req.sink.add(bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk));
      onProgress?.call((i + chunk).clamp(0, bytes.length) / bytes.length);
      await Future<void>.delayed(Duration.zero);
    }
    unawaited(req.sink.close());
    try {
      final res = await http.Response.fromStream(await sending);
      Map<String, dynamic> data = {};
      try {
        data = asMap(jsonDecode(utf8.decode(res.bodyBytes)));
      } catch (_) {}
      if (res.statusCode != 200 || data['file'] == null) throw ApiError(str(data['error']).isEmpty ? '上传失败（${res.statusCode}）' : str(data['error']), res.statusCode);
      return AttachmentInfo.fromJson(asMap(data['file']));
    } on ApiError {
      rethrow;
    } catch (_) {
      throw ApiError('网络出错，上传失败');
    } finally {
      client.close();
    }
  }

  /// 下载附件的原文件（只有同一台机器能下载）
  Future<Uint8List> download(AttachmentInfo a) async {
    http.Response res;
    try {
      res = await _client.post(_uri('/api/uploads/get'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({...config.connBody, 'group': a.group, 'id': a.id}));
    } catch (_) {
      throw ApiError('连不上服务器，请检查网络');
    }
    if (res.statusCode != 200) {
      String msg = '下载失败';
      try {
        msg = str(asMap(jsonDecode(utf8.decode(res.bodyBytes)))['error']);
      } catch (_) {}
      throw ApiError(msg, res.statusCode);
    }
    return res.bodyBytes;
  }

  /// 分享链接的网址
  String shareUrl(String id) => '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/share/$id';

  void close() => _client.close();
}
