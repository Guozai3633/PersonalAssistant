import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_config.dart';
import '../models/chat_result.dart';
import '../models/memory.dart';
import '../services/api_service.dart';
import '../utils/crypto_helper.dart';

// 后端服务器地址状态管理（支持运行时切换后热更新）
class ServerUrlNotifier extends StateNotifier<String> {
  ServerUrlNotifier() : super(APIService.defaultBaseURL) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_base_url');
    if (url != null && url.isNotEmpty) {
      state = url;
    }
  }

  Future<void> updateUrl(String newUrl) async {
    state = newUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_base_url', newUrl);
  }
}

final serverUrlProvider = StateNotifierProvider<ServerUrlNotifier, String>(
  (ref) => ServerUrlNotifier(),
);

// API 服务实例提供者（自动跟踪 serverUrl 变更重建实例）
final apiServiceProvider = Provider<APIService>((ref) {
  final baseUrl = ref.watch(serverUrlProvider);
  return APIService(serverBaseURL: baseUrl);
});

// 1. AI 凭证配置状态管理
class ConfigNotifier extends StateNotifier<AIConfig> {
  ConfigNotifier() : super(AIConfig.empty()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    // 向前平滑兼容历史配置数据，防范用户升级后数据被抹去
    final oldProvider = prefs.getString('provider') ?? 'openai';
    final oldChatModel = prefs.getString('chatModel') ?? 'gpt-4o-mini';
    final oldEmbedModel =
        prefs.getString('embedModel') ?? 'text-embedding-3-small';
    final oldVisionModel = prefs.getString('visionModel') ?? '';
    final oldApiKey = prefs.getString('apiKey') ?? '';
    final oldBaseUrl = prefs.getString('baseURL') ?? '';

    state = AIConfig(
      chatProvider: prefs.getString('chatProvider') ?? oldProvider,
      chatModel: prefs.getString('chatModel') ?? oldChatModel,
      chatAPIKey: prefs.getString('chatAPIKey') ?? oldApiKey,
      chatBaseURL: prefs.getString('chatBaseURL') ?? oldBaseUrl,
      visionProvider: prefs.getString('visionProvider') ?? oldProvider,
      visionModel: prefs.getString('visionModel') ?? oldVisionModel,
      visionAPIKey: prefs.getString('visionAPIKey') ?? oldApiKey,
      visionBaseURL: prefs.getString('visionBaseURL') ?? oldBaseUrl,
      embedProvider: prefs.getString('embedProvider') ?? oldProvider,
      embedModel: prefs.getString('embedModel') ?? oldEmbedModel,
      embedAPIKey: prefs.getString('embedAPIKey') ?? oldApiKey,
      embedBaseURL: prefs.getString('embedBaseURL') ?? oldBaseUrl,
      sttProvider: prefs.getString('sttProvider') ?? oldProvider,
      sttModel: prefs.getString('sttModel') ?? 'whisper-1',
      sttAPIKey: prefs.getString('sttAPIKey') ?? oldApiKey,
      sttBaseURL: prefs.getString('sttBaseURL') ?? oldBaseUrl,
      ttsProvider: prefs.getString('ttsProvider') ?? oldProvider,
      ttsModel: prefs.getString('ttsModel') ?? 'tts-1',
      ttsAPIKey: prefs.getString('ttsAPIKey') ?? oldApiKey,
      ttsBaseURL: prefs.getString('ttsBaseURL') ?? oldBaseUrl,
      ttsVoice: prefs.getString('ttsVoice') ?? 'alloy',
      barkKey: prefs.getString('barkKey') ?? '',
    );
  }

  Future<void> updateConfig({
    String? chatProvider,
    String? chatModel,
    String? chatAPIKey,
    String? chatBaseURL,
    String? visionProvider,
    String? visionModel,
    String? visionAPIKey,
    String? visionBaseURL,
    String? embedProvider,
    String? embedModel,
    String? embedAPIKey,
    String? embedBaseURL,
    String? sttProvider,
    String? sttModel,
    String? sttAPIKey,
    String? sttBaseURL,
    String? ttsProvider,
    String? ttsModel,
    String? ttsAPIKey,
    String? ttsBaseURL,
    String? ttsVoice,
    String? barkKey,
  }) async {
    state = state.copyWith(
      chatProvider: chatProvider,
      chatModel: chatModel,
      chatAPIKey: chatAPIKey,
      chatBaseURL: chatBaseURL,
      visionProvider: visionProvider,
      visionModel: visionModel,
      visionAPIKey: visionAPIKey,
      visionBaseURL: visionBaseURL,
      embedProvider: embedProvider,
      embedModel: embedModel,
      embedAPIKey: embedAPIKey,
      embedBaseURL: embedBaseURL,
      sttProvider: sttProvider,
      sttModel: sttModel,
      sttAPIKey: sttAPIKey,
      sttBaseURL: sttBaseURL,
      ttsProvider: ttsProvider,
      ttsModel: ttsModel,
      ttsAPIKey: ttsAPIKey,
      ttsBaseURL: ttsBaseURL,
      ttsVoice: ttsVoice,
      barkKey: barkKey,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chatProvider', state.chatProvider);
    await prefs.setString('chatModel', state.chatModel);
    await prefs.setString('chatAPIKey', state.chatAPIKey);
    await prefs.setString('chatBaseURL', state.chatBaseURL);
    await prefs.setString('visionProvider', state.visionProvider);
    await prefs.setString('visionModel', state.visionModel);
    await prefs.setString('visionAPIKey', state.visionAPIKey);
    await prefs.setString('visionBaseURL', state.visionBaseURL);
    await prefs.setString('embedProvider', state.embedProvider);
    await prefs.setString('embedModel', state.embedModel);
    await prefs.setString('embedAPIKey', state.embedAPIKey);
    await prefs.setString('embedBaseURL', state.embedBaseURL);
    await prefs.setString('sttProvider', state.sttProvider);
    await prefs.setString('sttModel', state.sttModel);
    await prefs.setString('sttAPIKey', state.sttAPIKey);
    await prefs.setString('sttBaseURL', state.sttBaseURL);
    await prefs.setString('ttsProvider', state.ttsProvider);
    await prefs.setString('ttsModel', state.ttsModel);
    await prefs.setString('ttsAPIKey', state.ttsAPIKey);
    await prefs.setString('ttsBaseURL', state.ttsBaseURL);
    await prefs.setString('ttsVoice', state.ttsVoice);
    await prefs.setString('barkKey', state.barkKey);
  }
}

final configProvider =
    StateNotifierProvider<ConfigNotifier, AIConfig>((ref) => ConfigNotifier());

// 2. 核心业务与指标状态管理
class AssistantState {
  final List<Memory> memories;
  final Map<String, dynamic> stats;
  final bool isLoading;
  final String? error;
  final List<Map<String, dynamic>> offlineQueue;
  final bool isOfflineMode;
  final List<Map<String, dynamic>> activeAlarms;

  AssistantState({
    required this.memories,
    required this.stats,
    this.isLoading = false,
    this.error,
    required this.offlineQueue,
    this.isOfflineMode = false,
    required this.activeAlarms,
  });

  factory AssistantState.initial() {
    return AssistantState(
        memories: [],
        stats: {},
        isLoading: false,
        offlineQueue: [],
        activeAlarms: []);
  }

  AssistantState copyWith({
    List<Memory>? memories,
    Map<String, dynamic>? stats,
    bool? isLoading,
    String? error,
    List<Map<String, dynamic>>? offlineQueue,
    bool? isOfflineMode,
    List<Map<String, dynamic>>? activeAlarms,
  }) {
    return AssistantState(
      memories: memories ?? this.memories,
      stats: stats ?? this.stats,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      offlineQueue: offlineQueue ?? this.offlineQueue,
      isOfflineMode: isOfflineMode ?? this.isOfflineMode,
      activeAlarms: activeAlarms ?? this.activeAlarms,
    );
  }
}

class AssistantNotifier extends StateNotifier<AssistantState> {
  final APIService _apiService;
  final AIConfig _aiConfig;
  Timer? _syncTimer;
  Timer? _localReminderTimer;
  Timer? _processingRefreshTimer;
  bool _isRefreshingProcessing = false;
  final Set<String> _alertedTaskIds = {};

  AssistantNotifier(this._apiService, this._aiConfig)
      : super(AssistantState.initial()) {
    _loadOfflineQueue();
    refreshAll();
    _startOfflineSyncTimer();
    _startLocalReminderTimer();
    _startProcessingRefreshTimer();
  }

  void _startProcessingRefreshTimer() {
    _processingRefreshTimer?.cancel();
    _processingRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final hasActiveProcessing = state.memories.any((memory) =>
          memory.processingStatus == 'pending' ||
          memory.processingStatus == 'processing');
      if (hasActiveProcessing) {
        _refreshProcessingMemories();
      }
    });
  }

  Future<void> _refreshProcessingMemories() async {
    if (_isRefreshingProcessing) return;
    _isRefreshingProcessing = true;
    try {
      final memories = await _apiService.fetchMemories(1, 40);
      final stillProcessing = memories.any((memory) =>
          memory.processingStatus == 'pending' ||
          memory.processingStatus == 'processing');
      var stats = state.stats;
      if (!stillProcessing ||
          memories.any(
              (memory) => memory.processingStatus == 'needs_confirmation')) {
        stats = await _apiService.fetchDashboardStats(_aiConfig);
      }
      if (mounted) {
        state = state.copyWith(
          memories: memories,
          stats: stats,
          isOfflineMode: false,
        );
      }
    } catch (e) {
      print('[WARN] Failed to refresh processing memories: $e');
    } finally {
      _isRefreshingProcessing = false;
    }
  }

  void _startLocalReminderTimer() {
    _localReminderTimer?.cancel();
    _localReminderTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _checkLocalReminders();
    });
  }

  void _checkLocalReminders() {
    final upcoming = state.stats['upcoming_tasks'];
    if (upcoming == null || upcoming is! List) return;

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final List<Map<String, dynamic>> newlyTriggered = [];

    for (final task in upcoming) {
      if (task is! Map<String, dynamic>) continue;
      final id = task['id'] as String?;
      final dueTime = task['due_time'] as int?;
      if (id == null || dueTime == null) continue;

      if (nowSec >= dueTime && !_alertedTaskIds.contains(id)) {
        _alertedTaskIds.add(id);
        newlyTriggered.add(task);
      }
    }

    if (newlyTriggered.isNotEmpty) {
      final currentAlarms = List<Map<String, dynamic>>.from(state.activeAlarms);
      currentAlarms.addAll(newlyTriggered);
      state = state.copyWith(activeAlarms: currentAlarms);
    }

    // 前台强鸣笛模式：如果有尚未关闭的活动闹钟，每隔 3 秒循环进行重度震动与系统警告音
    if (state.activeAlarms.isNotEmpty) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
      Future.delayed(const Duration(milliseconds: 400), () {
        HapticFeedback.heavyImpact();
      });
      Future.delayed(const Duration(milliseconds: 800), () {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      });
    }
  }

  void dismissAlarm(String taskId) {
    final currentAlarms = List<Map<String, dynamic>>.from(state.activeAlarms);
    currentAlarms.removeWhere((alarm) => alarm['id'] == taskId);
    state = state.copyWith(activeAlarms: currentAlarms);
  }

  Future<void> completeTask(String taskId) async {
    dismissAlarm(taskId);
    await removeTask(taskId);
  }

  void _startOfflineSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (state.offlineQueue.isNotEmpty) {
        flushOfflineQueue();
      }
      _syncE2EEClock();
    });
  }

  Future<void> _syncE2EEClock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final e2eeKey = prefs.getString('e2ee_key') ?? '';
      if (e2eeKey.isEmpty) return;

      final lastSyncTime = prefs.getInt('e2ee_last_sync_time') ?? 0;
      final syncResult = await _apiService.syncE2EE(lastSyncTime, []);
      final int serverSyncTime = syncResult['sync_time'] ?? 0;
      final List<dynamic>? serverChanges = syncResult['changes'];

      if (serverChanges != null && serverChanges.isNotEmpty) {
        final List<Memory> list =
            serverChanges.map((dynamic item) => Memory.fromJson(item)).toList();
        final List<Memory> decryptedList = [];
        for (final mem in list) {
          decryptedList.add(mem.copyWith(
            rawContent: CryptoHelper.decryptText(mem.rawContent, e2eeKey),
            originalContent:
                CryptoHelper.decryptText(mem.originalContent, e2eeKey),
            title: CryptoHelper.decryptText(mem.title, e2eeKey),
            tags: mem.tags
                .map((t) => CryptoHelper.decryptText(t, e2eeKey))
                .toList(),
          ));
        }

        final Map<String, Memory> currentMemMap = {
          for (final m in state.memories) m.id: m
        };

        for (final newMem in decryptedList) {
          if (newMem.deletedAt != null) {
            currentMemMap.remove(newMem.id);
          } else {
            final existing = currentMemMap[newMem.id];
            if (existing == null || newMem.updatedAt > existing.updatedAt) {
              currentMemMap[newMem.id] = newMem;
            }
          }
        }

        final mergedMemories = currentMemMap.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        final stats = await _apiService.fetchDashboardStats(_aiConfig);

        if (mounted) {
          state = state.copyWith(memories: mergedMemories, stats: stats);
        }
      }

      if (serverSyncTime > 0) {
        await prefs.setInt('e2ee_last_sync_time', serverSyncTime);
      }
    } catch (e) {
      print('[WARN] E2EE Sync clock failed: $e');
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _localReminderTimer?.cancel();
    _processingRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOfflineQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('offline_memories_queue');
      if (queueJson != null) {
        final List<dynamic> decoded = jsonDecode(queueJson);
        final queue = decoded.cast<Map<String, dynamic>>();
        if (mounted) {
          state = state.copyWith(offlineQueue: queue);
        }
      }
    } catch (e) {
      print('[ERROR] Failed to load offline queue: $e');
    }
  }

  Future<void> _saveOfflineQueue(List<Map<String, dynamic>> queue) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('offline_memories_queue', jsonEncode(queue));
    } catch (e) {
      print('[ERROR] Failed to save offline queue: $e');
    }
  }

  // 同步离线队列
  Future<void> flushOfflineQueue() async {
    if (state.offlineQueue.isEmpty) return;

    // 检查后端健康状况
    final isHealthy = await _apiService.checkServerHealth();
    if (!isHealthy) return; // 后端仍离线

    final currentQueue = List<Map<String, dynamic>>.from(state.offlineQueue);
    final failedItems = <Map<String, dynamic>>[];

    for (final item in currentQueue) {
      try {
        if (item['type'] == 'text') {
          await _apiService.ingest(
            item['content'] as String,
            item['sourceType'] as String,
            item['sourceMeta'] as String,
            _aiConfig,
          );
        } else if (item['type'] == 'audio') {
          await _apiService.ingestAudio(
            item['filePath'] as String,
            _aiConfig,
          );
        }
      } catch (e) {
        failedItems.add(item);
        print('[WARN] Failed to sync offline item: $e');
      }
    }

    if (mounted) {
      state = state.copyWith(
        offlineQueue: failedItems,
        isOfflineMode: failedItems.isNotEmpty,
      );
    }
    await _saveOfflineQueue(failedItems);
    await refreshAll();
  }

  // 刷新列表和仪表盘指标
  Future<void> refreshAll() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final memories = await _apiService.fetchMemories(1, 40); // 增加一次加载数量以支持时光轴
      final stats = await _apiService.fetchDashboardStats(_aiConfig);
      if (!mounted) return;
      state = state.copyWith(
        memories: memories,
        stats: stats,
        isOfflineMode: false,
        isLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        isOfflineMode: true,
        error: e.toString(),
      );
    }
  }

  // 录入新记忆
  Future<void> addMemory(
      String content, String sourceType, String sourceMeta) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiService.ingest(content, sourceType, sourceMeta, _aiConfig);
      if (mounted) {
        state = state.copyWith(isOfflineMode: false);
      }
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('SocketException') ||
          errStr.contains('TimeoutException') ||
          errStr.contains('Failed host lookup')) {
        final item = {
          'id': 'off_${DateTime.now().millisecondsSinceEpoch}',
          'type': 'text',
          'content': content,
          'sourceType': sourceType,
          'sourceMeta': sourceMeta,
          'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
        final newQueue = List<Map<String, dynamic>>.from(state.offlineQueue)
          ..add(item);
        if (mounted) {
          state = state.copyWith(
            offlineQueue: newQueue,
            isOfflineMode: true,
            isLoading: false,
            error: '检测到网络离线，已存入待同步队列。',
          );
        }
        await _saveOfflineQueue(newQueue);
      } else {
        if (!mounted) return;
        state = state.copyWith(isLoading: false, error: e.toString());
        rethrow;
      }
    }
  }

  // 录入语音记忆
  Future<void> addAudioMemory(String filePath) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final prefs = await SharedPreferences.getInstance();
      final e2eeKey = prefs.getString('e2ee_key') ?? '';

      if (e2eeKey.isNotEmpty) {
        // E2EE 激活时，先通过端点纯转译为明文，然后本地加密 Ingest，防止云端存储明文
        final text = await _apiService.transcribeAudio(filePath, _aiConfig);
        await _apiService.ingest(
            text, 'audio', filePath.split('/').last, _aiConfig);
      } else {
        await _apiService.ingestAudio(filePath, _aiConfig);
      }

      if (mounted) {
        state = state.copyWith(isOfflineMode: false);
      }
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('SocketException') ||
          errStr.contains('TimeoutException') ||
          errStr.contains('Failed host lookup')) {
        final item = {
          'id': 'off_${DateTime.now().millisecondsSinceEpoch}',
          'type': 'audio',
          'filePath': filePath,
          'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
        final newQueue = List<Map<String, dynamic>>.from(state.offlineQueue)
          ..add(item);
        if (mounted) {
          state = state.copyWith(
            offlineQueue: newQueue,
            isOfflineMode: true,
            isLoading: false,
            error: '检测到网络离线，语音文件已保存本地。',
          );
        }
        await _saveOfflineQueue(newQueue);
      } else {
        if (!mounted) return;
        state = state.copyWith(isLoading: false, error: e.toString());
        rethrow;
      }
    }
  }

  // 删除记忆
  Future<void> removeMemory(String id) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiService.deleteMemory(id, _aiConfig);
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  // 更新记忆
  Future<void> updateMemory(Memory memory) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiService.updateMemory(memory, _aiConfig);
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> retryMemoryProcessing(String id) async {
    try {
      final pendingMemory =
          await _apiService.retryMemoryProcessing(id, _aiConfig);
      if (!mounted) return;
      final memories = state.memories
          .map((memory) => memory.id == id ? pendingMemory : memory)
          .toList();
      state = state.copyWith(memories: memories, error: null);
    } catch (e) {
      if (mounted) {
        state = state.copyWith(error: e.toString());
      }
      rethrow;
    }
  }

  // 混合问答
  Future<ChatResult> askQuestion(String query, String sessionId) async {
    try {
      final result = await _apiService.ask(query, sessionId, _aiConfig);
      if (!mounted) return result;
      if (mounted) {
        state = state.copyWith(isOfflineMode: false);
        refreshAll();
      }
      return result;
    } catch (e) {
      if (mounted) {
        state = state.copyWith(error: e.toString());
      }
      rethrow;
    }
  }

  // 融合多选卡片生成长文
  Future<String> summarizeSelectedMemories(List<String> ids) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final summary = await _apiService.summarizeMemories(ids, _aiConfig);
      if (mounted) {
        state = state.copyWith(isLoading: false, isOfflineMode: false);
      }
      return summary;
    } catch (e) {
      if (mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
  }

  // 确认 AI 提取任务并刷新数据
  Future<void> confirmTask(Map<String, dynamic> task) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiService.confirmTask(task);
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      if (mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
  }

  // 删除任务并自动更新刷新数据
  Future<void> removeTask(String id) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiService.deleteTask(id);
      if (!mounted) return;
      await refreshAll();
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }
}

final assistantProvider =
    StateNotifierProvider<AssistantNotifier, AssistantState>((ref) {
  final api = ref.watch(apiServiceProvider);
  final config = ref.watch(configProvider);
  return AssistantNotifier(api, config);
});
