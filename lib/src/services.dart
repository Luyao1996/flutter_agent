// 平台能力：图片压缩、语音输入、选文件/拍照、剪贴板里的图片和文件、保存和分享
// 都包一层，出错一律变成给用户看的中文提示
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';

bool get isDesktopPlatform => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
bool get isMobilePlatform => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

// ---------- 图片：超过 2000 像素或 1.5 MB 时缩小，压成 JPG（动图不动） ----------
({Uint8List bytes, String name}) _shrink(({Uint8List bytes, String name}) a) {
  final src = img.decodeImage(a.bytes);
  if (src == null) return a;
  final longest = src.width > src.height ? src.width : src.height;
  if (longest <= 2000 && a.bytes.length <= 1.5 * 1024 * 1024) return a;
  final scaled = longest > 2000 ? img.copyResize(src, width: src.width >= src.height ? 2000 : null, height: src.height > src.width ? 2000 : null) : src;
  // 透明的地方铺白底
  final flat = img.Image(width: scaled.width, height: scaled.height)..clear(img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, scaled);
  final name = a.name.contains('.') ? '${a.name.substring(0, a.name.lastIndexOf('.'))}.jpg' : '${a.name}.jpg';
  return (bytes: Uint8List.fromList(img.encodeJpg(flat, quality: 85)), name: name);
}

Future<({Uint8List bytes, String name})> shrinkImage(Uint8List bytes, String name) => compute(_shrink, (bytes: bytes, name: name));

// ---------- 选文件、拍照、相册 ----------
/// 选到的文件：bytes 为 null 表示太大没有读进来（size 是原始大小）
typedef PickedFile = ({Uint8List? bytes, String name, int size});

/// 单个文件最大 20MB（和服务端一致），超过的不读进内存
const maxFileBytes = 20 * 1024 * 1024;

const allowedExtensions = [
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'pdf',
  'txt',
  'md',
  'log',
  'csv',
  'tsv',
  'json',
  'ini',
  'cfg',
  'conf',
  'inf',
  'xml',
  'yaml',
  'yml',
  'bat',
  'cmd',
  'ps1',
  'vbs',
  'reg',
  'sh',
  'py',
  'sql',
  'html',
  'htm',
  'docx',
  'xlsx',
  'pptx',
  'doc',
  'xls',
  'ppt'
];

// 用的是 file_picker 9.x 的写法（FilePicker.platform），和宿主项目锁定的版本一致
Future<List<PickedFile>> pickFiles() async {
  // 不让插件把文件全读进内存（1GB 的日志会把内存撑爆）：先看大小，不超过上限再读
  final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: allowedExtensions, allowMultiple: true, withData: false);
  final out = <PickedFile>[];
  for (final f in r?.files ?? const <PlatformFile>[]) {
    if (f.size > maxFileBytes || (f.path == null && f.bytes == null)) {
      out.add((bytes: null, name: f.name, size: f.size));
    } else {
      out.add((bytes: f.bytes ?? await File(f.path!).readAsBytes(), name: f.name, size: f.size));
    }
  }
  return out;
}

/// 选 md / txt 文件（知识库背景知识、技能上传用），返回文件名和文字
Future<List<({String name, String text})>> pickTextFiles() async {
  final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['md', 'markdown', 'txt'], allowMultiple: true, withData: true);
  return [
    for (final f in r?.files ?? const <PlatformFile>[]) (name: f.name, text: utf8.decode(f.bytes ?? await File(f.path!).readAsBytes(), allowMalformed: true)),
  ];
}

/// 手机上拍照或从相册选（相册可以多选）；图片在这一步就先压小
Future<List<PickedFile>> pickImages({required bool camera}) async {
  final picker = ImagePicker();
  final files = camera
      ? [await picker.pickImage(source: ImageSource.camera, maxWidth: 2000, maxHeight: 2000, imageQuality: 85)].whereType<XFile>().toList()
      : await picker.pickMultiImage(maxWidth: 2000, maxHeight: 2000, imageQuality: 85);
  return [for (final f in files) (bytes: await f.readAsBytes(), name: f.name, size: await f.length())];
}

// ---------- 剪贴板（Windows 上 Ctrl+V 粘贴截图、从资源管理器复制的文件） ----------
/// 剪贴板里有文件就返回文件，有图片就返回图片，都没有返回空
Future<List<PickedFile>> readClipboardFiles() async {
  try {
    final paths = await Pasteboard.files();
    if (paths.isNotEmpty) {
      return [
        for (final p in paths)
          if (File(p).lengthSync() > maxFileBytes)
            (bytes: null, name: p.split(RegExp(r'[\\/]')).last, size: File(p).lengthSync())
          else
            (bytes: await File(p).readAsBytes(), name: p.split(RegExp(r'[\\/]')).last, size: File(p).lengthSync()),
      ];
    }
    final image = await Pasteboard.image;
    if (image != null && image.isNotEmpty) return [(bytes: image, name: '', size: image.length)];
  } catch (_) {}
  return [];
}

Future<String?> readClipboardText() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

// ---------- 复制、保存、分享 ----------
Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));

/// 保存附件：电脑上弹出“另存为”，手机上用系统分享（存到文件、发给别人）
Future<bool> saveFile(Uint8List bytes, String name, {Rect? origin}) async {
  if (isDesktopPlatform) {
    // 电脑上 saveFile 只返回选好的路径，文件要自己写
    final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
    if (path == null) return false;
    await File(path).writeAsBytes(bytes);
    return true;
  }
  final r = await Share.shareXFiles([XFile.fromData(bytes, name: name)], fileNameOverrides: [name], sharePositionOrigin: origin);
  return r.status == ShareResultStatus.success;
}

/// 手机上用系统分享面板发链接
Future<void> shareText(String text, {String? subject, Rect? origin}) => Share.share(text, subject: subject, sharePositionOrigin: origin);

// ---------- 语音输入：系统自带的语音识别，结果插到光标处，不自动发送 ----------
class Dictation {
  final SpeechToText _stt = SpeechToText();
  bool _inited = false, _available = false;
  bool get listening => _stt.isListening;

  static const _errors = {
    'error_network': '语音识别连不上服务器，请检查网络后再试。',
    'error_network_timeout': '语音识别连不上服务器，请检查网络后再试。',
    'error_no_match': '没有听清，请靠近麦克风再说一次。',
    'error_speech_timeout': '没有听到说话声，请靠近麦克风再试一次。',
    'error_audio_error': '没有找到麦克风，请检查麦克风是否可用。',
    'error_permission': '没有麦克风权限：请在系统设置里允许这个应用使用麦克风和语音识别。',
    'error_insufficient_permissions': '没有麦克风权限：请在系统设置里允许这个应用使用麦克风和语音识别。',
    'error_server_disconnected': '语音识别服务断开了，请再试一次。',
    'error_language_not_supported': '这台设备不支持中文语音识别。',
    'error_language_unavailable': '这台设备没有安装中文语音识别，请在系统设置里添加中文语言。',
  };

  // 这次识别的回调和出错原因：插件的状态、出错回调只能在初始化时注册一次，所以每次开始时换成这次的
  void Function(String? error)? _onEnd;
  String? _error;

  void _finish() {
    final end = _onEnd;
    _onEnd = null;
    end?.call(_error);
  }

  /// 开始听：onPartial 实时给出正在识别的文字，onFinal 给出确定的一句，onEnd 结束（带出错原因或 null，每次只调一次）
  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal, required void Function(String? error) onEnd}) async {
    _onEnd = onEnd;
    _error = null;
    if (!_inited) {
      _inited = true;
      try {
        _available = await _stt.initialize(
          onError: (e) => _error = _errors[e.errorMsg] ?? '语音识别出错了（${e.errorMsg}），可以再试一次。',
          onStatus: (s) {
            if (s == 'done' || s == 'notListening') _finish();
          },
        );
      } catch (_) {
        _available = false;
      }
    }
    if (!_available) {
      _inited = false;
      _error = Platform.isAndroid ? '这台手机没有可用的语音识别服务（很多国产手机需要安装或打开系统自带的语音识别），也可能是没有给麦克风权限。' : '当前设备不支持语音输入，或者没有给麦克风和语音识别权限。';
      return _finish();
    }
    try {
      await _stt.listen(
        // speech_to_text 7.0 的 SpeechListenOptions 里还没有 localeId，用 listen 自己的参数（7.x 都能用）
        // ignore: deprecated_member_use
        localeId: 'zh_CN',
        listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true, listenMode: ListenMode.dictation, autoPunctuation: true),
        onResult: (r) => r.finalResult ? onFinal(r.recognizedWords) : onPartial(r.recognizedWords),
      );
    } catch (_) {
      _error = '语音识别启动失败，请再试一次。';
      _finish();
    }
  }

  /// 不再需要结果（界面关掉了）：停止，并且不再回调
  Future<void> cancel() async {
    _onEnd = null;
    try {
      await _stt.cancel();
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
