import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ai_services.dart';
import 'app_controller.dart';
import 'settings_detail_page.dart';
import 'vertex_ai.dart';

class VertexAiSettingsPage extends StatefulWidget {
  const VertexAiSettingsPage({
    super.key,
    required this.controller,
    this.secrets = const SecretStore(),
  });
  final AppController controller;
  final SecretStore secrets;

  @override
  State<VertexAiSettingsPage> createState() => _VertexAiSettingsPageState();
}

class _VertexAiSettingsPageState extends State<VertexAiSettingsPage> {
  final _form = GlobalKey<FormState>();
  late final _project = TextEditingController(
    text: widget.controller.vertexProjectId,
  );
  late final _location = TextEditingController(
    text: widget.controller.vertexLocation,
  );
  late final _model = TextEditingController(
    text: widget.controller.vertexModel,
  );
  String _json = '';
  String? _email;
  String? _status;
  bool _busy = true;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _enabled =
        widget.controller.llmProvider != LlmProvider.vertexAi ||
        widget.controller.aiEnabled;
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await widget.secrets.readVertexCredentials();
      final account = json.isEmpty ? null : VertexServiceAccount.parse(json);
      if (!mounted) return;
      setState(() {
        _json = json;
        _email = account?.email;
      });
    } catch (_) {
      if (mounted) setState(() => _status = '无法读取已保存的服务账号，请重新导入。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 65536) {
        throw const VertexAiException('服务账号文件过大，请选择 Google 下载的 JSON 密钥。');
      }
      final json = utf8.decode(bytes);
      final account = VertexServiceAccount.parse(json);
      if (!mounted) return;
      setState(() {
        _json = json;
        _email = account.email;
        if (_project.text.trim().isEmpty) _project.text = account.projectId;
        _status = '已导入，保存后生效。';
      });
    } on VertexAiException catch (error) {
      if (mounted) setState(() => _status = error.message);
    } catch (_) {
      if (mounted) setState(() => _status = '无法读取 JSON 文件，请重新选择。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit({required bool test}) async {
    if (!_form.currentState!.validate()) return;
    if (_json.isEmpty && (test || _enabled)) {
      setState(() => _status = '请先导入服务账号 JSON。');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final config = VertexAiConfig(
        projectId: _project.text.trim(),
        location: _location.text.trim(),
      );
      VertexAiConfig.endpoint(config.baseUrl, _model.text.trim());
      if (test) {
        final client = VertexAiClient();
        try {
          await client
              .chat(
                baseUrl: config.baseUrl,
                credentialJson: _json,
                model: _model.text.trim(),
                stream: false,
                messages: [
                  {'role': 'user', 'content': 'Reply with OK.'},
                ],
                generationConfig: {
                  'maxOutputTokens': 1024,
                  if (_model.text.trim().startsWith('gemini-2.5-flash'))
                    'thinkingConfig': {'thinkingBudget': 0},
                },
              )
              .join();
          if (mounted) setState(() => _status = '连接成功：认证及模型调用均已通过。尚未保存设置。');
        } finally {
          client.close();
        }
      } else {
        await widget.secrets.writeVertexCredentials(_json);
        widget.controller.configureVertexAi(
          enabled: _enabled,
          projectId: config.projectId,
          location: config.location,
          model: _model.text.trim(),
        );
        if (mounted) Navigator.of(context).pop(true);
      }
    } on VertexAiException catch (error) {
      if (mounted) setState(() => _status = error.message);
    } catch (_) {
      if (mounted) setState(() => _status = '操作失败，请检查系统安全存储和网络后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _project.dispose();
    _location.dispose();
    _model.dispose();
    _json = '';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsDetailPage(
    controller: widget.controller,
    title: const Text('Vertex AI'),
    content: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用 Vertex AI'),
            value: _enabled,
            onChanged: _busy ? null : (v) => setState(() => _enabled = v),
          ),
          const Text(
            '导入 Google Cloud 服务账号 JSON，自动获取和刷新访问令牌。密钥保存在本机安全存储中，不包含在数据备份内。',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('导入服务账号 JSON'),
          ),
          if (_email != null) ...[
            const SizedBox(height: 8),
            SelectableText('当前账号：$_email'),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _json = '';
                      _email = null;
                      _status = '保存后移除本机密钥。';
                      _enabled = false;
                    }),
              child: const Text('移除已导入的密钥'),
            ),
          ],
          const SizedBox(height: 16),
          TextFormField(
            controller: _project,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Project ID',
              helperText: '默认取自 JSON；可填写已授权的目标项目',
            ),
            validator: (v) =>
                RegExp(r'^[a-z0-9][a-z0-9-]{3,62}$').hasMatch(v?.trim() ?? '')
                ? null
                : '请填写有效的 Project ID',
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _location,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Location',
              helperText: '例如 global 或 us-central1',
            ),
            validator: (v) =>
                RegExp(r'^(global|[a-z]+-[a-z]+[0-9]+)$')
                    .hasMatch(v?.trim() ?? '')
                ? null
                : '请填写有效的区域',
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _model,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '模型 ID',
              helperText: '例如 gemini-2.5-flash',
            ),
            validator: (v) =>
                RegExp(r'^gemini-[a-zA-Z0-9._-]+$').hasMatch(v?.trim() ?? '')
                ? null
                : '请填写 Gemini 模型 ID',
          ),
          const SizedBox(height: 16),
          const Text('验证连接会发送一条简短测试请求，可能产生少量模型费用。'),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Semantics(liveRegion: true, child: Text(_status!)),
            ),
        ],
      ),
    ),
    actions: [
      OutlinedButton(
        onPressed: _busy ? null : () => _submit(test: true),
        child: const Text('验证连接'),
      ),
      FilledButton(
        onPressed: _busy ? null : () => _submit(test: false),
        child: const Text('保存'),
      ),
    ],
  );
}
