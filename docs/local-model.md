# 本地模型接口

## 算力端推理

当前 Agent 的近场推理链路为：

```text
RemoteComputeModel → InferenceClient → InferenceRelay
  → InferenceHost → LocalChat → libgewu_probe.so → GEWU / KNPU
```

`LocalChat` 也支持同进程 llama.cpp 后端：模型目录含 GGUF 时改为

```text
InferenceHost → LocalChat → libllama_probe.so
  → llama_chat_apply_template / llama_decode
```

该路径不使用 HTTP server。模型通过算力端设置页导入到
`filesDir/models/<模型名>/`，可选 `llama.json` 指定模型文件、上下文、档位和能力。
第一版只公告 `text`，不把 GGUF 目录当作视觉模型。

算力端 Native 源码位于 [gewu_probe.cpp](../apps/compute-node/entry/src/main/cpp/gewu_probe.cpp)。LocalChat 从应用 `filesDir/models/Qwen2.5-7B-Instruct-Q4_N_0` 读取 api_config.json、params、tokenizer.json。Native 会话当前使用 knpu 和 max_ctx=32768；基础 legacy 双端另使用自己的会话配置。

LocalChat 管理请求标识、回调、取消与清理。InferenceHost 负责请求准入、结果消息与任务展示；一次本地推理结束不等于整个 Agent 任务结束。SDK 构建仍依赖设备提供 libqos 等系统能力，部署步骤见 [构建与运行](build-and-run.md)。

## 聊天端本地适配接口

`apps/agent-client` 还提供 `libllm.so` 和 `SessionBackedModel`，用于接入本地模型或由其他应用复用 agent-core。此路径不同于页面的 RemoteComputeModel：

```text
LocalLlmBinding → LlmNativeBinding → SessionBackedModel
  → libllm.so（AKI）→ GEWU
```

`entry` 加载 Native 模块并注入绑定；agent-core HAR 不直接导入该 .so。绑定接口包括 createSession、submitRequest、abortRequest、destroySession，以及运行库支持的协作启停/查询。

[LoopModelFactory](../apps/agent-client/agent-core/src/main/ets/model/LoopModelFactory.ets) 只有在接入方提供绑定且 useLocalLlm 启用时才选择本地适配，否则按提供方配置选择 HTTP 模型或脚本模型。该工厂的回退逻辑不能套用于页面近场 RemoteComputeModel；远端不可用时页面不会自动改用云端来完成同一次请求。

## 配置

配置模板位于 [llm_config.example.json](../apps/agent-client/entry/src/main/resources/rawfile/llm_config.example.json)。字段包括 useLocalLlm、localModelPath、localModelBackend、localModelMaxContext、localModelRequestType。localModelPath 由配置指定，不等于算力端固定的 models 目录。

协作模板另见 [主机配置](../apps/agent-client/entry/src/main/resources/rawfile/llm_config.collab-master.example.json) 和 [协作者配置](../apps/agent-client/entry/src/main/resources/rawfile/llm_config.collab-slave.example.json)。localCollaboration 对应 GEWU 会话与应用控制通道，涉及运行库支持、控制握手和会话生命周期，不是 ParallelTaskRunner 把独立请求发给不同算力的机制。

普通近场 Agent 部署不需要配置这些本地会话协作参数。不能根据模板或接口存在推断任意设备已支持模型层切分。

## 源码

- [LocalLlmBinding](../apps/agent-client/entry/src/main/ets/llm/LocalLlmBinding.ets)：entry Native 加载与绑定。
- [SessionBackedModel](../apps/agent-client/agent-core/src/main/ets/model/SessionBackedModel.ets)：本地模型适配。
- [llm_bridge.cpp](../apps/agent-client/entry/src/main/cpp/llm_bridge.cpp)：AKI 桥。
- [LocalChat](../apps/compute-node/entry/src/main/ets/llm/LocalChat.ets)：算力端请求生命周期。
