import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/chat_result.dart';
import '../models/memory.dart';
import '../providers/assistant_provider.dart';

class Attachment {
  final String name;
  final String type; // 'image' 或 'file'
  final String data; // 对于图片是 Base64 Data URL，对于文本文件是文件内容文本

  Attachment({required this.name, required this.type, required this.data});
}

class CommandCenterView extends ConsumerStatefulWidget {
  final String initialMode; // 'text', 'camera', 'voice'
  const CommandCenterView({super.key, this.initialMode = 'text'});

  @override
  ConsumerState<CommandCenterView> createState() => _CommandCenterViewState();
}

class _CommandCenterViewState extends ConsumerState<CommandCenterView>
    with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  bool _isSearching = false;
  bool _isIngesting = false;

  // 附件暂存列表
  final List<Attachment> _attachments = [];

  // 剪贴板自动嗅探相关
  String? _lastClipboardText;
  String? _detectedClipboardText;
  bool _showClipboardPrompt = false;

  // 接收分享相关
  StreamSubscription? _intentSub;

  // 语音录音相关
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _isCancelRange = false;
  List<double> _ampSamples = [];
  Timer? _ampTimer;
  String? _recordFilePath;
  DateTime? _recordStartTime;

  // TTS 播放器
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // receive_sharing_intent 仅支持移动端原生平台 (Android / iOS)，在 Web/桌面端不进行初始化，以防 MissingPluginException 报错崩溃
    if (!kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS)) {
      _initSharingIntent();
    }
    _checkClipboard();

    // 根据入口模式自动触发对应操作
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (widget.initialMode) {
        case 'camera':
          _pickImage(ImageSource.camera);
          break;
        case 'voice':
          _startRecording();
          break;
        default:
          // text 模式：默认聚焦输入框，无需额外操作
          break;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intentSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _ampTimer?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  // 检测剪贴板
  Future<void> _checkClipboard() async {
    if (_isIngesting || _isSearching) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data != null && data.text != null) {
        final text = data.text!.trim();
        if (text.isNotEmpty && text != _lastClipboardText) {
          setState(() {
            _detectedClipboardText = text;
            _showClipboardPrompt = true;
          });
        }
      }
    } catch (e) {
      debugPrint('Error checking clipboard: $e');
    }
  }

  // 初始化分享意图监听
  void _initSharingIntent() {
    // 处理在后台时的分享
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      _handleSharedMedia(value);
    }, onError: (err) {
      debugPrint("getMediaStream error: $err");
    });

    // 处理冷启动时的分享
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        _handleSharedMedia(value);
      }
      ReceiveSharingIntent.instance.reset();
    });
  }

  // 处理分享流中的文件或文本
  void _handleSharedMedia(List<SharedMediaFile> mediaFiles) async {
    if (mediaFiles.isEmpty) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('接收到微信/系统分享，正在入库...'),
            backgroundColor: Colors.deepPurple),
      );
    }

    for (var file in mediaFiles) {
      if (file.type == SharedMediaType.text ||
          file.type == SharedMediaType.url) {
        final text = file.path;
        if (text.isNotEmpty) {
          await _handleDirectTextIngest(text);
        }
      } else if (file.type == SharedMediaType.image) {
        final path = file.path;
        if (path.isNotEmpty) {
          final ioFile = io.File(path);
          if (await ioFile.exists()) {
            final bytes = await ioFile.readAsBytes();
            final base64Data = base64Encode(bytes);
            final fileName = path.split(io.Platform.pathSeparator).last;
            final mimeType =
                fileName.endsWith('.jpg') || fileName.endsWith('.jpeg')
                    ? 'image/jpeg'
                    : 'image/png';
            final dataUrl = 'data:$mimeType;base64,$base64Data';
            _handleImageIngest(dataUrl, fileName);
          }
        }
      }
    }
  }

  // 直接入库分享过来的文本
  Future<void> _handleDirectTextIngest(String text) async {
    if (_isIngesting || _isSearching) return;
    setState(() {
      _isIngesting = true;
    });
    try {
      await ref.read(assistantProvider.notifier).addMemory(text, 'text', '');
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('外部分享文本已成功入库！'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('分享文本入库失败: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  // 发送 Base64 图片进行 OCR 提取事实静默入库（主要用于外部分享流的无感写入）
  void _handleImageIngest(String base64Data, String fileName) async {
    if (_isIngesting || _isSearching) return;
    setState(() {
      _isIngesting = true;
    });

    try {
      await ref
          .read(assistantProvider.notifier)
          .addMemory(base64Data, 'image', fileName);
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('图片 $fileName 已通过 AI 深度分析并入库！'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('图片解析入库失败: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  // 开始录音
  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final fileName = 'rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
        final filePath = '${tempDir.path}/$fileName';

        setState(() {
          _isRecording = true;
          _isCancelRange = false;
          _ampSamples = List.filled(30, 0.0);
          _recordFilePath = filePath;
          _recordStartTime = DateTime.now();
        });

        // 震动反馈
        Feedback.forLongPress(context);

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 16000,
            bitRate: 64000,
          ),
          path: filePath,
        );

        // 定时拉取振幅分贝
        _ampTimer?.cancel();
        _ampTimer =
            Timer.periodic(const Duration(milliseconds: 50), (timer) async {
          if (!_isRecording) return;
          final amp = await _audioRecorder.getAmplitude();
          setState(() {
            double volume = (amp.current + 60.0) / 60.0;
            if (volume < 0.0) volume = 0.0;
            if (volume > 1.0) volume = 1.0;

            _ampSamples.removeAt(0);
            _ampSamples.add(volume);
          });
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('未获取麦克风权限，无法录音'),
              backgroundColor: Colors.redAccent),
        );
      }
    } catch (e) {
      debugPrint("Error starting recorder: $e");
      _stopRecordingState();
    }
  }

  void _stopRecordingState() {
    _ampTimer?.cancel();
    setState(() {
      _isRecording = false;
      _isCancelRange = false;
    });
  }

  // 结束/放弃录音
  Future<void> _stopRecording(bool isCanceled) async {
    if (!_isRecording) return;
    _ampTimer?.cancel();

    try {
      final path = await _audioRecorder.stop();
      final startTime = _recordStartTime;
      _stopRecordingState();

      if (isCanceled || path == null) {
        if (path != null) {
          final file = io.File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
        return;
      }

      if (startTime != null) {
        final duration = DateTime.now().difference(startTime);
        if (duration.inMilliseconds < 1000) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('录音时间太短'), backgroundColor: Colors.orangeAccent),
          );
          final file = io.File(path);
          if (await file.exists()) {
            await file.delete();
          }
          return;
        }
      }

      _handleAudioTranscribe(path);
    } catch (e) {
      debugPrint("Error stopping recorder: $e");
      _stopRecordingState();
    }
  }

  // 语音转译纯文本处理
  void _handleAudioTranscribe(String filePath) async {
    if (_isIngesting || _isSearching) return;
    setState(() {
      _isIngesting = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在执行语音转文字...'),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final apiService = ref.read(apiServiceProvider);
      final config = ref.read(configProvider);

      final text = await apiService.transcribeAudio(filePath, config);

      if (mounted) {
        setState(() {
          _isIngesting = false;
          if (_inputController.text.isNotEmpty) {
            _inputController.text = '${_inputController.text} $text';
          } else {
            _inputController.text = text;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('语音识别成功！已填充至输入框，可修改并发送。'),
            backgroundColor: Colors.green,
          ),
        );
      }
      final file = io.File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('语音转文字失败: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      try {
        final file = io.File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  // 弹出附件选择菜单（极客风大厂设计）
  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1F1E29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.description, color: Colors.blueAccent),
                title: Text('导入文本/Markdown文件',
                    style: GoogleFonts.outfit(color: Colors.white)),
                subtitle: Text('支持 .txt, .md, .json，读取内容并填充输入框',
                    style:
                        GoogleFonts.outfit(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _pickTextFile();
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.photo_library, color: Color(0xFFFF8906)),
                title: Text('选取相册图片 (AI 智能识图)',
                    style: GoogleFonts.outfit(color: Colors.white)),
                subtitle: Text('支持自动压缩，上传并使用 AI 深度理解图片内容',
                    style:
                        GoogleFonts.outfit(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFF10B981)),
                title: Text('拍照上传 (AI 智能识图)',
                    style: GoogleFonts.outfit(color: Colors.white)),
                subtitle: Text('拍照后由 AI 深度理解场景、意图和关键信息',
                    style:
                        GoogleFonts.outfit(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // 跨平台选取文本文件并缓存为附件
  void _pickTextFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'json'],
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        String content = '';

        if (kIsWeb) {
          if (file.bytes != null) {
            content = utf8.decode(file.bytes!);
          }
        } else {
          if (file.bytes != null) {
            content = utf8.decode(file.bytes!);
          } else if (file.path != null) {
            final ioFile = io.File(file.path!);
            content = await ioFile.readAsString();
          }
        }

        if (content.isNotEmpty) {
          setState(() {
            _attachments.add(Attachment(
              name: file.name,
              type: 'file',
              data: content,
            ));
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('已导入附件文件 ${file.name}，挂载在输入框上方。'),
                backgroundColor: Colors.deepPurple,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('读取文本文件失败: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  // 跨平台选取图片
  void _pickImage(ImageSource source) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (image != null) {
        final bytes = await image.readAsBytes();
        final base64Data = base64Encode(bytes);

        final mimeType = image.mimeType ?? 'image/png';
        final dataUrl = 'data:$mimeType;base64,$base64Data';

        setState(() {
          _attachments.add(Attachment(
            name: image.name,
            type: 'image',
            data: dataUrl,
          ));
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已添加图片附件 ${image.name}，挂载在输入框上方。'),
              backgroundColor: Colors.deepPurple,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('选择图片失败: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  // 极速录入信息与附件投递
  void _handleIngest() async {
    final text = _inputController.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    if (_isIngesting || _isSearching) return;

    setState(() {
      _isIngesting = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在投递事实并解析元数据中...'),
        duration: Duration(seconds: 1),
      ),
    );

    try {
      final notifier = ref.read(assistantProvider.notifier);

      // 1. 投递文字
      if (text.isNotEmpty) {
        await notifier.addMemory(text, 'text', '');
      }

      // 2. 串行投递所有附件卡片
      for (var att in _attachments) {
        if (att.type == 'image') {
          await notifier.addMemory(att.data, 'image', att.name);
        } else if (att.type == 'file') {
          await notifier.addMemory(att.data, 'file', att.name);
        }
      }

      if (mounted) {
        setState(() {
          _isIngesting = false;
          _attachments.clear();
          _inputController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('文字与挂载附件已成功全部导入！'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIngesting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('投递失败: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  // 语义检索并融合附件内容 (RAG)
  void _handleAsk() async {
    final text = _inputController.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    if (_isSearching || _isIngesting) return;

    setState(() {
      _messages.add({
        'role': 'user',
        'content': text.isNotEmpty ? text : '基于上传的附件进行综合分析'
      });
      _isSearching = true;
    });

    final userQuery = text;
    _inputController.clear();

    final tempAttachments = List<Attachment>.from(_attachments);
    setState(() {
      _attachments.clear();
    });

    try {
      final apiService = ref.read(apiServiceProvider);
      final config = ref.read(configProvider);

      StringBuffer contextQuery = StringBuffer();

      // 对所有附件执行 OCR 或者读取文字融合
      for (var att in tempAttachments) {
        if (att.type == 'file') {
          contextQuery.writeln('[关联文本文件: ${att.name}]');
          contextQuery.writeln('```');
          contextQuery.writeln(att.data);
          contextQuery.writeln('```');
          contextQuery.writeln();
        } else if (att.type == 'image') {
          contextQuery.writeln('[关联图片: ${att.name} (AI智能识图分析中...)]');
          contextQuery.writeln('```');
          try {
            final ocrResult = await apiService.performOCR(att.data, config);
            contextQuery.writeln(ocrResult);
          } catch (ocrErr) {
            contextQuery.writeln('(图片OCR文字提取失败: $ocrErr)');
          }
          contextQuery.writeln('```');
          contextQuery.writeln();
        }
      }

      if (userQuery.isNotEmpty) {
        contextQuery.writeln('[用户提问/指令]: $userQuery');
        contextQuery.writeln(
            '\n【助手指令】: 请结合上述图片/文件（特别是AI智能识图分析出的文字与意图），对用户的具体提问做出聪明、精准且富有同理心的回应。');
      } else {
        contextQuery.writeln('[用户意图指令]: 分析并推断用户拍照/上传该图片/文件的真实意图。');
        contextQuery.writeln(
            '\n【助手指令】: 请扮演我的私人贴身助手，深度识别上述图片中我拍照的潜意识意图（例如：看到美食想了解、看到日程想记录、看到白板要备忘、看到报错求救等）。请直接以第一人称助手口吻（如“我看到您拍的是...”）与我开启智能对话，提供针对性的解答、记录建议或关怀。绝对不要生硬地把报告里的“场景识别”、“文字提取”等格式化标题列给用户，要自然温和地直接交谈。');
      }

      final finalPrompt = contextQuery.toString();
      final result = await ref
          .read(assistantProvider.notifier)
          .askQuestion(finalPrompt, 'session_default');

      if (mounted) {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'content': result.answer,
            'sources': result.sources,
          });
          _isSearching = false;
        });

        // 异步播放 TTS 语音反馈
        try {
          final ttsBytes = await apiService.generateTTS(result.answer, config);
          await _audioPlayer.play(BytesSource(ttsBytes));
        } catch (ttsErr) {
          debugPrint('TTS 播放失败: $ttsErr');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('问答语音播放失败: $ttsErr',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
                backgroundColor: Colors.redAccent.shade700,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add({'role': 'assistant', 'content': '抱歉，检索分析发生错误: $e'});
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _openCitation(MemoryCitation citation) async {
    try {
      final memory =
          await ref.read(apiServiceProvider).fetchMemory(citation.memoryId);
      if (!mounted) return;
      _showSourceMemoryDialog(memory);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('来源记忆加载失败: $e')),
      );
    }
  }

  void _showSourceMemoryDialog(Memory memory) {
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(memory.createdAt * 1000);
    final updatedAt =
        DateTime.fromMillisecondsSinceEpoch(memory.updatedAt * 1000);
    final originalContent = memory.originalContent.isNotEmpty
        ? memory.originalContent
        : memory.rawContent;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1F1E29),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        memory.title.isEmpty ? '未命名记忆' : memory.title,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close, color: Colors.white54),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12),
                const SizedBox(height: 10),
                _buildSourceMetaRow(
                  Icons.input,
                  '来源',
                  _sourceTypeLabel(memory.sourceType),
                ),
                if (memory.sourceMeta.isNotEmpty)
                  _buildSourceMetaRow(
                      Icons.description_outlined, '来源信息', memory.sourceMeta),
                _buildSourceMetaRow(
                  Icons.schedule,
                  '录入时间',
                  DateFormat('yyyy/MM/dd HH:mm').format(createdAt),
                ),
                _buildSourceMetaRow(
                  Icons.sync,
                  '最近处理',
                  DateFormat('yyyy/MM/dd HH:mm').format(updatedAt),
                ),
                if (memory.extractedTime.isNotEmpty)
                  _buildSourceMetaRow(
                    Icons.event,
                    '关联时间',
                    memory.extractedTime,
                  ),
                const SizedBox(height: 14),
                Text(
                  '原始内容',
                  style: GoogleFonts.outfit(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                _buildOriginalContent(memory.sourceType, originalContent),
                if (memory.rawContent.trim() != originalContent.trim()) ...[
                  const SizedBox(height: 16),
                  Text(
                    '解析内容',
                    style: GoogleFonts.outfit(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                  SelectableText(
                    memory.rawContent,
                    style: GoogleFonts.outfit(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
                if (memory.processingError.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    memory.processingError,
                    style: GoogleFonts.outfit(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourceMetaRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFFF8906), size: 15),
          const SizedBox(width: 7),
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOriginalContent(String sourceType, String content) {
    if (sourceType == 'image' && content.startsWith('data:image')) {
      try {
        final encoded = content.substring(content.indexOf(',') + 1);
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(
            base64Decode(encoded),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text(
              '原始图片无法显示',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        );
      } catch (_) {
        return const Text(
          '原始图片无法显示',
          style: TextStyle(color: Colors.redAccent),
        );
      }
    }
    return SelectableText(
      content,
      style: GoogleFonts.outfit(
        color: Colors.white70,
        fontSize: 13,
        height: 1.45,
      ),
    );
  }

  String _sourceTypeLabel(String sourceType) {
    switch (sourceType) {
      case 'image':
        return '图片';
      case 'audio':
        return '语音';
      case 'file':
        return '文件';
      case 'link':
        return '链接';
      case 'note':
        return '笔记';
      default:
        return '文本';
    }
  }

  // 附件悬浮展示栏
  Widget _buildAttachmentBar() {
    if (_attachments.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 90,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _attachments.length,
        itemBuilder: (context, index) {
          final att = _attachments[index];
          final isImage = att.type == 'image';

          return Container(
            width: 80,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1E29),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.deepPurple.withOpacity(0.3)),
            ),
            child: Stack(
              children: [
                GestureDetector(
                  onTap: () => _previewAttachment(att),
                  child: Center(
                    child: isImage
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: _buildImageWidget(att.data),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.insert_drive_file,
                                  color: Colors.blueAccent, size: 28),
                              const SizedBox(height: 4),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4.0),
                                child: Text(
                                  att.name,
                                  style: GoogleFonts.outfit(
                                      color: Colors.grey, fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _attachments.removeAt(index);
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          color: Colors.redAccent, size: 14),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // 点击预览附件详情 Dialog
  void _previewAttachment(Attachment att) {
    final isImage = att.type == 'image';

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1F1E29),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        att.name,
                        style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.6,
                    maxWidth: MediaQuery.of(context).size.width * 0.8,
                  ),
                  child: SingleChildScrollView(
                    child: isImage
                        ? _buildImageWidget(att.data)
                        : Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              att.data,
                              style: GoogleFonts.shareTechMono(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 辅助解析 Base64 并在前端渲染图片缩略图
  Widget _buildImageWidget(String data) {
    try {
      final cleanBase64 = data.contains(',') ? data.split(',')[1] : data;
      final bytes = base64Decode(cleanBase64);
      return Image.memory(
        bytes,
        width: 80,
        height: 90,
        fit: BoxFit.cover,
      );
    } catch (e) {
      return const Icon(Icons.broken_image, color: Colors.redAccent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0E17),
        elevation: 0,
        title: Text(
          '全局指令舱 (Command Center)',
          style: GoogleFonts.outfit(
              fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 聊天/问答流
              Expanded(
                child: _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.terminal,
                                size: 64,
                                color: Colors.deepPurple.withOpacity(0.5)),
                            const SizedBox(height: 16),
                            Text(
                              '在下方输入框可执行操作：\n1. 点击 [投递记录]：无感打标存储碎片知识\n2. 点击 [语义检索]：基于双轨记忆库寻找答案',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.outfit(
                                  color: Colors.grey, fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isUser = msg['role'] == 'user';
                          final sources =
                              (msg['sources'] as List<MemoryCitation>?) ??
                                  const <MemoryCitation>[];
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? const Color(0xFFFF8906)
                                    : const Color(0xFF1F1E29),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(12),
                                  topRight: const Radius.circular(12),
                                  bottomLeft: isUser
                                      ? const Radius.circular(12)
                                      : Radius.zero,
                                  bottomRight: isUser
                                      ? Radius.zero
                                      : const Radius.circular(12),
                                ),
                                border: isUser
                                    ? null
                                    : Border.all(
                                        color:
                                            Colors.deepPurple.withOpacity(0.2)),
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg['content'] ?? '',
                                    style: GoogleFonts.outfit(
                                      color:
                                          isUser ? Colors.black : Colors.white,
                                      fontSize: 16,
                                    ),
                                  ),
                                  if (!isUser && sources.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    const Divider(
                                        color: Colors.white12, height: 1),
                                    const SizedBox(height: 10),
                                    Text(
                                      '参考记忆',
                                      style: GoogleFonts.outfit(
                                        color: Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    ...sources.asMap().entries.map((entry) {
                                      final citation = entry.value;
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 6),
                                        child: InkWell(
                                          onTap: () => _openCitation(citation),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          child: Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.all(9),
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withOpacity(0.16),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                  color: Colors.white10),
                                            ),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '[${entry.key + 1}]',
                                                  style:
                                                      GoogleFonts.shareTechMono(
                                                    color:
                                                        const Color(0xFFFF8906),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        citation.title,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style:
                                                            GoogleFonts.outfit(
                                                          color: Colors.white,
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        citation.excerpt,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style:
                                                            GoogleFonts.outfit(
                                                          color: Colors.white54,
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const Icon(
                                                  Icons.open_in_new,
                                                  color: Colors.white38,
                                                  size: 14,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              if (_isSearching || _isIngesting)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFFFF8906)),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _isSearching ? '思考并混合检索事实中...' : '解析并投递事实中...',
                        style: GoogleFonts.outfit(color: Colors.grey),
                      ),
                    ],
                  ),
                ),

              // 指令输入舱
              Container(
                padding: const EdgeInsets.all(16),
                color: const Color(0xFF0F0E17),
                child: SafeArea(
                  child: Column(
                    children: [
                      // 剪贴板一键投递提示气泡（毛玻璃质感）
                      if (_showClipboardPrompt &&
                          _detectedClipboardText != null) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1E29).withOpacity(0.8),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.deepPurple.withOpacity(0.3)),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.assignment,
                                          color: Color(0xFFFF8906), size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '检测到刚复制的文本，是否一键投递？',
                                          style: GoogleFonts.outfit(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close,
                                            color: Colors.grey, size: 18),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          setState(() {
                                            _lastClipboardText =
                                                _detectedClipboardText;
                                            _showClipboardPrompt = false;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _detectedClipboardText!.length > 120
                                        ? '${_detectedClipboardText!.substring(0, 120)}...'
                                        : _detectedClipboardText!,
                                    style: GoogleFonts.outfit(
                                      color: Colors.grey,
                                      fontSize: 13,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: () {
                                          setState(() {
                                            _lastClipboardText =
                                                _detectedClipboardText;
                                            _showClipboardPrompt = false;
                                          });
                                        },
                                        child: Text('忽略',
                                            style: GoogleFonts.outfit(
                                                color: Colors.grey)),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFFFF8906),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                        ),
                                        onPressed: () {
                                          final text = _detectedClipboardText!;
                                          setState(() {
                                            _lastClipboardText = text;
                                            _showClipboardPrompt = false;
                                          });
                                          _handleDirectTextIngest(text);
                                        },
                                        child: Text('一键投递',
                                            style: GoogleFonts.outfit(
                                                color: Colors.black,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],

                      _buildAttachmentBar(),

                      TextField(
                        controller: _inputController,
                        style: GoogleFonts.outfit(color: Colors.white),
                        maxLines: 3,
                        minLines: 1,
                        decoration: InputDecoration(
                          hintText: '写下你的计划/复制微信群通知/提出你的疑问...',
                          hintStyle: GoogleFonts.outfit(color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFF1F1E29),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.attach_file,
                                    color: Color(0xFFFF8906)),
                                onPressed: (_isIngesting || _isSearching)
                                    ? null
                                    : _showAttachmentMenu,
                                tooltip: '导入文本/选取图片 OCR',
                              ),
                              GestureDetector(
                                onTap: () {
                                  if (_isRecording) {
                                    _stopRecording(false);
                                  } else {
                                    _startRecording();
                                  }
                                },
                                onLongPressStart: (_) => _startRecording(),
                                onLongPressMoveUpdate: (details) {
                                  if (details.localOffsetFromOrigin.dy < -60) {
                                    if (!_isCancelRange) {
                                      setState(() {
                                        _isCancelRange = true;
                                      });
                                    }
                                  } else {
                                    if (_isCancelRange) {
                                      setState(() {
                                        _isCancelRange = false;
                                      });
                                    }
                                  }
                                },
                                onLongPressEnd: (_) =>
                                    _stopRecording(_isCancelRange),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12.0),
                                  child: Icon(
                                    Icons.mic,
                                    color: _isRecording
                                        ? Colors.redAccent
                                        : ((_isIngesting || _isSearching)
                                            ? Colors.grey
                                            : const Color(0xFFFF8906)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: Colors.deepPurple.withOpacity(0.5)),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          // 投递按钮
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                    color: (_isIngesting || _isSearching)
                                        ? Colors.grey
                                        : const Color(0xFFFF8906)),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: (_isIngesting || _isSearching)
                                  ? null
                                  : _handleIngest,
                              icon: Icon(Icons.cloud_upload,
                                  color: (_isIngesting || _isSearching)
                                      ? Colors.grey
                                      : const Color(0xFFFF8906)),
                              label: Text(
                                '投递记录',
                                style: GoogleFonts.outfit(
                                    color: (_isIngesting || _isSearching)
                                        ? Colors.grey
                                        : const Color(0xFFFF8906),
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // 检索按钮
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: (_isIngesting || _isSearching)
                                    ? Colors.grey.withOpacity(0.3)
                                    : const Color(0xFFFF8906),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: (_isIngesting || _isSearching)
                                  ? null
                                  : _handleAsk,
                              icon: Icon(Icons.psychology,
                                  color: (_isIngesting || _isSearching)
                                      ? Colors.grey
                                      : Colors.black),
                              label: Text(
                                '语义检索',
                                style: GoogleFonts.outfit(
                                    color: (_isIngesting || _isSearching)
                                        ? Colors.grey
                                        : Colors.black,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // 录音全屏毛玻璃遮罩
          if (_isRecording)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _stopRecording(false),
                child: ClipRRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      color: Colors.black.withOpacity(0.6),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1F1E29),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _isCancelRange
                                      ? Colors.redAccent.withOpacity(0.5)
                                      : Colors.deepPurple.withOpacity(0.5),
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                _isCancelRange
                                    ? Icons.settings_backup_restore
                                    : Icons.mic,
                                size: 48,
                                color: _isCancelRange
                                    ? Colors.redAccent
                                    : const Color(0xFFFF8906),
                              ),
                            ),
                            const SizedBox(height: 32),
                            // 声波发光起伏动画
                            SizedBox(
                              height: 60,
                              width: 240,
                              child: CustomPaint(
                                painter: WaveformPainter(
                                  samples: _ampSamples,
                                  color: _isCancelRange
                                      ? Colors.redAccent
                                      : const Color(0xFFFF8906),
                                ),
                              ),
                            ),
                            const SizedBox(height: 32),
                            Text(
                              _isCancelRange
                                  ? '松开手指，取消录音'
                                  : '正在录音... 松开发送/点击任意区域发送，上滑取消',
                              style: GoogleFonts.outfit(
                                color: _isCancelRange
                                    ? Colors.redAccent
                                    : Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 极客风对称声波绘制器
class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;

  WaveformPainter({required this.samples, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final double width = size.width;
    final double height = size.height;
    final int count = samples.length;
    final double step = width / (count - 1);

    final double centerY = height / 2;

    for (int i = 0; i < count; i++) {
      final double x = i * step;
      final double ampHeight = samples[i] * (height / 2);

      canvas.drawLine(
        Offset(x, centerY - ampHeight - 3),
        Offset(x, centerY + ampHeight + 3),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.samples != samples || oldDelegate.color != color;
  }
}
