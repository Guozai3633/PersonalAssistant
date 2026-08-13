import 'dart:typed_data';

import 'package:client/models/ai_config.dart';
import 'package:client/models/chat_result.dart';
import 'package:client/models/memory.dart';
import 'package:client/providers/assistant_provider.dart';
import 'package:client/services/api_service.dart';
import 'package:client/views/command_center_view.dart';
import 'package:client/views/dashboard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAPIService extends APIService {
  FakeAPIService() : super(serverBaseURL: 'http://localhost');

  String? ingestedContent;

  @override
  Future<Memory> ingest(String content, String sourceType, String sourceMeta,
      AIConfig config) async {
    ingestedContent = content;
    return Memory(
      id: 'mem_new',
      rawContent: content,
      originalContent: content,
      extractedTime: '',
      priority: 1,
      sourceType: sourceType,
      sourceMeta: sourceMeta,
      processingStatus: 'pending',
      createdAt: 2,
      updatedAt: 2,
      tags: const [],
    );
  }

  @override
  Future<List<Memory>> fetchMemories(int page, int pageSize) async {
    return [
      Memory(
        id: 'mem_confirmation',
        rawContent: '明天下午三点提交课程报告',
        extractedTime: '',
        priority: 1,
        sourceType: 'text',
        sourceMeta: '',
        processingStatus: 'needs_confirmation',
        createdAt: 1,
        updatedAt: 1,
        tags: const [],
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> fetchDashboardStats(AIConfig config) async {
    return {
      'today_count': 1,
      'pending_task_count': 1,
      'streak_days': 1,
      'total_memories': 1,
      'daily_counts': <dynamic>[],
      'upcoming_tasks': <dynamic>[],
      'confirmation_tasks': [
        {
          'id': 'task_report',
          'memory_id': 'mem_confirmation',
          'title': '提交课程报告',
          'description': '',
          'action_type': 'reminder',
          'due_time': 4102444800,
          'original_due_text': '明天下午三点',
          'status': 'pending_confirmation',
          'source_content': '明天下午三点提交课程报告',
        },
      ],
      'top_tags': <dynamic>[],
      'user_profile': '',
    };
  }

  @override
  Future<ChatResult> ask(
      String query, String sessionId, AIConfig config) async {
    return const ChatResult(
      answer: '报告明天下午提交。[1]',
      sources: [
        MemoryCitation(
          memoryId: 'mem_report',
          title: '提交报告',
          excerpt: '明天下午三点提交课程报告',
          sourceType: 'text',
          sourceMeta: '课程群',
          extractedTime: '2026-06-28T15:00:00+08:00',
          createdAt: 1,
        ),
      ],
    );
  }

  @override
  Future<Memory> fetchMemory(String id) async {
    return Memory(
      id: id,
      rawContent: '明天下午三点提交课程报告',
      originalContent: '课程群通知：明天下午三点提交课程报告',
      extractedTime: '2026-06-28T15:00:00+08:00',
      priority: 2,
      sourceType: 'text',
      sourceMeta: '课程群',
      title: '提交报告',
      createdAt: 1,
      updatedAt: 2,
      tags: const ['课程'],
    );
  }

  @override
  Future<Uint8List> generateTTS(String text, AIConfig config) async {
    return Uint8List(0);
  }
}

void main() {
  test('Memory reads processing status and error from API JSON', () {
    final memory = Memory.fromJson({
      'id': 'mem_1',
      'raw_content': '课程通知',
      'processing_status': 'failed',
      'processing_error': '结构化解析失败',
    });

    expect(memory.processingStatus, 'failed');
    expect(memory.processingError, '结构化解析失败');
    expect(memory.toJson()['processing_status'], 'failed');
  });

  test('Memory keeps completed as the legacy API default', () {
    final memory = Memory.fromJson({
      'id': 'mem_legacy',
      'raw_content': '旧记录',
    });

    expect(memory.processingStatus, 'completed');
    expect(memory.processingError, isEmpty);
    expect(memory.originalContent, '旧记录');
  });

  test('Memory supports the task confirmation state', () {
    final memory = Memory.fromJson({
      'id': 'mem_confirmation',
      'raw_content': '明天提醒我提交报告',
      'processing_status': 'needs_confirmation',
    });

    expect(memory.processingStatus, 'needs_confirmation');
  });

  test('ChatResult reads numbered memory citations', () {
    final result = ChatResult.fromJson({
      'answer': '报告明天下午提交。[1]',
      'sources': [
        {
          'memory_id': 'mem_report',
          'title': '提交报告',
          'excerpt': '明天下午三点提交课程报告',
          'source_type': 'text',
          'source_meta': '课程群',
          'extracted_time': '2026-06-28T15:00:00+08:00',
          'created_at': 1,
        },
      ],
    });

    expect(result.answer, contains('[1]'));
    expect(result.sources, hasLength(1));
    expect(result.sources.single.memoryId, 'mem_report');
  });

  testWidgets('Dashboard renders task confirmation with source evidence',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeAPIService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: DashboardView()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('待确认'), findsWidgets);
    expect(find.text('提交课程报告'), findsOneWidget);
    expect(find.textContaining('原文：明天下午三点'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
    expect(find.text('记忆收件箱'), findsOneWidget);
    expect(find.text('最近记忆'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('quick-capture-input')), '新的快速记录');
    await tester.tap(find.byKey(const ValueKey('quick-capture-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.ingestedContent, '新的快速记录');
    final captureField = tester
        .widget<TextField>(find.byKey(const ValueKey('quick-capture-input')));
    expect(captureField.controller?.text, isEmpty);

    await tester.tap(find.text('分析'));
    await tester.pump();
    expect(find.textContaining('7日活跃趋势'), findsOneWidget);
    expect(find.text('最近记忆'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Command center renders clickable memory citations',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(FakeAPIService()),
        ],
        child: const MaterialApp(home: CommandCenterView()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '报告什么时候交？');
    await tester.tap(find.text('语义检索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('参考记忆'), findsOneWidget);
    expect(find.text('提交报告'), findsOneWidget);
    expect(find.text('[1]'), findsOneWidget);

    await tester.tap(find.text('提交报告'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('原始内容'), findsOneWidget);
    expect(find.textContaining('课程群通知'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
