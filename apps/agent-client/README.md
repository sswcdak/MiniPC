# Agent 聊天端

HarmonyOS NEXT 聊天应用，负责 Agent 执行、工具调用、子任务编排和结果展示。默认页面通过 RemoteComputeModel 使用近场算力设备；本机工具在聊天设备运行。

顶部 Agent 开关默认关闭，并保存选择。关闭后是普通聊天：只发送当前消息、附件文字及本轮图片，不发送历史问答，也不初始化工具、拆分任务或执行答案审查。开启后使用 Agent 流程。两种模式均保留界面上的聊天记录；生成期间需先停止再切换模式。

连接建立后申请多设备连接后台任务。应用退到后台时保留近场连接与推理，只停止发现扫描；回到前台时恢复近场准备，应用销毁或主动断开时释放连接。

主页面下方显示「当前会话」的完整多轮记录。点击标题会向上展开聊天并折叠任务路由，再次点击还原。左侧抽屉单击会话即可切换主页记录和底部输入区；草稿、附件与追问上下文分别保存到各自会话。新建会话会复用已有的空白会话，首次发送时也可自动建立会话。清空按钮只清空当前会话，抽屉中另有清空全部和删除当前会话。

每轮记录显示输入、回答、执行状态、设备与实时用时，保留图片和思考行动内容。正在执行的会话禁止重复发送及清空；切换到其他会话后可以继续独立提交任务，后台任务按算力容量并发执行。停止和删除只作用于对应会话，持久化记录在重启后保留，中断的任务恢复为已停止状态。

任务路由图根据宽高自动排布和缩放，不产生内部滚动。正在计算的设备卡片使用接近白色的浅蓝背景，边框和轻微阴影缓慢呼吸；结束后恢复普通样式，系统要求减少动态效果时停用呼吸动画。名称、状态、内存条和百分比放大显示，设备图标保持原尺寸。

## 构建与运行

在 DevEco Studio 中打开本目录，安装 AGenUI 依赖并构建 entry。仓库根目录的命令行入口：

```powershell
.\scripts\build-hap.ps1 -Target agent-client -InstallDependencies
```

环境、签名和连接步骤见 [构建与运行](../../docs/build-and-run.md)。本工程 bundleName 为 com.jiuwen.registrychatui，应与算力端分别安装到不同设备。版本号以 [AppScope](AppScope/app.json5) 为准。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| entry/src/main/ets/pages/Index.ets | 页面、会话历史、任务状态和最终展示 |
| entry/src/main/ets/model | 近场模型适配、多请求与取消范围 |
| entry/src/main/ets/nearby | 设备发现和近场通信 |
| entry/src/main/ets/protocol | 推理消息及分片校验 |
| agent-core/src/main/ets/agent | ReAct、工具契约和任务接口 |
| agent-core/src/main/ets/agent/parallel | 独立子任务拆分、执行和汇总 |

流程见 [Agent 执行](../../docs/agent-workflow.md)、[多算力协作](../../docs/multi-compute.md) 和 [外部集成](../../docs/integrations.md)。本地 Native 适配接口见 [本地模型](../../docs/local-model.md)。

## 测试

从仓库根目录运行 `node scripts/test-all.cjs agent`；也可单独执行 `node apps/agent-client/agent-core/tests/run-all.cjs`。TypeScript 环境及覆盖范围见 [测试](../../docs/testing.md)。
