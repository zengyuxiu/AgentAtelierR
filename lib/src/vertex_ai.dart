import 'dart:async';
import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;


class VertexAiException implements Exception {
  const VertexAiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The JSON is deliberately never included in exceptions or diagnostics.
class VertexServiceAccount {
  VertexServiceAccount._(this.projectId, this.email, this.credentials);
  final String projectId;
  final String email;
  final auth.ServiceAccountCredentials credentials;

  factory VertexServiceAccount.parse(String source) {
    try {
      final data = jsonDecode(source) as Map<String, dynamic>;
      if (data['type'] != 'service_account' ||
          data['project_id'] is! String ||
          (data['project_id'] as String).isEmpty ||
          data['client_email'] is! String ||
          !(data['client_email'] as String).endsWith('.gserviceaccount.com') ||
          data['token_uri'] != 'https://oauth2.googleapis.com/token') {
        throw const FormatException();
      }
      return VertexServiceAccount._(
        data['project_id'] as String,
        data['client_email'] as String,
        auth.ServiceAccountCredentials.fromJson(data),
      );
    } catch (_) {
      throw const VertexAiException('请选择有效的 Google 服务账号 JSON 密钥文件。');
    }
  }
}

class VertexAiConfig {
  const VertexAiConfig({required this.projectId, this.location = 'global'});
  final String projectId;
  final String location;

  String get baseUrl {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{3,62}$').hasMatch(projectId) ||
        !RegExp(r'^(global|[a-z]+-[a-z]+[0-9]+)$').hasMatch(location)) {
      throw const VertexAiException('请填写有效的 Project ID 和 Location。');
    }
    final host = location == 'global'
        ? 'aiplatform.googleapis.com'
        : '$location-aiplatform.googleapis.com';
    return 'https://$host/v1/projects/$projectId/locations/$location/publishers/google';
  }

  static Uri endpoint(String baseUrl, String model, {bool stream = false}) {
    final uri = Uri.tryParse(baseUrl);
    final match = uri == null
        ? null
        : RegExp(
            r'^/v1/projects/([a-z0-9][a-z0-9-]{3,62})/locations/([a-z0-9-]+)/publishers/google$',
          ).firstMatch(uri.path);
    if (uri == null ||
        match == null ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        VertexAiConfig(
              projectId: match.group(1)!,
              location: match.group(2)!,
            ).baseUrl !=
            baseUrl ||
        !RegExp(r'^gemini-[a-zA-Z0-9._-]+$').hasMatch(model)) {
      throw const VertexAiException('Vertex AI 地址或 Gemini 模型 ID 无效。');
    }
    return Uri.parse(
      '$baseUrl/models/$model:${stream ? 'streamGenerateContent?alt=sse' : 'generateContent'}',
    );
  }
}

typedef VertexTokenLoader = Future<auth.AccessToken> Function(String json);
typedef VertexToolExecutor = Future<String> Function(Map<String, dynamic> call);

/// Native Vertex generateContent transport, shared by chat and background jobs.
class VertexAiClient {
  VertexAiClient({
    http.Client? client,
    VertexTokenLoader? tokenLoader,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _loader = tokenLoader,
       _now = now ?? DateTime.now;
  final http.Client _client;
  final bool _ownsClient;
  final VertexTokenLoader? _loader;
  final DateTime Function() _now;
  String? _accountJson;
  Future<auth.AccessToken>? _pending;
  auth.AccessToken? _token;

  void close() {
    _accountJson = null;
    _token = null;
    if (_ownsClient) _client.close();
  }

  Future<auth.AccessToken> _load(String json) async {
    try {
      if (_loader != null) return await _loader(json);
      final account = VertexServiceAccount.parse(json);
      final credentials = await auth
          .obtainAccessCredentialsViaServiceAccount(account.credentials, const [
            'https://www.googleapis.com/auth/cloud-platform',
          ], _client)
          .timeout(const Duration(seconds: 45));
      return credentials.accessToken;
    } on VertexAiException {
      rethrow;
    } catch (_) {
      throw const VertexAiException(
        '服务账号认证失败，请检查密钥是否有效、系统时间及 Google OAuth 网络连接。',
      );
    }
  }

  Future<String> accessToken(String json) async {
    // Switch synchronously; an older in-flight refresh must not overwrite this account.
    if (_accountJson != json) {
      _accountJson = json;
      _token = null;
      _pending = null;
    }
    final cached = _token;
    if (cached != null &&
        cached.expiry.isAfter(_now().toUtc().add(const Duration(minutes: 1)))) {
      return cached.data;
    }
    final pending = _pending ??= _load(json);
    try {
      final token = await pending;
      if (_accountJson == json) _token = token;
      return token.data;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<http.StreamedResponse> _send(
    Uri url,
    String json,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await accessToken(json);
      final request = http.Request('POST', url)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Accept': url.hasQuery ? 'text/event-stream' : 'application/json',
        })
        ..body = jsonEncode(body);
      http.StreamedResponse response;
      try {
        response = await _client
            .send(request)
            .timeout(const Duration(seconds: 60));
      } catch (_) {
        throw const VertexAiException('Vertex AI 网络连接失败或超时。');
      }
      if (response.statusCode == 401 && attempt == 0) {
        await response.stream
            .timeout(const Duration(seconds: 90))
            .drain<void>();
        if (_accountJson == json && _token?.data == token) _token = null;
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream
            .timeout(const Duration(seconds: 90))
            .drain<void>();
        final hint = switch (response.statusCode) {
          400 => '请检查模型、请求参数和附件格式',
          401 => '服务账号认证已被拒绝，请重新导入有效密钥',
          403 => '请检查 Vertex AI API、结算及服务账号的 Vertex AI User 权限',
          404 => '请检查项目、区域及模型是否可用',
          429 => '配额或服务容量不足，请稍后重试',
          _ => '服务暂不可用，请检查网络后重试',
        };
        throw VertexAiException('Vertex AI HTTP ${response.statusCode}：$hint。');
      }
      return response;
    }
    throw const VertexAiException('Vertex AI 认证失败。');
  }

  static List<Map<String, dynamic>> _parts(Object? content) {
    if (content is String) {
      return [
        {'text': content},
      ];
    }
    if (content is! List) throw const VertexAiException('不支持的消息格式。');
    return content.map<Map<String, dynamic>>((part) {
      if (part['type'] == 'text') return {'text': part['text']};
      final data = part['type'] == 'image_url'
          ? part['image_url']['url']
          : part['file']?['file_data'];
      final match = data is String
          ? RegExp(r'^data:([^;]+);base64,(.*)$', dotAll: true).firstMatch(data)
          : null;
      if (match == null) throw const VertexAiException('Vertex AI 仅支持内嵌附件数据。');
      return {
        'inlineData': {'mimeType': match.group(1), 'data': match.group(2)},
      };
    }).toList();
  }

  static Map<String, dynamic>? _candidate(Map<String, dynamic> event) {
    if (event.containsKey('error') ||
        (event['promptFeedback'] as Map?)?['blockReason'] != null) {
      throw const VertexAiException('Vertex AI 拒绝了请求或内容被安全策略拦截。');
    }
    final candidates = event['candidates'] as List? ?? const [];
    if (candidates.isEmpty) return null;
    final candidate = Map<String, dynamic>.from(candidates.first as Map);
    final finish = candidate['finishReason'];
    if (finish != null && finish != 'STOP' && finish != 'MAX_TOKENS') {
      throw const VertexAiException('Vertex AI 未正常完成响应，可能触发安全限制。');
    }
    return candidate;
  }

  static Iterable<String> _texts(Map? content) sync* {
    for (final part in content?['parts'] as List? ?? const []) {
      if (part['thought'] != true && part['text'] is String) {
        yield part['text'] as String;
      }
    }
  }

  static Stream<Map<String, dynamic>> _events(Stream<List<int>> bytes) async* {
    final data = <String>[];
    await for (final line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty && data.isNotEmpty) {
        yield jsonDecode(data.join('\n')) as Map<String, dynamic>;
        data.clear();
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    if (data.isNotEmpty) {
      yield jsonDecode(data.join('\n')) as Map<String, dynamic>;
    }
  }

  Stream<String> chat({
    required String baseUrl,
    required String credentialJson,
    required String model,
    required List<Map<String, dynamic>> messages,
    bool stream = true,
    List<Map<String, dynamic>> tools = const [],
    VertexToolExecutor? executeTool,
    Map<String, dynamic> generationConfig = const {},
  }) async* {
    // Validate destination before obtaining or transmitting credentials.
    final url = VertexAiConfig.endpoint(
      baseUrl,
      model,
      stream: stream && tools.isEmpty,
    );
    final system = <Map<String, dynamic>>[];
    final contents = <Map<String, dynamic>>[];
    for (final message in messages) {
      final parts = _parts(message['content']);
      if (message['role'] == 'system') {
        system.addAll(parts);
      } else {
        contents.add({
          'role': message['role'] == 'assistant' ? 'model' : 'user',
          'parts': parts,
        });
      }
    }
    final declarations = tools.map((tool) {
      final function = tool['function'] as Map;
      return {
        'name': function['name'],
        'description': function['description'],
        'parametersJsonSchema': function['parameters'],
      };
    }).toList();
    var calls = 0;
    try {
      for (var round = 0; round <= 10; round++) {
        final body = <String, dynamic>{
          if (system.isNotEmpty) 'systemInstruction': {'parts': system},
          'contents': contents,
          if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
          if (declarations.isNotEmpty)
            'tools': [
              {'functionDeclarations': declarations},
            ],
          if (declarations.isNotEmpty && calls >= 10)
            'toolConfig': {
              'functionCallingConfig': {'mode': 'NONE'},
            },
        };
        final response = await _send(url, credentialJson, body);
        final bytes = response.stream.timeout(const Duration(seconds: 90));
        if (stream && tools.isEmpty) {
          var finished = false;
          var hasText = false;
          await for (final event in _events(bytes)) {
            final candidate = _candidate(event);
            finished |= candidate?['finishReason'] != null;
            for (final text in _texts(candidate?['content'] as Map?)) {
              hasText |= text.isNotEmpty;
              yield text;
            }
          }
          if (!finished || !hasText) {
            throw const VertexAiException('Vertex AI 响应中断或未返回正文，请重试。');
          }
          return;
        }
        final event = jsonDecode(
          await utf8.decoder.bind(bytes).join(),
        ) as Map<String, dynamic>;
        final candidate = _candidate(event);
        final content = candidate?['content'] as Map?;
        final parts = content?['parts'] as List? ?? const [];
        final functions = parts
            .where((part) => part['functionCall'] != null)
            .toList();
        if (functions.isEmpty) {
          final text = _texts(content).join();
          if (text.isEmpty || candidate?['finishReason'] == null) {
            throw const VertexAiException('Vertex AI 未返回完整正文。');
          }
          yield text;
          return;
        }
        if (executeTool == null ||
            candidate?['finishReason'] != 'STOP' ||
            calls + functions.length > 10 ||
            round == 10) {
          throw const VertexAiException('Vertex AI 工具调用不完整、超过限制或未启用。');
        }
        for (final part in functions) {
          final function = part['functionCall'] as Map;
          if (!declarations.any((d) => d['name'] == function['name']) ||
              (function['args'] != null && function['args'] is! Map)) {
            throw const VertexAiException('Vertex AI 请求了未声明的工具或无效参数。');
          }
        }
        // Keep every model part, including thoughtSignature, exactly as returned.
        contents.add(Map<String, dynamic>.from(content!));
        final results = <Map<String, dynamic>>[];
        for (final part in functions) {
          final function = part['functionCall'] as Map;
          final result = await executeTool({
            'type': 'function',
            'function': {
              'name': function['name'],
              'arguments': jsonEncode(function['args'] ?? {}),
            },
          });
          calls++;
          results.add({
            'functionResponse': {
              'name': function['name'],
              if (function['id'] != null) 'id': function['id'],
              'response': {'result': result},
            },
          });
        }
        contents.add({'role': 'user', 'parts': results});
      }
    } on VertexAiException {
      rethrow;
    } on TimeoutException {
      throw const VertexAiException('Vertex AI 响应超时，请重试。');
    } on FormatException {
      throw const VertexAiException('Vertex AI 返回了无法解析的响应。');
    } on http.ClientException {
      throw const VertexAiException('Vertex AI 网络连接中断。');
    }
  }
}
