// 管理面板用的选文件、上传：资料库（多个文件、整个文件夹、zip）、知识库 zip、工具库程序包
// 大文件不整个读进内存：有路径的边读边传
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../api.dart';

/// 选到的一个文件；relPath 是上传文件夹时带着子文件夹的相对路径（其他时候就是文件名）
class PanelFile {
  PanelFile({required this.name, required this.size, this.path, this.bytes, String? relPath}) : relPath = relPath ?? name;
  final String name, relPath;
  final int size;
  final String? path;
  final Uint8List? bytes;
  bool get isZip => name.toLowerCase().endsWith('.zip');
  Stream<List<int>> open() => bytes != null ? Stream.value(bytes!) : File(path!).openRead();
  Future<Uint8List> read() async => bytes ?? await File(path!).readAsBytes();
}

/// 选文件（extensions 为空 = 什么文件都行）
Future<List<PanelFile>> pickPanelFiles({List<String>? extensions, bool multiple = true}) async {
  final r = await FilePicker.platform.pickFiles(
      type: extensions == null ? FileType.any : FileType.custom, allowedExtensions: extensions, allowMultiple: multiple, withData: kIsWeb);
  return [
    for (final f in r?.files ?? const <PlatformFile>[])
      if (f.bytes != null || f.path != null) PanelFile(name: f.name, size: f.size, path: kIsWeb ? null : f.path, bytes: kIsWeb ? f.bytes : null),
  ];
}

/// 能不能选整个文件夹（只有电脑上能直接读文件夹里的文件）
bool get canPickFolder => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 选一个文件夹，列出里面所有文件（相对路径以文件夹名开头；隐藏文件、Thumbs.db 跳过）
Future<List<PanelFile>> pickPanelFolder() async {
  final dir = await FilePicker.platform.getDirectoryPath();
  if (dir == null) return [];
  return listFolder(Directory(dir));
}

List<PanelFile> listFolder(Directory dir) {
  final root = dir.path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
  final out = <PanelFile>[];
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(dir.path.length).replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
    if (RegExp(r'(^|/)(\.|Thumbs\.db$)', caseSensitive: false).hasMatch(rel)) continue;
    out.add(PanelFile(name: rel.split('/').last, size: e.lengthSync(), path: e.path, relPath: '$root/$rel'));
  }
  return out;
}

/// 工具上传的 multipart：先放 meta 再放 zip（后台先读出 meta 查权限，再把整个内容原样转给 SFU）
({Stream<List<int>> Function() body, int length, String type}) toolMultipart(Map<String, dynamic> meta, PanelFile? file) {
  final boundary = '----netbarops${Random().nextInt(1 << 32).toRadixString(16)}${DateTime.now().microsecondsSinceEpoch}';
  final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${jsonEncode(meta)}\r\n');
  final fileHead = file == null
      ? <int>[]
      : utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="${file.name.replaceAll('"', '')}"\r\nContent-Type: application/zip\r\n\r\n');
  final tail = utf8.encode('${file == null ? '' : '\r\n'}--$boundary--\r\n');
  Stream<List<int>> body() async* {
    yield head;
    if (file != null) {
      yield fileHead;
      yield* file.open();
    }
    yield tail;
  }

  return (body: body, length: head.length + fileHead.length + (file?.size ?? 0) + tail.length, type: 'multipart/form-data; boundary=$boundary');
}

/// 上传一个文件到资料库（或知识库 zip）：连接信息、放到哪放在请求头
Future<Map<String, dynamic>> uploadRaw(NetbarApi api, String path, PanelFile f, Map<String, String> extra, {void Function(int, int)? onProgress}) => api.postRaw(path,
    body: f.open,
    length: f.size,
    onProgress: onProgress,
    headers: () => {
          'Content-Type': 'application/octet-stream',
          'X-Ops-Mcp': Uri.encodeComponent(api.key),
          'X-Ops-Token': api.conn,
          ...extra,
        });
