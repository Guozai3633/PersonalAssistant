import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/assistant_provider.dart'; // 读取用户 AI 配置
import '../services/api_service.dart';

// 用于控制反应堆振幅的全局状态
final amplitudeProvider = StateProvider<double>((ref) => 0.0);

class VoiceCabinView extends ConsumerStatefulWidget {
	const VoiceCabinView({Key? key}) : super(key: key);

	@override
	ConsumerState<VoiceCabinView> createState() => _VoiceCabinViewState();
}

class _VoiceCabinViewState extends ConsumerState<VoiceCabinView> with SingleTickerProviderStateMixin {
	late AnimationController _reactorController;
	final _audioRecorder = AudioRecorder();
	final _audioPlayer = AudioPlayer();
	
	io.WebSocket? _socket;
	StreamSubscription? _socketSub;
	StreamSubscription? _recordSub;
	Timer? _chunkGuardTimer;
	Timer? _llmEndGuardTimer;


	final List<VoiceMessage> _messages = [];
	final ScrollController _scrollController = ScrollController();

	bool _isRecording = false;
	bool _isThinking = false;
	bool _isPlayingTTS = false;
	
	String _asrText = "";
	String _llmResponse = "";
	String _statusText = "点按核心开启伴随交互";

	// 合并后的音频字节缓存
	final List<int> _combinedAudioBytes = [];
	bool _serverEndSignaled = false;

	@override
	void initState() {
		super.initState();
		_reactorController = AnimationController(
			vsync: this,
			duration: const Duration(seconds: 4),
		)..repeat();

		// 强制将音频路由输出到扬声器（外放），防止在某些真机上默认走到听筒导致听不到声音
		// Web 端不支持原生音频上下文配置，需跳过
		if (!kIsWeb) {
			_audioPlayer.setAudioContext(
				AudioContext(
					android: AudioContextAndroid(
						isSpeakerphoneOn: true,
						stayAwake: true,
						contentType: AndroidContentType.music,
						usageType: AndroidUsageType.media,
						audioFocus: AndroidAudioFocus.gain,
					),
					iOS: AudioContextIOS(
						category: AVAudioSessionCategory.playAndRecord,
						options: {
							AVAudioSessionOptions.defaultToSpeaker,
							AVAudioSessionOptions.mixWithOthers,
						},
					),
				),
			);
		}

		_audioPlayer.onPlayerComplete.listen((_) {
			_resetToReadyState();
		});

		_loadVoiceHistory();
	}

	@override
	void dispose() {
		_cleanupSession();
		_reactorController.dispose();
		_audioPlayer.dispose();
		_audioRecorder.dispose();
		super.dispose();
	}

	void _cleanupSession() {
		_llmEndGuardTimer?.cancel();
		_recordSub?.cancel();
		_audioPlayer.stop();
		_combinedAudioBytes.clear();
		if (_socket != null) {
			_socketSub?.cancel();
			_socket!.close();
			_socket = null;
		}
	}

	// 建立双向 WebSocket 通道
	Future<bool> _initWebSocket() async {
		if (_socket != null) return true;

		setState(() {
			_statusText = "正在唤醒 J.A.R.V.I.S...";
		});

		try {
			final apiService = APIService(); // 自动连接配置的 base url
			final aiConfig = ref.read(configProvider);
			
			final socket = await apiService.connectVoiceStream(aiConfig);
			_socket = socket;

			_socketSub = socket.listen(
				(data) {
					if (data is String) {
						_handleTextMessage(data);
					} else if (data is List<int>) {
						_handleBinaryMessage(Uint8List.fromList(data));
					}
				},
				onError: (err) {
					_showError("连接异常: $err");
				},
				onDone: () {
					_showError("J.A.R.V.I.S 伴随舱已断开");
				},
			);


			return true;
		} catch (e) {
			setState(() {
				_statusText = "唤醒失败，请检查网络或配置";
			});
			_showError("连接失败: $e");
			return false;
		}
	}

	// 处理后端控制或文本帧
	void _handleTextMessage(String jsonStr) {
		try {
			final msg = jsonDecode(jsonStr) as Map<String, dynamic>;
			final type = msg['type'];
			final content = msg['content'] ?? '';

			if (type == 'status') {
				setState(() {
					if (content == 'listening') {
						_statusText = "倾听中...";
					} else if (content == 'asr_processing') {
						_statusText = "正在整理思路...";
					} else if (content == 'llm_processing') {
						_isThinking = true;
						_statusText = "J.A.R.V.I.S 思考中...";
						// 固化用户最后的 ASR 消息
						if (_messages.isNotEmpty && _messages.last.role == 'user') {
							_messages.last.isStreaming = false;
						}
					}
				});
				_scrollToBottom();
			} else if (type == 'asr_text') {
				setState(() {
					_asrText = content;
					_statusText = "您说: $content";

					if (_messages.isNotEmpty && _messages.last.role == 'user' && _messages.last.isStreaming) {
						_messages.last.content = content;
					} else {
						// 容灾：如果没有 user 占位符则新建
						_messages.add(VoiceMessage(role: 'user', content: content, isStreaming: true));
					}
				});
				_scrollToBottom();
			} else if (type == 'llm_text') {
				setState(() {
					_isThinking = false;
					_isPlayingTTS = true;
					_llmResponse += content;
					// 过滤可能在流中出现的 TASK_COMMAND 指令字符
					_llmResponse = _llmResponse.replaceAll(RegExp(r'\[TASK_COMMAND:[^\]]*\]'), '');
					_statusText = "J.A.R.V.I.S 伴随回复中...";

					final cleanChunk = content.replaceAll(RegExp(r'\[TASK_COMMAND:[^\]]*\]'), '');
					if (_messages.isNotEmpty && _messages.last.role == 'assistant' && _messages.last.isStreaming) {
						_messages.last.content += cleanChunk;
					} else {
						_messages.add(VoiceMessage(role: 'assistant', content: cleanChunk, isStreaming: true));
					}
				});
				_scrollToBottom();
			} else if (type == 'llm_end') {
				_serverEndSignaled = true;
				final cleanContent = msg['clean_content'] ?? '';
				setState(() {
					if (cleanContent.isNotEmpty) {
						_llmResponse = cleanContent;
					}
					if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
						if (cleanContent.isNotEmpty) {
							_messages.last.content = cleanContent;
						}
						_messages.last.isStreaming = false;
					}
				});
				_scrollToBottom();

				_llmEndGuardTimer?.cancel();
				
				// 收到 LLM 结束，所有音频分片已就绪，立即合并播放
				_playCombinedAudio();
			} else if (type == 'tts_error') {
				// TTS 合成失败，向用户展示错误信息帮助调试声音问题
				debugPrint("[TTS_ERROR] $content");
				if (mounted) {
					ScaffoldMessenger.of(context).showSnackBar(
						SnackBar(
							content: Text('语音合成异常: $content', style: const TextStyle(color: Colors.white, fontSize: 12)),
							backgroundColor: Colors.orange.shade800,
							duration: const Duration(seconds: 4),
						),
					);
				}
			} else if (type == 'error') {
				_showError("服务异常: $content");
				_resetToReadyState();
			}
		} catch (e) {
			debugPrint("Error parsing message: $e");
		}
	}

	// 收到流式语音合成的二进制分段文件
	void _handleBinaryMessage(Uint8List audioBytes) {
		_combinedAudioBytes.addAll(audioBytes);
	}

	// 播放合并后的完整音频
	Future<void> _playCombinedAudio() async {
		if (_combinedAudioBytes.isEmpty) {
			_resetToReadyState();
			return;
		}

		setState(() {
			_isPlayingTTS = true;
			_statusText = "J.A.R.V.I.S 语音播报中...";
		});

		try {
			final tempDir = await getTemporaryDirectory();
			final tempFile = io.File('${tempDir.path}/tts_combined_${DateTime.now().millisecondsSinceEpoch}.mp3');
			await tempFile.writeAsBytes(Uint8List.fromList(_combinedAudioBytes));

			await _audioPlayer.play(DeviceFileSource(tempFile.path));
		} catch (e) {
			debugPrint("Error playing combined audio: $e");
			if (mounted) {
				ScaffoldMessenger.of(context).showSnackBar(
					SnackBar(
						content: Text('本地播放引擎报错: $e', style: const TextStyle(color: Colors.white, fontSize: 12)),
						backgroundColor: Colors.redAccent.shade700,
						duration: const Duration(seconds: 5),
					),
				);
			}
			_resetToReadyState();
		}
	}

	void _resetToReadyState() {
		_llmEndGuardTimer?.cancel();
		setState(() {
			_isRecording = false;
			_isThinking = false;
			_isPlayingTTS = false;
			_serverEndSignaled = false;
			_asrText = "";
			_llmResponse = "";
			_statusText = "点按核心开启伴随交互";
		});
	}

	void _showError(String text) {
		ScaffoldMessenger.of(context).showSnackBar(
			SnackBar(
				content: Text(text, style: const TextStyle(color: Colors.white)),
				backgroundColor: Colors.redAccent.shade700,
			),
		);
		_resetToReadyState();
	}

	// 开始对讲
	Future<void> _startIngestion() async {
		if (_isRecording || _isThinking || _isPlayingTTS) return;

		// 1. 初始化 WebSocket
		final connected = await _initWebSocket();
		if (!connected) return;

		// 2. 检查并申请麦克风权限
		if (!await _audioRecorder.hasPermission()) {
			_showError("未获得麦克风授权");
			return;
		}

		// 3. 停止当前正在播放的声音
		await _audioPlayer.stop();
		_combinedAudioBytes.clear();

		setState(() {
			_isRecording = true;
			_asrText = "";
			_llmResponse = "";
			_statusText = "正在倾听...";
			_messages.add(VoiceMessage(role: 'user', content: '...', isStreaming: true));
		});
		_scrollToBottom();

		// 4. 发送 start 指令包
		_socket?.add(jsonEncode({"type": "start", "format": "pcm"}));

		// 5. 启动 PCM 流录制
		const recordConfig = RecordConfig(
			encoder: AudioEncoder.pcm16bits,
			sampleRate: 16000,
			numChannels: 1,
		);

		try {
			final recordStream = await _audioRecorder.startStream(recordConfig);
			_recordSub = recordStream.listen(
				(chunk) {
					// 持续往 WebSocket 塞入 PCM 音频包
					_socket?.add(chunk);
				},
				onError: (err) {
					_showError("录制异常: $err");
				},
			);

			// 6. 定时读取录音分贝，用于绘制能量核的动态膨胀效果
			Timer.periodic(const Duration(milliseconds: 60), (timer) async {
				if (!_isRecording) {
					timer.cancel();
					return;
				}
				final amp = await _audioRecorder.getAmplitude();
				// 将分贝 [-40, 0] 换算到比率 [0, 1.0]
				final db = amp.current;
				final ratio = ((db + 40).clamp(0, 40) / 40.0);
				ref.read(amplitudeProvider.notifier).state = ratio;
			});

		} catch (e) {
			_showError("开启录制失败: $e");
		}
	}

	// 结束本次对讲，等待转译与回答
	Future<void> _stopIngestion() async {
		if (!_isRecording) return;

		setState(() {
			_isRecording = false;
			_statusText = "整理思维中...";
		});

		try {
			await _audioRecorder.stop();
			await _recordSub?.cancel();

			// 发送 end 结束帧指令
			_socket?.add(jsonEncode({"type": "end"}));
		} catch (e) {
			_showError("停止录制异常: $e");
		}
	}

	Future<void> _loadVoiceHistory() async {
		try {
			final apiService = await APIService.fromPrefs();
			final history = await apiService.fetchChatHistory('session_voice');
			setState(() {
				_messages.clear();
				for (final item in history) {
					final role = item['role'] ?? 'assistant';
					final content = item['content'] ?? '';
					if (role == 'user' || role == 'assistant') {
						_messages.add(
							VoiceMessage(
								role: role,
								content: content,
								isStreaming: false,
							),
						);
					}
				}
			});
			_scrollToBottom();
		} catch (e) {
			debugPrint("Failed to load voice history: $e");
		}
	}

	void _scrollToBottom() {
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (_scrollController.hasClients) {
				_scrollController.animateTo(
					_scrollController.position.maxScrollExtent,
					duration: const Duration(milliseconds: 300),
					curve: Curves.easeOut,
				);
			}
		});
	}

	Widget _buildChatBubble(VoiceMessage msg) {
		final isUser = msg.role == 'user';
		return Align(
			alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
			child: Container(
				margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
				padding: const EdgeInsets.all(12),
				constraints: BoxConstraints(
					maxWidth: MediaQuery.of(context).size.width * 0.75,
				),
				decoration: BoxDecoration(
					color: isUser
						? const Color(0xFF0D2847).withOpacity(0.75)
						: const Color(0xFF0A162B).withOpacity(0.85),
					borderRadius: BorderRadius.only(
						topLeft: const Radius.circular(12),
						topRight: const Radius.circular(12),
						bottomLeft: isUser ? const Radius.circular(12) : Radius.zero,
						bottomRight: isUser ? Radius.zero : const Radius.circular(12),
					),
					border: Border.all(
						color: isUser
							? const Color(0xFF00AAFF).withOpacity(0.25)
							: const Color(0xFF00F0FF).withOpacity(0.2),
						width: 1,
					),
					boxShadow: [
						BoxShadow(
							color: (isUser ? const Color(0xFF00AAFF) : const Color(0xFF00F0FF)).withOpacity(0.02),
							blurRadius: 4,
							spreadRadius: 1,
						)
					],
				),
				child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						Row(
							mainAxisSize: MainAxisSize.min,
							children: [
								Icon(
									isUser ? Icons.person_outline : Icons.blur_on,
									size: 14,
									color: isUser ? const Color(0xFF00AAFF) : const Color(0xFF00F0FF),
								),
								const SizedBox(width: 6),
								Text(
									isUser ? "YOU" : "J.A.R.V.I.S",
									style: GoogleFonts.orbitron(
										color: isUser ? const Color(0xFF00AAFF) : const Color(0xFF00F0FF),
										fontSize: 10,
										fontWeight: FontWeight.bold,
										letterSpacing: 1.0,
									),
								),
								if (msg.isStreaming) ...[
									const SizedBox(width: 8),
									Container(
										width: 6,
										height: 6,
										decoration: const BoxDecoration(
											shape: BoxShape.circle,
											color: Color(0xFF00F0FF),
										),
									),
								]
							],
						),
						const SizedBox(height: 6),
						Text(
							msg.content,
							style: TextStyle(
								color: isUser ? Colors.white : const Color(0xFFE2F0FF),
								fontSize: 13,
								height: 1.4,
							),
						),
					],
				),
			),
		);
	}

	Widget _buildThinkingBubble() {
		return Align(
			alignment: Alignment.centerLeft,
			child: Container(
				margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
				padding: const EdgeInsets.all(12),
				decoration: BoxDecoration(
					color: const Color(0xFF0A162B).withOpacity(0.65),
					borderRadius: const BorderRadius.only(
						topLeft: Radius.circular(12),
						topRight: Radius.circular(12),
						bottomRight: Radius.circular(12),
					),
					border: Border.all(
						color: const Color(0xFF00F0FF).withOpacity(0.1),
						width: 1,
					),
				),
				child: Row(
					mainAxisSize: MainAxisSize.min,
					children: [
						const SizedBox(
							width: 12,
							height: 12,
							child: CircularProgressIndicator(
								strokeWidth: 1.5,
								color: Color(0xFF00F0FF),
							),
						),
						const SizedBox(width: 10),
						Text(
							"思考中...",
							style: TextStyle(
								color: Colors.blueGrey.shade400,
								fontSize: 12,
							),
						),
					],
				),
			),
		);
	}

	@override
	Widget build(BuildContext context) {
		final ampRatio = ref.watch(amplitudeProvider);

		return Scaffold(
			backgroundColor: const Color(0xFF030914), // 科幻暗黑背景
			appBar: AppBar(
				backgroundColor: Colors.transparent,
				elevation: 0,
				leading: IconButton(
					icon: const Icon(Icons.arrow_back_ios_new, color: Colors.blueGrey),
					onPressed: () => Navigator.pop(context),
				),
				title: Text(
					"J.A.R.V.I.S VOICE CABIN",
					style: GoogleFonts.orbitron(
						color: const Color(0xFF00F0FF),
						fontSize: 16,
						fontWeight: FontWeight.bold,
						letterSpacing: 2.0,
					),
				),
				centerTitle: true,
			),
			body: Column(
				children: [
					const SizedBox(height: 40),
					// 顶部的状态与提示文字
					Padding(
						padding: const EdgeInsets.symmetric(horizontal: 24.0),
						child: Text(
							_statusText,
							textAlign: TextAlign.center,
							style: TextStyle(
								color: Colors.blueGrey.shade200,
								fontSize: 14,
								height: 1.5,
							),
						),
					),
					
					const Spacer(),

					// 核心区域：钢铁侠能量反应堆
					GestureDetector(
						onTap: () {
							if (_isRecording) {
								_stopIngestion();
							} else {
								_startIngestion();
							}
						},
						child: Stack(
							alignment: Alignment.center,
							children: [
								// 呼吸发光背影圈
								Container(
									width: 260,
									height: 260,
									decoration: BoxDecoration(
										shape: BoxShape.circle,
										boxShadow: [
											BoxShadow(
												color: const Color(0xFF00F0FF).withOpacity(
													_isRecording 
														? 0.15 + (ampRatio * 0.2)
														: _isPlayingTTS ? 0.2 : 0.08
												),
												blurRadius: 40 + (ampRatio * 30),
												spreadRadius: 5,
											)
										],
									),
								),
								// CustomPainter 能量反应堆核心
								AnimatedBuilder(
									animation: _reactorController,
									builder: (context, child) {
										return CustomPaint(
											size: const Size(220, 220),
											painter: ArcReactorPainter(
												progress: _reactorController.value,
												amplitude: ampRatio,
												isRecording: _isRecording,
												isThinking: _isThinking,
												isPlaying: _isPlayingTTS,
											),
										);
									},
								),
								// 中心圆孔与麦克风指示
								Icon(
									_isRecording 
										? Icons.mic 
										: _isPlayingTTS 
											? Icons.volume_up 
											: Icons.power_settings_new,
									size: 32,
									color: _isRecording
										? const Color(0xFF00F0FF)
										: _isPlayingTTS
											? const Color(0xFF00FF88)
											: Colors.blueGrey.shade300,
								),
							],
						),
					),

					const Spacer(),

					// 底部动态文本板（展现多轮流式对话历史）
					Container(
						width: double.infinity,
						height: 220,
						margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
						padding: const EdgeInsets.all(12),
						decoration: BoxDecoration(
							color: const Color(0xFF061022).withOpacity(0.5),
							borderRadius: BorderRadius.circular(16),
							border: Border.all(
								color: const Color(0xFF00F0FF).withOpacity(0.12),
								width: 1,
							),
							boxShadow: [
								BoxShadow(
									color: const Color(0xFF00F0FF).withOpacity(0.02),
									blurRadius: 10,
									spreadRadius: 2,
								)
							],
						),
						child: ClipRRect(
							borderRadius: BorderRadius.circular(12),
							child: ShaderMask(
								shaderCallback: (Rect bounds) {
									return const LinearGradient(
										begin: Alignment.topCenter,
										end: Alignment.bottomCenter,
										colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
										stops: [0.0, 0.08, 0.92, 1.0],
									).createShader(bounds);
								},
								blendMode: BlendMode.dstIn,
								child: ListView.builder(
									controller: _scrollController,
									physics: const BouncingScrollPhysics(),
									itemCount: _messages.length + (_isThinking ? 1 : 0),
									itemBuilder: (context, index) {
										if (index == _messages.length && _isThinking) {
											return _buildThinkingBubble();
										}
										final msg = _messages[index];
										return _buildChatBubble(msg);
									},
								),
							),
						),
					),
					const SizedBox(height: 8),
				],
			),
		);
	}
}

// 钢铁侠能量反应堆 CustomPainter 绘制逻辑
class ArcReactorPainter extends CustomPainter {
	final double progress;
	final double amplitude;
	final bool isRecording;
	final bool isThinking;
	final bool isPlaying;

	ArcReactorPainter({
		required this.progress,
		required this.amplitude,
		required this.isRecording,
		required this.isThinking,
		required this.isPlaying,
	});

	@override
	void paint(Canvas canvas, Size size) {
		final center = Offset(size.width / 2, size.height / 2);
		final radius = size.width / 2;

		// 基础颜色设定
		final colorCore = isRecording 
			? const Color(0xFF00F0FF) // 录音中：科幻极客蓝
			: isPlaying 
				? const Color(0xFF00FF88) // 播放中：原声绿
				: const Color(0xFF00A0FF).withOpacity(0.7);

		final paintCore = Paint()
			..color = colorCore
			..style = PaintingStyle.stroke
			..strokeWidth = 2.0;

		// 1. 绘制最外侧虚线圈与轨道环
		final outerRadius = radius * 0.95;
		canvas.drawCircle(center, outerRadius, Paint()
			..color = colorCore.withOpacity(0.1)
			..style = PaintingStyle.stroke
			..strokeWidth = 1.0
		);

		// 2. 绘制 10 个能量喷射叶片
		final numSegments = 10;
		final segmentAngle = (2 * math.pi) / numSegments;
		final rotateAngle = progress * 2 * math.pi * 0.05; // 缓慢旋转进度

		for (int i = 0; i < numSegments; i++) {
			final angle = i * segmentAngle + rotateAngle;
			
			// 振幅会让喷射叶片向外伸缩振荡
			final extraLen = isRecording ? amplitude * 12.0 : isPlaying ? (math.sin(progress * 20 + i) * 6.0) : 0.0;
			final innerR = radius * 0.6;
			final outerR = radius * 0.85 + extraLen;

			final start = Offset(
				center.dx + innerR * math.cos(angle),
				center.dy + innerR * math.sin(angle),
			);
			final end = Offset(
				center.dx + outerR * math.cos(angle),
				center.dy + outerR * math.sin(angle),
			);

			final paintBlade = Paint()
				..color = colorCore.withOpacity(isRecording ? 0.7 + (amplitude * 0.3) : 0.4)
				..style = PaintingStyle.stroke
				..strokeWidth = 5.0
				..strokeCap = StrokeCap.round;

			canvas.drawLine(start, end, paintBlade);
		}

		// 3. 绘制核心两个环
		final innerRingRadius = radius * 0.5;
		canvas.drawCircle(center, innerRingRadius, paintCore..strokeWidth = 1.5);

		// 核心发光发热扩散涟漪效果
		if (isRecording || isPlaying || isThinking) {
			final waveRadius = radius * (0.5 + (progress % 0.5));
			canvas.drawCircle(center, waveRadius, Paint()
				..color = colorCore.withOpacity(1.0 - (progress % 0.5) * 2.0)
				..style = PaintingStyle.stroke
				..strokeWidth = 1.0
			);
		}

		// 4. 绘制围绕核心的多圈细小刻度
		final numTicks = 60;
		final tickAngle = (2 * math.pi) / numTicks;
		for (int i = 0; i < numTicks; i++) {
			final angle = i * tickAngle - rotateAngle * 0.5;
			final isLong = i % 6 == 0;
			final rStart = radius * 0.90;
			final rEnd = radius * (isLong ? 0.82 : 0.86);

			final start = Offset(
				center.dx + rStart * math.cos(angle),
				center.dy + rStart * math.sin(angle),
			);
			final end = Offset(
				center.dx + rEnd * math.cos(angle),
				center.dy + rEnd * math.sin(angle),
			);

			canvas.drawLine(start, end, Paint()
				..color = colorCore.withOpacity(isLong ? 0.5 : 0.2)
				..style = PaintingStyle.stroke
				..strokeWidth = isLong ? 1.5 : 1.0
			);
		}
	}

	@override
	bool shouldRepaint(covariant ArcReactorPainter oldDelegate) {
		return oldDelegate.progress != progress ||
				oldDelegate.amplitude != amplitude ||
				oldDelegate.isRecording != isRecording ||
				oldDelegate.isThinking != isThinking ||
				oldDelegate.isPlaying != isPlaying;
	}
}

class VoiceMessage {
	final String role; // 'user' | 'assistant'
	String content;
	bool isStreaming;

	VoiceMessage({
		required this.role,
		required this.content,
		this.isStreaming = false,
	});
}
