class Memory {
  final String id;
  final String rawContent;
  final String originalContent;
  final String extractedTime;
  final int priority;
  final String sourceType;
  final String sourceMeta;
  final String title;
  final String processingStatus;
  final String processingError;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final List<String> tags;

  Memory({
    required this.id,
    required this.rawContent,
    this.originalContent = '',
    required this.extractedTime,
    required this.priority,
    required this.sourceType,
    required this.sourceMeta,
    this.processingStatus = 'completed',
    this.processingError = '',
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.tags,
    this.title = '',
  });

  factory Memory.fromJson(Map<String, dynamic> json) {
    var tagsFromJson = json['tags'];
    List<String> tagsList =
        tagsFromJson != null ? List<String>.from(tagsFromJson) : [];

    return Memory(
      id: json['id'] ?? '',
      rawContent: json['raw_content'] ?? '',
      originalContent: json['original_content'] ?? json['raw_content'] ?? '',
      extractedTime: json['extracted_time'] ?? '',
      priority: json['priority'] ?? 1,
      sourceType: json['source_type'] ?? 'text',
      sourceMeta: json['source_meta'] ?? '',
      processingStatus: json['processing_status'] ?? 'completed',
      processingError: json['processing_error'] ?? '',
      createdAt: json['created_at'] ?? 0,
      updatedAt: json['updated_at'] ?? json['created_at'] ?? 0,
      deletedAt: json['deleted_at'],
      tags: tagsList,
      title: json['title'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'raw_content': rawContent,
      'original_content': originalContent,
      'extracted_time': extractedTime,
      'priority': priority,
      'source_type': sourceType,
      'source_meta': sourceMeta,
      'title': title,
      'processing_status': processingStatus,
      'processing_error': processingError,
      'created_at': createdAt,
      'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      'tags': tags,
    };
  }

  Memory copyWith({
    String? id,
    String? rawContent,
    String? originalContent,
    String? extractedTime,
    int? priority,
    String? sourceType,
    String? sourceMeta,
    String? title,
    String? processingStatus,
    String? processingError,
    int? createdAt,
    int? updatedAt,
    int? deletedAt,
    List<String>? tags,
  }) {
    return Memory(
      id: id ?? this.id,
      rawContent: rawContent ?? this.rawContent,
      originalContent: originalContent ?? this.originalContent,
      extractedTime: extractedTime ?? this.extractedTime,
      priority: priority ?? this.priority,
      sourceType: sourceType ?? this.sourceType,
      sourceMeta: sourceMeta ?? this.sourceMeta,
      title: title ?? this.title,
      processingStatus: processingStatus ?? this.processingStatus,
      processingError: processingError ?? this.processingError,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      tags: tags ?? this.tags,
    );
  }
}
