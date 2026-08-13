import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/assistant_provider.dart';
import '../services/api_service.dart';
import '../utils/crypto_helper.dart';

class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key});

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  // 对话模型控制器与状态
  final _chatApiKeyController = TextEditingController();
  final _chatBaseUrlController = TextEditingController();
  final _chatModelController = TextEditingController();
  String _chatProvider = 'openai';

  // 视觉多模态模型控制器与状态
  final _visionApiKeyController = TextEditingController();
  final _visionBaseUrlController = TextEditingController();
  final _visionModelController = TextEditingController();
  String _visionProvider = 'openai';

  // 向量模型控制器与状态
  final _embedApiKeyController = TextEditingController();
  final _embedBaseUrlController = TextEditingController();
  final _embedModelController = TextEditingController();
  String _embedProvider = 'openai';

  // 语音模型控制器与状态
  final _sttApiKeyController = TextEditingController();
  final _sttBaseUrlController = TextEditingController();
  final _sttModelController = TextEditingController();
  String _sttProvider = 'openai';

  // TTS音色与配置
  String _ttsVoice = 'alloy';
  String _ttsProvider = 'openai';
  final _ttsApiKeyController = TextEditingController();
  final _ttsBaseUrlController = TextEditingController();
  final _ttsModelController = TextEditingController();
  final _barkKeyController = TextEditingController();

  // API Token 安全令牌控制器
  final _apiTokenController = TextEditingController();
  
  // 后端服务器地址控制器
  final _serverUrlController = TextEditingController();
  bool _isTestingConnection = false;

  // 高级配置变量
  bool _localMode = false;
  final _ollamaBaseController = TextEditingController();
  bool _e2eeEnabled = false;
  final _e2eeKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final config = ref.read(configProvider);
      setState(() {
        _chatProvider = config.chatProvider;
        _chatApiKeyController.text = config.chatAPIKey;
        _chatBaseUrlController.text = config.chatBaseURL;
        _chatModelController.text = config.chatModel;

        _visionProvider = config.visionProvider;
        _visionApiKeyController.text = config.visionAPIKey;
        _visionBaseUrlController.text = config.visionBaseURL;
        _visionModelController.text = config.visionModel;

        _embedProvider = config.embedProvider;
        _embedApiKeyController.text = config.embedAPIKey;
        _embedBaseUrlController.text = config.embedBaseURL;
        _embedModelController.text = config.embedModel;

        _sttProvider = config.sttProvider;
        _sttApiKeyController.text = config.sttAPIKey;
        _sttBaseUrlController.text = config.sttBaseURL;
        _sttModelController.text = config.sttModel;

        _ttsVoice = config.ttsVoice.isNotEmpty ? config.ttsVoice : 'alloy';
        _ttsProvider = config.ttsProvider.isNotEmpty ? config.ttsProvider : 'openai';
        _ttsApiKeyController.text = config.ttsAPIKey;
        _ttsBaseUrlController.text = config.ttsBaseURL;
        _ttsModelController.text = config.ttsModel.isNotEmpty ? config.ttsModel : 'tts-1';
        _barkKeyController.text = config.barkKey;
      });
    });

    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _apiTokenController.text = prefs.getString('api_token') ?? '';
          _serverUrlController.text = prefs.getString('server_base_url') ?? APIService.defaultBaseURL;
          _localMode = prefs.getBool('local_mode') ?? false;
          _ollamaBaseController.text = prefs.getString('ollama_api_base') ?? 'http://host.docker.internal:11434';
          final savedE2eeKey = prefs.getString('e2ee_key') ?? '';
          _e2eeEnabled = savedE2eeKey.isNotEmpty;
          _e2eeKeyController.text = savedE2eeKey;
        });
      }
    });
  }

  @override
  void dispose() {
    _chatApiKeyController.dispose();
    _chatBaseUrlController.dispose();
    _chatModelController.dispose();

    _visionApiKeyController.dispose();
    _visionBaseUrlController.dispose();
    _visionModelController.dispose();

    _embedApiKeyController.dispose();
    _embedBaseUrlController.dispose();
    _embedModelController.dispose();

    _sttApiKeyController.dispose();
    _sttBaseUrlController.dispose();
    _sttModelController.dispose();
    _ttsApiKeyController.dispose();
    _ttsBaseUrlController.dispose();
    _ttsModelController.dispose();
    _barkKeyController.dispose();
    _apiTokenController.dispose();
    _serverUrlController.dispose();
    _ollamaBaseController.dispose();
    _e2eeKeyController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() => _isTestingConnection = true);
    try {
      final testService = APIService(serverBaseURL: _serverUrlController.text.trim());
      final isHealthy = await testService.checkServerHealth();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isHealthy ? '✅ 连接成功！后端服务运行正常' : '❌ 连接失败：服务器无响应'),
          backgroundColor: isHealthy ? Colors.green : Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 连接失败：$e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isTestingConnection = false);
      }
    }
  }

  void _saveSettings() {
    ref.read(configProvider.notifier).updateConfig(
          chatProvider: _chatProvider,
          chatAPIKey: _chatApiKeyController.text.trim(),
          chatBaseURL: _chatBaseUrlController.text.trim(),
          chatModel: _chatModelController.text.trim(),

          visionProvider: _visionProvider,
          visionAPIKey: _visionApiKeyController.text.trim(),
          visionBaseURL: _visionBaseUrlController.text.trim(),
          visionModel: _visionModelController.text.trim(),

          embedProvider: _embedProvider,
          embedAPIKey: _embedApiKeyController.text.trim(),
          embedBaseURL: _embedBaseUrlController.text.trim(),
          embedModel: _embedModelController.text.trim(),

          sttProvider: _sttProvider,
          sttAPIKey: _sttApiKeyController.text.trim(),
          sttBaseURL: _sttBaseUrlController.text.trim(),
          sttModel: _sttModelController.text.trim(),
          ttsProvider: _ttsProvider,
          ttsAPIKey: _ttsApiKeyController.text.trim(),
          ttsBaseURL: _ttsBaseUrlController.text.trim(),
          ttsModel: _ttsModelController.text.trim(),
          ttsVoice: _ttsVoice,
          barkKey: _barkKeyController.text.trim(),
        );

    // 保存服务器地址到 SharedPreferences 并通知 Provider 热更新
    final serverUrl = _serverUrlController.text.trim();
    ref.read(serverUrlProvider.notifier).updateUrl(serverUrl);

    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('api_token', _apiTokenController.text.trim());
      prefs.setBool('local_mode', _localMode);
      prefs.setString('ollama_api_base', _ollamaBaseController.text.trim());
      if (_e2eeEnabled) {
        prefs.setString('e2ee_key', _e2eeKeyController.text.trim());
      } else {
        prefs.remove('e2ee_key');
        prefs.remove('e2ee_last_sync_time');
      }
    });

    // 触发刷新数据
    ref.read(assistantProvider.notifier).refreshAll();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('配置已保存！'),
        backgroundColor: Colors.purple,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0E17),
        elevation: 0,
        title: Text(
          '算力与多模型混用配置',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'BYOK (Bring Your Own Key) 多微服务源控制中心',
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 20),

            // 0. 后端服务器地址配置 Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E29),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🌐 后端服务器地址 (Server URL)',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.cyanAccent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '配置后端的 IP 地址与端口。若 WiFi/网络环境切换后连不上，请更新此地址。',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _serverUrlController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '例如: http://192.168.1.100:8082',
                      hintStyle: const TextStyle(color: Colors.white24),
                      labelText: '服务器地址',
                      labelStyle: const TextStyle(color: Colors.cyanAccent),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: const BorderSide(color: Colors.cyanAccent),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent.withOpacity(0.15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: Colors.cyanAccent.withOpacity(0.4)),
                        ),
                      ),
                      icon: _isTestingConnection
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.cyanAccent,
                              ),
                            )
                          : const Icon(Icons.wifi_find, color: Colors.cyanAccent, size: 20),
                      label: Text(
                        _isTestingConnection ? '连接测试中...' : '测试连接',
                        style: GoogleFonts.outfit(color: Colors.cyanAccent),
                      ),
                      onPressed: _isTestingConnection ? null : _testConnection,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 1. 对话大模型 Card
            _buildModelCard(
              title: '💬 对话大模型 (Chat Model)',
              provider: _chatProvider,
              apiKeyController: _chatApiKeyController,
              baseUrlController: _chatBaseUrlController,
              modelController: _chatModelController,
              modelHint: '例如: gpt-4o-mini 或 qwen2.5:7b',
              onProviderChanged: (val) {
                if (val != null) {
                  setState(() {
                    _chatProvider = val;
                    if (val == 'local') {
                      _chatBaseUrlController.text = 'http://host.docker.internal:11434/v1';
                      _chatApiKeyController.text = 'ollama';
                      _chatModelController.text = 'qwen2.5:7b';
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 24),

            // 2. 视觉大模型 Card
            _buildModelCard(
              title: '🖼️ 视觉大模型 (Vision Model - 可选)',
              subtitle: '若为空则自动降级复用对话大模型的所有配置',
              provider: _visionProvider,
              apiKeyController: _visionApiKeyController,
              baseUrlController: _visionBaseUrlController,
              modelController: _visionModelController,
              modelHint: '例如: qwen2-vl 或 gpt-4o-mini',
              onProviderChanged: (val) {
                if (val != null) {
                  setState(() {
                    _visionProvider = val;
                    if (val == 'local') {
                      _visionBaseUrlController.text = 'http://host.docker.internal:11434/v1';
                      _visionApiKeyController.text = 'ollama';
                      _visionModelController.text = 'qwen2-vl';
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 24),

            // 3. 向量大模型 Card
            _buildModelCard(
              title: '📐 向量嵌入大模型 (Embedding Model)',
              provider: _embedProvider,
              apiKeyController: _embedApiKeyController,
              baseUrlController: _embedBaseUrlController,
              modelController: _embedModelController,
              modelHint: '例如: text-embedding-3-small 或 mxbai-embed-large',
              onProviderChanged: (val) {
                if (val != null) {
                  setState(() {
                    _embedProvider = val;
                    if (val == 'local') {
                      _embedBaseUrlController.text = 'http://host.docker.internal:11434/v1';
                      _embedApiKeyController.text = 'ollama';
                      _embedModelController.text = 'mxbai-embed-large';
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 24),

            // 5. 语音转文字模型 Card
            _buildModelCard(
              title: '🎙️ 语音转文字模型 (STT Model)',
              provider: _sttProvider,
              apiKeyController: _sttApiKeyController,
              baseUrlController: _sttBaseUrlController,
              modelController: _sttModelController,
              modelHint: '例如: whisper-1',
              onProviderChanged: (val) {
                if (val != null) {
                  setState(() {
                    _sttProvider = val;
                    if (val == 'local') {
                      _sttBaseUrlController.text = 'http://host.docker.internal:11434/v1';
                      _sttApiKeyController.text = 'ollama';
                      _sttModelController.text = 'whisper-1';
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 24),

            // 6. 语音合成与锁屏推送 Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E29),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blueAccent.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🔊 语音合成与锁屏推送 (TTS & Bark)',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFFF8906),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // TTS Voice
                  Text('TTS 伴随音色', style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F0E17),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _ttsVoice,
                        dropdownColor: const Color(0xFF1F1E29),
                        style: GoogleFonts.outfit(color: Colors.white, fontSize: 15),
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(value: 'alloy', child: Text('Alloy (自然中性)')),
                          DropdownMenuItem(value: 'echo', child: Text('Echo (温和男声)')),
                          DropdownMenuItem(value: 'fable', child: Text('Fable (故事男声)')),
                          DropdownMenuItem(value: 'onyx', child: Text('Onyx (雄浑男声)')),
                          DropdownMenuItem(value: 'nova', child: Text('Nova (明亮女声)')),
                          DropdownMenuItem(value: 'shimmer', child: Text('Shimmer (温柔女声)')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _ttsVoice = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // TTS Provider
                  Text('语音合成服务商 (TTS Provider)', style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F0E17),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _ttsProvider,
                        dropdownColor: const Color(0xFF1F1E29),
                        style: GoogleFonts.outfit(color: Colors.white, fontSize: 15),
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(value: 'openai', child: Text('OpenAI 协议 (含各兼容中转)')),
                          DropdownMenuItem(value: 'local', child: Text('Local / Ollama 本地模型')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _ttsProvider = val;
                              if (val == 'local') {
                                _ttsBaseUrlController.text = 'http://host.docker.internal:11434/v1';
                                _ttsApiKeyController.text = 'ollama';
                                _ttsModelController.text = 'tts-1';
                              }
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // TTS Base URL
                  _buildCardTextField(
                    controller: _ttsBaseUrlController,
                    label: 'TTS 接口地址 (TTS Base URL - 留空则复用对话配置)',
                    hint: '例如: https://api.openai.com/v1',
                  ),
                  const SizedBox(height: 14),

                  // TTS API Key
                  _buildCardTextField(
                    controller: _ttsApiKeyController,
                    label: 'TTS 密钥 (TTS API Key - 留空则复用对话配置)',
                    hint: '填入 API 密钥',
                    obscureText: true,
                  ),
                  const SizedBox(height: 14),

                  // TTS Model Name
                  _buildCardTextField(
                    controller: _ttsModelController,
                    label: 'TTS 模型名称 (TTS Model Name - 留空则复用对话配置)',
                    hint: '例如: tts-1',
                  ),
                  const SizedBox(height: 14),

                  // Bark Key
                  _buildCardTextField(
                    controller: _barkKeyController,
                    label: 'Bark 锁屏推送密钥 (Bark Key - iOS推送服务，安卓请留空)',
                    hint: '输入 Bark App 密钥，例如: eyJhbGciOi...',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),

            // 0. 安全认证令牌 Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E29),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.redAccent.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🔑 后端访问安全令牌 (API Access Token)',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '若后端配置了 APP_API_TOKEN 环境变量，必须在此配置对应的 Token 才能发起请求，以防公网暴露造成数据泄露。',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _apiTokenController,
                    style: const TextStyle(color: Colors.white),
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: '请输入访问安全令牌 (留空表示无需认证)',
                      hintStyle: const TextStyle(color: Colors.white24),
                      labelText: 'API Token',
                      labelStyle: const TextStyle(color: Colors.redAccent),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: const BorderSide(color: Colors.redAccent),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 8. 高级安全与本地离线配置 Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E29),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.amberAccent.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🛡️ 高级安全与本地离线自愈',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.amberAccent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '配置端到端加密密钥与本地离线运行模式，确保断网生存能力及隐私数据物理主权。',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),

                  // 1. 本地离线自愈模式 Switch
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🔌 本地离线自愈模式 (Local Mode)',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '激活后后端将自适应 Fallback 至局域网 Ollama',
                            style: GoogleFonts.outfit(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                      Switch(
                        value: _localMode,
                        activeColor: Colors.amberAccent,
                        onChanged: (val) {
                          setState(() {
                            _localMode = val;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // 2. Ollama Base URL TextField
                  if (_localMode) ...[
                    _buildCardTextField(
                      controller: _ollamaBaseController,
                      label: 'Ollama 接口地址 (Ollama API Base)',
                      hint: '例如: http://192.168.1.100:11434',
                    ),
                    const SizedBox(height: 16),
                  ],

                  const Divider(color: Colors.white10),
                  const SizedBox(height: 8),

                  // 3. E2EE 端到端加密 Switch
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🔏 端到端加密盲同步 (E2EE)',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '开启后，所有写入和拉取的数据均在本地执行加解密',
                            style: GoogleFonts.outfit(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                      Switch(
                        value: _e2eeEnabled,
                        activeColor: Colors.amberAccent,
                        onChanged: (val) {
                          setState(() {
                            _e2eeEnabled = val;
                            if (val && _e2eeKeyController.text.isEmpty) {
                              _e2eeKeyController.text = CryptoHelper.generateAESKey();
                            }
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // 4. E2EE Key TextField & Actions
                  if (_e2eeEnabled) ...[
                    _buildCardTextField(
                      controller: _e2eeKeyController,
                      label: '数字主权对称密钥 (AES Base64Url Key)',
                      hint: '32字节 Base64Url 对称密钥，请务必妥善保管',
                      obscureText: true,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white24),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: const Icon(Icons.autorenew, color: Colors.white70, size: 16),
                            label: Text(
                              '重新生成',
                              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13),
                            ),
                            onPressed: () {
                              setState(() {
                                _e2eeKeyController.text = CryptoHelper.generateAESKey();
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已重新生成 E2EE 对称密钥，点击保存生效！'),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white24),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: const Icon(Icons.copy, color: Colors.white70, size: 16),
                            label: Text(
                              '复制密钥',
                              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13),
                            ),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _e2eeKeyController.text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('密钥已成功复制到剪贴板！'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 保存按钮
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF8906),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saveSettings,
                child: Text(
                  '保存并部署到后台',
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildModelCard({
    required String title,
    String? subtitle,
    required String provider,
    required TextEditingController apiKeyController,
    required TextEditingController baseUrlController,
    required TextEditingController modelController,
    required String modelHint,
    required ValueChanged<String?> onProviderChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurple.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: const Color(0xFFFF8906),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),

          // Provider
          Text('服务协议 (Provider)', style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0E17),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: provider,
                dropdownColor: const Color(0xFF1F1E29),
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'openai', child: Text('OpenAI 协议 (含 DeepSeek/硅基)')),
                  DropdownMenuItem(value: 'claude', child: Text('Claude 协议')),
                  DropdownMenuItem(value: 'local', child: Text('Local / Ollama 本地模型')),
                ],
                onChanged: onProviderChanged,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Base URL
          _buildCardTextField(
            controller: baseUrlController,
            label: '接口地址 (Base URL)',
            hint: '例如: https://api.openai.com/v1',
          ),
          const SizedBox(height: 14),

          // API Key
          _buildCardTextField(
            controller: apiKeyController,
            label: '密钥 (API Key / Auth Token)',
            hint: '填入 API 密钥',
            obscureText: true,
          ),
          const SizedBox(height: 14),

          // Model Name
          _buildCardTextField(
            controller: modelController,
            label: '模型名称 (Model Name)',
            hint: modelHint,
          ),
        ],
      ),
    );
  }

  Widget _buildCardTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscureText = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 14,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: GoogleFonts.outfit(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.outfit(color: Colors.grey, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF0F0E17),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFFF8906), width: 1.0),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }
}
