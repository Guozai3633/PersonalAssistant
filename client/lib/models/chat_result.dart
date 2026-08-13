class MemoryCitation {
  final String memoryId;
  final String title;
  final String excerpt;
  final String sourceType;
  final String sourceMeta;
  final String extractedTime;
  final int createdAt;

  const MemoryCitation({
    required this.memoryId,
    required this.title,
    required this.excerpt,
    required this.sourceType,
    required this.sourceMeta,
    required this.extractedTime,
    required this.createdAt,
  });

  factory MemoryCitation.fromJson(Map<String, dynamic> json) {
    return MemoryCitation(
      memoryId: json['memory_id'] ?? '',
      title: json['title'] ?? '未命名记忆',
      excerpt: json['excerpt'] ?? '',
      sourceType: json['source_type'] ?? 'text',
      sourceMeta: json['source_meta'] ?? '',
      extractedTime: json['extracted_time'] ?? '',
      createdAt: json['created_at'] ?? 0,
    );
  }
}

class ChatResult {
  final String answer;
  final List<MemoryCitation> sources;

  const ChatResult({required this.answer, required this.sources});

  factory ChatResult.fromJson(Map<String, dynamic> json) {
    final rawSources = json['sources'] as List<dynamic>? ?? const [];
    return ChatResult(
      answer: json['answer'] ?? '',
      sources: rawSources
          .map((source) =>
              MemoryCitation.fromJson(Map<String, dynamic>.from(source as Map)))
          .toList(),
    );
  }
}
