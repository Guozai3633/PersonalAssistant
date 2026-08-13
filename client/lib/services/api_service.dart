import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_config.dart';
import '../models/chat_result.dart';
import '../models/memory.dart';
import '../utils/crypto_helper.dart';

class APIService {
  final String serverBaseURL;

  /// 默认后端地址（当 SharedPreferences 中尚未配置时使用）
  static const String defaultBaseURL = 'http://10.103.229.101:8082';

  APIService({this.serverBaseURL = defaultBaseURL});

  /// 从持久化存储中读取用户配置的后端地址来创建实例
  static Future<APIService> fromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_base_url');
    if (url != null && url.isNotEmpty) {
      return APIService(serverBaseURL: url);
    }
    return APIService();
  }

  // 辅助方法：统一注入 API 访问令牌（X-App-Token 或 Authorization: Bearer）
  Future<Map<String, String>> _buildHeaders(
      [Map<String, String>? aiHeaders]) async {
    final Map<String, String> headers = {
      'Content-Type': 'application/json',
    };
    if (aiHeaders != null) {
      headers.addAll(aiHeaders);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('api_token') ?? '';
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
        headers['X-App-Token'] = token;
      }

      // 注入本地离线自愈标头
      final localMode = prefs.getBool('local_mode') ?? false;
      headers['X-Local-Mode'] = localMode ? 'true' : 'false';
      final ollamaBase = prefs.getString('ollama_api_base') ??
          'http://host.docker.internal:11434';
      headers['X-Ollama-API-Base'] = ollamaBase;
    } catch (_) {}

    return headers;
  }

  // Ingest: 录入非结构化记忆
  Future<Memory> ingest(String content, String sourceType, String sourceMeta,
      AIConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final e2eeKey = prefs.getString('e2ee_key') ?? '';
    final bool isEncrypted = e2eeKey.isNotEmpty;

    String processedContent = content;
    String title = '';
    List<String> tags = [];

    if (isEncrypted) {
      processedContent = CryptoHelper.encryptText(content, e2eeKey);
      title = CryptoHelper.encryptText('密文笔记', e2eeKey);
      tags = [CryptoHelper.encryptText('密文', e2eeKey)];
    }

    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/memories/ingest'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode({
            'content': processedContent,
            'source_type': sourceType,
            'source_meta': sourceMeta,
            'is_encrypted': isEncrypted,
            'title': title,
            'tags': tags,
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode == 201) {
      final mem = Memory.fromJson(jsonDecode(response.body));
      if (isEncrypted) {
        return mem.copyWith(
          rawContent: CryptoHelper.decryptText(mem.rawContent, e2eeKey),
          originalContent:
              CryptoHelper.decryptText(mem.originalContent, e2eeKey),
          title: CryptoHelper.decryptText(mem.title, e2eeKey),
          tags: mem.tags
              .map((t) => CryptoHelper.decryptText(t, e2eeKey))
              .toList(),
        );
      }
      return mem;
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to ingest memory (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // FetchMemories: 分页加载事实列表
  Future<List<Memory>> fetchMemories(int page, int pageSize) async {
    final response = await http
        .get(
          Uri.parse(
              '$serverBaseURL/api/memories?page=$page&pageSize=$pageSize'),
          headers: await _buildHeaders(),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body);
      final prefs = await SharedPreferences.getInstance();
      final e2eeKey = prefs.getString('e2ee_key') ?? '';
      final List<Memory> list =
          body.map((dynamic item) => Memory.fromJson(item)).toList();
      if (e2eeKey.isNotEmpty) {
        return list
            .map((mem) => mem.copyWith(
                  rawContent: CryptoHelper.decryptText(mem.rawContent, e2eeKey),
                  originalContent:
                      CryptoHelper.decryptText(mem.originalContent, e2eeKey),
                  title: CryptoHelper.decryptText(mem.title, e2eeKey),
                  tags: mem.tags
                      .map((t) => CryptoHelper.decryptText(t, e2eeKey))
                      .toList(),
                ))
            .toList();
      }
      return list;
    } else {
      throw Exception('Failed to load memories (HTTP ${response.statusCode})');
    }
  }

  Future<Memory> fetchMemory(String id) async {
    final response = await http
        .get(
          Uri.parse(
              '$serverBaseURL/api/memories?id=${Uri.encodeQueryComponent(id)}'),
          headers: await _buildHeaders(),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to load memory (HTTP ${response.statusCode}): ${response.body}');
    }

    var memory =
        Memory.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    final prefs = await SharedPreferences.getInstance();
    final e2eeKey = prefs.getString('e2ee_key') ?? '';
    if (e2eeKey.isNotEmpty) {
      memory = memory.copyWith(
        rawContent: CryptoHelper.decryptText(memory.rawContent, e2eeKey),
        originalContent:
            CryptoHelper.decryptText(memory.originalContent, e2eeKey),
        title: CryptoHelper.decryptText(memory.title, e2eeKey),
        tags: memory.tags
            .map((tag) => CryptoHelper.decryptText(tag, e2eeKey))
            .toList(),
      );
    }
    return memory;
  }

  // RetryMemoryProcessing: 重试失败或中断的后台解析任务
  Future<Memory> retryMemoryProcessing(String id, AIConfig config) async {
    final response = await http
        .post(
          Uri.parse(
              '$serverBaseURL/api/memories/retry?id=${Uri.encodeQueryComponent(id)}'),
          headers: await _buildHeaders(config.toHeaders()),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 202) {
      return Memory.fromJson(jsonDecode(response.body));
    }

    String errorMessage = response.body;
    try {
      final body = jsonDecode(response.body);
      errorMessage = body['error'] ?? errorMessage;
    } catch (_) {}
    throw Exception(
        'Failed to retry memory processing (HTTP ${response.statusCode}): $errorMessage');
  }

  // DeleteMemory: 物理删除向量与软删除 SQLite 记录
  Future<void> deleteMemory(String id, AIConfig config) async {
    final response = await http
        .delete(
          Uri.parse('$serverBaseURL/api/memories?id=$id'),
          headers: await _buildHeaders(config.toHeaders()),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 204) {
      throw Exception(
          'Failed to delete memory (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  // Ask: RAG 双轨检索生成对话
  Future<ChatResult> ask(
      String query, String sessionId, AIConfig config) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/chat'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode({
            'query': query,
            'session_id': sessionId,
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return ChatResult.fromJson(body);
    } else {
      throw Exception('Failed to ask AI (HTTP ${response.statusCode})');
    }
  }

  // FetchChatHistory: 获取聊天历史消息
  Future<List<Map<String, dynamic>>> fetchChatHistory(String sessionId) async {
    final response = await http
        .get(
          Uri.parse('$serverBaseURL/api/chat/messages?session_id=$sessionId'),
          headers: await _buildHeaders(),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final List<dynamic> body = jsonDecode(response.body);
      return body.map((dynamic item) => item as Map<String, dynamic>).toList();
    } else {
      throw Exception(
          'Failed to load chat history (HTTP ${response.statusCode})');
    }
  }

  // FetchDashboardStats: 读取系统健康及吞吐量指标
  Future<Map<String, dynamic>> fetchDashboardStats(AIConfig config) async {
    final response = await http
        .get(
          Uri.parse('$serverBaseURL/api/dashboard/stats'),
          headers: await _buildHeaders(config.toHeaders()),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
          'Failed to load metrics (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  // IngestAudio: 上传音频文件并转译录入
  Future<Memory> ingestAudio(String filePath, AIConfig config) async {
    final file = io.File(filePath);
    if (!await file.exists()) {
      throw Exception('Audio file not found at $filePath');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$serverBaseURL/api/memories/ingest-audio'),
    );

    request.headers.addAll(await _buildHeaders(config.toHeaders()));
    request.files.add(await http.MultipartFile.fromPath(
      'audio',
      file.path,
    ));

    final streamedResponse =
        await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      return Memory.fromJson(jsonDecode(response.body));
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to ingest audio (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // CheckServerHealth: 检查后端服务是否可达
  Future<bool> checkServerHealth() async {
    try {
      final response = await http
          .get(
            Uri.parse('$serverBaseURL/health'),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // TranscribeAudio: 上传音频文件执行纯转译不入库
  Future<String> transcribeAudio(String filePath, AIConfig config) async {
    final file = io.File(filePath);
    if (!await file.exists()) {
      throw Exception('Audio file not found at $filePath');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$serverBaseURL/api/audio/transcribe'),
    );

    request.headers.addAll(await _buildHeaders(config.toHeaders()));
    request.files.add(await http.MultipartFile.fromPath('audio', file.path));

    final streamedResponse =
        await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      return body['text'] ?? '';
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to transcribe audio (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // PerformOCR: 传递 Base64 图片数据得到识别文本
  Future<String> performOCR(String base64Data, AIConfig config) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/ocr'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode({'base64_data': base64Data}),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      return body['text'] ?? '';
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to OCR image (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // UpdateMemory: 更新已有记忆
  Future<void> updateMemory(Memory memory, AIConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final e2eeKey = prefs.getString('e2ee_key') ?? '';
    final bool isEncrypted = e2eeKey.isNotEmpty;

    Memory memToSend = memory;
    if (isEncrypted) {
      memToSend = memory.copyWith(
        rawContent: CryptoHelper.encryptText(memory.rawContent, e2eeKey),
        originalContent:
            CryptoHelper.encryptText(memory.originalContent, e2eeKey),
        title: CryptoHelper.encryptText(
            memory.title.isNotEmpty ? memory.title : '密文笔记', e2eeKey),
        tags: memory.tags
            .map((t) => CryptoHelper.encryptText(t, e2eeKey))
            .toList(),
      );
    }

    final response = await http
        .put(
          Uri.parse('$serverBaseURL/api/memories'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode(memToSend.toJson()),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 204) {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to update memory (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // GenerateTTS: 将文本转为语音音频数据
  Future<Uint8List> generateTTS(String text, AIConfig config) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/audio/tts'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to generate TTS (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // SummarizeMemories: 融合所选记忆生成长文总结
  Future<String> summarizeMemories(List<String> ids, AIConfig config) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/memories/summarize'),
          headers: await _buildHeaders(config.toHeaders()),
          body: jsonEncode({'ids': ids}),
        )
        .timeout(const Duration(seconds: 180));

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      return body['summary'] ?? '';
    } else {
      String errorMsg;
      try {
        final errorBody = jsonDecode(response.body);
        errorMsg = errorBody['error'] ?? errorBody.toString();
      } catch (_) {
        errorMsg = response.body;
      }
      throw Exception(
          'Failed to summarize memories (HTTP ${response.statusCode}): $errorMsg');
    }
  }

  // FetchMindGraph: 获取思维脑图的神经拓扑图谱数据
  Future<Map<String, dynamic>> fetchMindGraph() async {
    final response = await http
        .get(
          Uri.parse('$serverBaseURL/api/dashboard/mind-graph'),
          headers: await _buildHeaders(),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final Map<String, dynamic> data =
          jsonDecode(response.body) as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      final e2eeKey = prefs.getString('e2ee_key') ?? '';
      if (e2eeKey.isNotEmpty) {
        final List<dynamic> nodes = data['nodes'] ?? [];
        for (final n in nodes) {
          final label = n['label'] ?? '';
          n['label'] = CryptoHelper.decryptText(label, e2eeKey);
        }
        final List<dynamic> links = data['links'] ?? [];
        for (final l in links) {
          final label = l['label'];
          if (label != null) {
            l['label'] = CryptoHelper.decryptText(label, e2eeKey);
          }
        }
      }
      return data;
    } else {
      throw Exception(
          'Failed to load mind graph (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  // SyncE2EE: 盲同步加密数据
  Future<Map<String, dynamic>> syncE2EE(
      int lastSyncTime, List<Memory> changes) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/e2ee/sync'),
          headers: await _buildHeaders(),
          body: jsonEncode({
            'last_sync_time': lastSyncTime,
            'changes': changes.map((m) => m.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
          'E2EE Sync failed (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  // ConnectVoiceStream: 建立双向语音流长连接
  Future<io.WebSocket> connectVoiceStream(AIConfig config) async {
    final String wsUrl = serverBaseURL
            .replaceAll('http://', 'ws://')
            .replaceAll('https://', 'wss://') +
        '/api/chat/voice-stream';

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token') ?? '';

    final queryParams = <String, String>{};
    if (token.isNotEmpty) {
      queryParams['token'] = token;
    }

    // 将配置以 Query 参数传递
    final headers = config.toHeaders();
    headers.forEach((key, val) {
      final k = key.toLowerCase();
      if (k == 'x-chat-provider') queryParams['chat_provider'] = val;
      if (k == 'x-chat-model') queryParams['chat_model'] = val;
      if (k == 'x-chat-api-key') queryParams['chat_api_key'] = val;
      if (k == 'x-chat-base-url') queryParams['chat_base_url'] = val;

      if (k == 'x-vision-provider') queryParams['vision_provider'] = val;
      if (k == 'x-vision-model') queryParams['vision_model'] = val;
      if (k == 'x-vision-api-key') queryParams['vision_api_key'] = val;
      if (k == 'x-vision-base-url') queryParams['vision_base_url'] = val;

      if (k == 'x-embed-provider') queryParams['embed_provider'] = val;
      if (k == 'x-embed-model') queryParams['embed_model'] = val;
      if (k == 'x-embed-api-key') queryParams['embed_api_key'] = val;
      if (k == 'x-embed-base-url') queryParams['embed_base_url'] = val;

      if (k == 'x-stt-provider') queryParams['stt_provider'] = val;
      if (k == 'x-stt-model') queryParams['stt_model'] = val;
      if (k == 'x-stt-api-key') queryParams['stt_api_key'] = val;
      if (k == 'x-stt-base-url') queryParams['stt_base_url'] = val;

      if (k == 'x-tts-provider') queryParams['tts_provider'] = val;
      if (k == 'x-tts-model') queryParams['tts_model'] = val;
      if (k == 'x-tts-api-key') queryParams['tts_api_key'] = val;
      if (k == 'x-tts-base-url') queryParams['tts_base_url'] = val;
      if (k == 'x-tts-voice') queryParams['tts_voice'] = val;
      if (k == 'x-bark-key') queryParams['bark_key'] = val;
    });

    final uri = Uri.parse(wsUrl).replace(queryParameters: queryParams);
    final socket = await io.WebSocket.connect(uri.toString())
        .timeout(const Duration(seconds: 15));
    return socket;
  }

  // ConfirmTask: 保存用户修正并激活提醒
  Future<void> confirmTask(Map<String, dynamic> task) async {
    final response = await http
        .put(
          Uri.parse('$serverBaseURL/api/tasks/confirm'),
          headers: await _buildHeaders(),
          body: jsonEncode({
            'id': task['id'],
            'title': task['title'],
            'description': task['description'] ?? '',
            'action_type': task['action_type'] ?? 'reminder',
            'due_time': task['due_time'],
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 204) {
      String errorMessage = response.body;
      try {
        final body = jsonDecode(response.body);
        errorMessage = body['error'] ?? errorMessage;
      } catch (_) {}
      throw Exception(
          'Failed to confirm task (HTTP ${response.statusCode}): $errorMessage');
    }
  }

  // DeleteTask: 删除指定待办日程提醒
  Future<void> deleteTask(String id) async {
    final response = await http
        .post(
          Uri.parse('$serverBaseURL/api/tasks/delete?id=$id'),
          headers: await _buildHeaders(),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to delete task (HTTP ${response.statusCode}): ${response.body}');
    }
  }
}
