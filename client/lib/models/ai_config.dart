class AIConfig {
  final String chatProvider;
  final String chatModel;
  final String chatAPIKey;
  final String chatBaseURL;

  final String visionProvider;
  final String visionModel;
  final String visionAPIKey;
  final String visionBaseURL;

  final String embedProvider;
  final String embedModel;
  final String embedAPIKey;
  final String embedBaseURL;

  final String sttProvider;
  final String sttModel;
  final String sttAPIKey;
  final String sttBaseURL;

  final String ttsProvider;
  final String ttsModel;
  final String ttsAPIKey;
  final String ttsBaseURL;
  final String ttsVoice;
  final String barkKey;

  AIConfig({
    required this.chatProvider,
    required this.chatModel,
    required this.chatAPIKey,
    required this.chatBaseURL,
    required this.visionProvider,
    required this.visionModel,
    required this.visionAPIKey,
    required this.visionBaseURL,
    required this.embedProvider,
    required this.embedModel,
    required this.embedAPIKey,
    required this.embedBaseURL,
    required this.sttProvider,
    required this.sttModel,
    required this.sttAPIKey,
    required this.sttBaseURL,
    required this.ttsProvider,
    required this.ttsModel,
    required this.ttsAPIKey,
    required this.ttsBaseURL,
    required this.ttsVoice,
    required this.barkKey,
  });

  factory AIConfig.empty() {
    return AIConfig(
      chatProvider: 'openai',
      chatModel: 'gpt-4o-mini',
      chatAPIKey: '',
      chatBaseURL: '',
      visionProvider: 'openai',
      visionModel: '',
      visionAPIKey: '',
      visionBaseURL: '',
      embedProvider: 'openai',
      embedModel: 'text-embedding-3-small',
      embedAPIKey: '',
      embedBaseURL: '',
      sttProvider: 'openai',
      sttModel: 'whisper-1',
      sttAPIKey: '',
      sttBaseURL: '',
      ttsProvider: 'openai',
      ttsModel: 'tts-1',
      ttsAPIKey: '',
      ttsBaseURL: '',
      ttsVoice: 'alloy',
      barkKey: '',
    );
  }

  AIConfig copyWith({
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
  }) {
    return AIConfig(
      chatProvider: chatProvider ?? this.chatProvider,
      chatModel: chatModel ?? this.chatModel,
      chatAPIKey: chatAPIKey ?? this.chatAPIKey,
      chatBaseURL: chatBaseURL ?? this.chatBaseURL,
      visionProvider: visionProvider ?? this.visionProvider,
      visionModel: visionModel ?? this.visionModel,
      visionAPIKey: visionAPIKey ?? this.visionAPIKey,
      visionBaseURL: visionBaseURL ?? this.visionBaseURL,
      embedProvider: embedProvider ?? this.embedProvider,
      embedModel: embedModel ?? this.embedModel,
      embedAPIKey: embedAPIKey ?? this.embedAPIKey,
      embedBaseURL: embedBaseURL ?? this.embedBaseURL,
      sttProvider: sttProvider ?? this.sttProvider,
      sttModel: sttModel ?? this.sttModel,
      sttAPIKey: sttAPIKey ?? this.sttAPIKey,
      sttBaseURL: sttBaseURL ?? this.sttBaseURL,
      ttsProvider: ttsProvider ?? this.ttsProvider,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsAPIKey: ttsAPIKey ?? this.ttsAPIKey,
      ttsBaseURL: ttsBaseURL ?? this.ttsBaseURL,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      barkKey: barkKey ?? this.barkKey,
    );
  }

  Map<String, String> toHeaders() {
    return {
      'X-Chat-Provider': chatProvider,
      'X-Chat-Model': chatModel,
      'X-Chat-API-Key': chatAPIKey,
      'X-Chat-Base-URL': chatBaseURL,
      'X-Vision-Provider': visionProvider,
      'X-Vision-Model': visionModel,
      'X-Vision-API-Key': visionAPIKey,
      'X-Vision-Base-URL': visionBaseURL,
      'X-Embed-Provider': embedProvider,
      'X-Embed-Model': embedModel,
      'X-Embed-API-Key': embedAPIKey,
      'X-Embed-Base-URL': embedBaseURL,
      'X-STT-Provider': sttProvider,
      'X-STT-Model': sttModel,
      'X-STT-API-Key': sttAPIKey,
      'X-STT-Base-URL': sttBaseURL,
      'X-TTS-Provider': ttsProvider,
      'X-TTS-Model': ttsModel,
      'X-TTS-API-Key': ttsAPIKey,
      'X-TTS-Base-URL': ttsBaseURL,
      'X-TTS-Voice': ttsVoice,
      'X-Bark-Key': barkKey,
    };
  }
}
