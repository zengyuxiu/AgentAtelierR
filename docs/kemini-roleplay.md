# Kemini 原预设与原生演出协议

角色聊天以用户提供的 Kemini Dramatron v3.1 原始 JSON 为主体，按条目顺序执行宏、角色资料占位和历史插入，只新增一个动画与语音协议条目。用户建议回复、记忆整理等专用任务不使用这套角色预设。

## 原文件与生效配置

原文件完整保存在本地 `assets/presets/kemini_dramatron_v3_1.json`，不修改源文件。它包含 55 个条目，原执行顺序列出 50 个；未进入顺序的 5 个条目保留但不执行。运行配置新增 `agentatelier.native.performance.v1`，插在最终续写条目 `jailbreak` 前面，所有原条目的相对顺序保持不变。目前运行配置为 56 个条目、51 个顺序项、29 个启用项；启用项包含只设置变量和空占位的条目，不等于发给服务商的消息数量。

按用户最终选择应用以下覆盖：

| 条目 | 生效状态 |
| --- | --- |
| `095b5c1f-cf5f-48e8-a6aa-e25c882ea754` 普通防截断 | 启用，原内容保留 |
| `a443f257-0f5d-4286-a1ff-f60653ed6400` 雪融雪降长篇示例 | 关闭 |
| `main` CLEAR | 关闭 |
| `enhanceDefinitions` 伪造助手确认 | 关闭 |
| Tavern Helper 脚本、两套原正则列表 | 全部关闭 |
| `show_thoughts` | 关闭 |

混合条目保留写作要求，仅按明确的行前缀屏蔽无关部分：ROLE AND GUIDE 中的模型身份和内测审查声明、ICOT 中的安全覆盖声明、最终续写条目中的隐藏思考 token 预算指令。具体 ID 和前缀见 `lib/src/kemini_preset.dart` 的 `keminiSuppressedLinePrefixes`。除这些覆盖外，其余条目沿用原启用状态，未批量打开原先禁用的可选项。

原始 JSON 是本地素材，不纳入 Git。新检出需要先安装用户提供的同版本文件：

```bash
python3 tool/install_kemini_preset.py '/absolute/path/Kemini_Dramatron_v3.1(1).json'
```

安装器校验 SHA-256，并拒绝覆盖不同内容。原文件 SHA-256 为 `3d394088a2b4c19a6d819a9cfba7bfacb372296a626c1192eaa6cab62c383968`。

## 执行方式

`AppController.buildCharacterPromptPlan()` 生成结构化计划，公共聊天入口调用 `KeminiPromptPlan.assemble()`。`buildCharacterPrompt()` 仅提供预览，不作为实际聊天的扁平注入来源。

- 按原顺序执行 `setvar`、`getvar`、`trim`、注释及用户名称宏，保留正文示例占位字面量。未知的活动功能宏明确报错。
- 在原 marker 位置插入世界、用户、角色、场景、记忆、宿主工具规则及聊天历史；未提供的任务或结果保持空白。
- 原三段交错结构、文风、人物规则和正文长度要求继续由原预设控制。
- 输入包装和输出元数据隐藏由原生代码实现，不执行 Tavern JavaScript 或 HTML。流式过滤隐藏 thinking、disclaimer、Reference_Example 内容，并去掉 Interleaving 外壳，正文继续送入展示、语音和动画解析。
- 精简上下文只压缩运行时资料和历史，不压缩或重写预设条目。源 JSON 中的采样参数等设置保留存档，不代表已经自动应用到模型请求。

OpenAI 兼容接口保留原消息角色。Vertex 和 Gemini Interactions 通过原位置的 `preset_system` 用户消息块保留逻辑顺序，统一系统指令说明其含义；这是有序适配，并不等同于每个条目拥有独立的原生 system 优先级。Gemini Content 的原生角色限制见[官方 Content 文档](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/Content)。

## 动画与语音

新增协议只约束故事正文的台本表达，原预设的外层结构仍保留：

| 内容 | 原生表达 | 消费端 |
| --- | --- | --- |
| 场景、第三人称叙述、角色内心 | `旁白：正文` | 旁白展示 |
| 莱莎说出口的话 | `莱莎：[情绪][face:表情][action:动作]正文` | 语音、表情、动作队列 |
| 已知 NPC 台词 | `角色[角色ID]：正文` | NPC 展示 |
| 台词翻译 | `译文：正文` | 翻译展示 |

标签选择受实际运行时动作、表情和姿态能力约束。小说叙述不能直接修改任务、背包或地图，工具结果仍以真实调用为准。

“普通防截断”是原条目的名称，保留该声明不意味着能够改变服务商过滤、输出 token 上限或网络中断行为。

## 验证

自动测试覆盖源文件字节一致性、运行覆盖、原顺序和宏、历史位置、流式元数据过滤，以及 OpenAI、Vertex、Gemini Interactions 三条请求路径。

```bash
flutter test
flutter analyze
```

真实 Vertex 验证（产生模型调用费用）：

```bash
flutter test test/kemini_roleplay_prompt_test.dart --plain-name 'live Vertex' \
  --dart-define=VERTEX_SERVICE_ACCOUNT_FILE=/absolute/path/service-account.json
```

测试使用默认角色和合成输入，经过公共聊天入口及实际 Vertex 请求，检查可解析台本、标签、正文长度和语音文本。复核文件写入 `/tmp/agentatelier-kemini-effective.json`、`/tmp/agentatelier-kemini-request.json` 和 `/tmp/agentatelier-kemini-sample.txt`；不记录认证头或凭证内容。该验证不替代真机动画与音频验收。
