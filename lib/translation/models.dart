enum TranslationLanguage {
  auto('自动检测', 'auto'),
  zh('简体中文', '简体中文'),
  en('英文', 'English'),
  ja('日文', '日本語'),
  ko('韩文', '한국어'),
  fr('法文', 'Français'),
  de('德文', 'Deutsch'),
  es('西班牙文', 'Español'),
  ru('俄文', 'Русский'),
  pt('葡萄牙文', 'Português');

  const TranslationLanguage(this.label, this.prompt);
  final String label, prompt;
}

class TranslationChannel {
  const TranslationChannel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.isCustom = false,
    this.isEnabled = true,
    this.keyUrl = '',
    this.createdAt,
    this.secretId = '',
    this.region = 'ap-guangzhou',
    this.projectId = 0,
  });
  final String id, name, baseUrl, model, apiKey, keyUrl;
  final bool isCustom, isEnabled;
  final DateTime? createdAt;
  final String secretId, region;
  final int projectId;
  bool get isTencentTmt => id == 'tencent_tmt';
  bool get configured =>
      apiKey.trim().isNotEmpty &&
      (isTencentTmt
          ? secretId.trim().isNotEmpty && region.trim().isNotEmpty
          : model.trim().isNotEmpty);
  String get keyHint => apiKey.isEmpty
      ? '未配置 Key'
      : '已保存 · ••••${apiKey.length <= 4 ? '••••' : apiKey.substring(apiKey.length - 4)}';
  TranslationChannel copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? isEnabled,
    String? secretId,
    String? region,
    int? projectId,
  }) => TranslationChannel(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    isCustom: isCustom,
    isEnabled: isEnabled ?? this.isEnabled,
    keyUrl: keyUrl,
    createdAt: createdAt,
    secretId: secretId ?? this.secretId,
    region: region ?? this.region,
    projectId: projectId ?? this.projectId,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'isCustom': isCustom,
    'isEnabled': isEnabled,
    'keyUrl': keyUrl,
    'createdAt': createdAt?.toIso8601String(),
    'secretId': secretId,
    'region': region,
    'projectId': projectId,
  };
  factory TranslationChannel.fromJson(Map<String, dynamic> v) =>
      TranslationChannel(
        id: v['id'] as String,
        name: v['name'] as String,
        baseUrl: v['baseUrl'] as String,
        model: v['model'] as String,
        apiKey: v['apiKey'] as String? ?? '',
        isCustom: v['isCustom'] == true,
        isEnabled: v['isEnabled'] != false,
        keyUrl: v['keyUrl'] as String? ?? '',
        createdAt: DateTime.tryParse(v['createdAt'] as String? ?? ''),
        secretId: v['secretId'] as String? ?? '',
        region: v['region'] as String? ?? 'ap-guangzhou',
        projectId: (v['projectId'] as num?)?.toInt() ?? 0,
      );
}

List<TranslationChannel> defaultTranslationChannels() => [
  const TranslationChannel(
    id: 'zhipu',
    name: '智谱 AI',
    model: 'glm-4-flash',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    keyUrl: 'https://open.bigmodel.cn',
  ),
  const TranslationChannel(
    id: 'deepseek',
    name: 'DeepSeek',
    model: 'deepseek-chat',
    baseUrl: 'https://api.deepseek.com/v1/chat/completions',
    keyUrl: 'https://platform.deepseek.com',
  ),
  const TranslationChannel(
    id: 'qwen',
    name: '通义千问',
    model: 'qwen-turbo',
    baseUrl:
        'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    keyUrl: 'https://dashscope.console.aliyun.com',
  ),
  const TranslationChannel(
    id: 'kimi',
    name: 'Kimi',
    model: 'moonshot-v1-8k',
    baseUrl: 'https://api.moonshot.cn/v1/chat/completions',
    keyUrl: 'https://platform.moonshot.cn',
  ),
  const TranslationChannel(
    id: 'doubao',
    name: '豆包',
    model: 'doubao-lite-32k',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    keyUrl: 'https://console.volcengine.com',
  ),
  const TranslationChannel(
    id: 'openai',
    name: 'OpenAI',
    model: 'gpt-4o-mini',
    baseUrl: 'https://api.openai.com/v1/chat/completions',
    keyUrl: 'https://platform.openai.com',
  ),
  const TranslationChannel(
    id: 'tencent_tmt',
    name: '腾讯云 TMT',
    model: 'TextTranslate',
    baseUrl: 'https://tmt.tencentcloudapi.com',
    keyUrl: 'https://console.cloud.tencent.com/cam/capi',
  ),
];

class TranslationResult {
  const TranslationResult({
    required this.originalText,
    required this.translatedText,
    required this.channelName,
    required this.from,
    required this.to,
    required this.duration,
    this.tokensUsed = 0,
  });
  final String originalText, translatedText, channelName;
  final TranslationLanguage from, to;
  final Duration duration;
  final int tokensUsed;
}

class TranslationException implements Exception {
  const TranslationException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class TranslationCancelled implements Exception {
  const TranslationCancelled();
}

String? validateTranslationEndpoint(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return '请输入完整 API 地址，例如 https://example.com/v1/chat/completions';
  }
  if (uri.scheme != 'https' &&
      !(uri.scheme == 'http' &&
          ['localhost', '127.0.0.1', '::1'].contains(uri.host))) {
    return 'API 地址需要 HTTPS；本机 localhost 服务可使用 HTTP';
  }
  return null;
}
