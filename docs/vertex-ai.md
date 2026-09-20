# Vertex AI 服务账号接入

应用支持独立的 **Vertex AI** 服务商，使用 Google Cloud 服务账号 JSON
签发 OAuth 访问令牌，调用原生 `generateContent` / `streamGenerateContent`。
Google Gemini 选项仍使用原来的 Interactions 接口。

## 在应用中配置

1. 打开 **设置 → AI 接口 → Vertex AI**。
2. 点击 **导入服务账号 JSON**，选择 Google Cloud 下载的 `service_account` 密钥。
3. **Project ID** 默认从文件读取，也可填写该账号已获授权的目标项目。
4. **Location** 可填写 `global` 或模型支持的区域，例如 `us-central1`。
5. **模型 ID** 填写 `gemini-2.5-flash` 等当前项目可用的 Gemini 模型。
6. 点击 **验证连接**，成功后点击 **保存**。验证会产生一次简短模型请求。

不需要填写 API Key、手动复制 access token 或自定义 Base URL。
密钥仅在点击保存后写入 `flutter_secure_storage`，取消导入页面不会保存。
访问令牌在内存中缓存，到期前刷新，HTTP 401 后重新认证并重试一次。
服务账号 JSON 不进入 SharedPreferences、数据导出或运行日志。
更换设备或恢复数据备份后，需要重新导入 JSON。
选择“移除已导入的密钥”并保存，可删除本机保存的凭据并停用此连接。

JSON 文件用于应用使用者自己的账号配置，不应打包进 APK、assets 或源代码。
目标项目需要启用 Vertex AI API、具备有效结算，服务账号需要相应模型调用权限
（通常为 Vertex AI User）。应用不会自动修改云端 IAM 或结算设置。

## 开发者验证

```bash
flutter pub get
dart run tool/verify_vertex_ai.dart /absolute/path/service-account.json gemini-2.5-flash global
flutter test test/vertex_ai_test.dart test/gemini_interactions_test.dart test/model_thinking_test.dart
```

验证脚本使用与应用相同的连接层，依次检查 OAuth、普通生成、SSE 流式响应和
无副作用的工具调用回合。只输出结果与项目/区域/模型，不输出密钥、JWT 或访问令牌。
此命令验证凭据和云端连接，不会代替应用向系统安全存储写入凭据。

聊天、建议回复、长期记忆及资料转换共用服务商路由。普通聊天使用 SSE；
角色聊天在启用 Agent 工具后仍逐轮使用 streamGenerateContent SSE，正文分片即时传递；完整接收并校验工具调用后才执行工具，保留模型原始
`thoughtSignature`。每轮对话最多执行 10 次工具调用，写入类工具顺序执行。
文本和内嵌附件转成 `contents/parts`，服务端仍会校验模型支持的 MIME 类型及大小。
Gemini 2.5 使用 thinkingBudget，Gemini 3 使用 thinkingLevel；未知型号不发送思考参数。

HTTP 403：检查 API、结算和权限；404：检查项目、区域和模型；429：检查配额或稍后重试。
响应被安全策略拦截或流中断时会显示错误，不会把空响应当作成功。

参考：[Vertex AI REST generateContent](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.endpoints/generateContent)、
[Google Dart 服务账号认证](https://pub.dev/documentation/googleapis_auth/latest/auth_io/obtainAccessCredentialsViaServiceAccount.html)。
