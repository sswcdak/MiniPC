interface TabletLlamaDevice {
  id: string;
  name: string;
  role: string;
  ready: boolean;
  jobs: number;
  slot?: number;
  model?: string;
  inferenceBackend?: string;
  memTotal?: number;
  memAvail?: number;
  memUsage?: number;
  cpuUsage?: number;
  thermalLevel?: number;
  batteryTemp?: number;
  capabilities?: string[];
  pendingInfo?: boolean;
}

interface TabletLlamaSnapshot {
  devices?: TabletLlamaDevice[];
}

interface TabletTopologyNode {
  id: string;
  title: string;
  rankLabel: string;
  address: string;
  online: boolean;
  model: string;
  memoryBytes: number;
  expertBytes: number;
  diskBytes: number;
  hit: number;
  cpu: string;
  temperature: string;
}

interface TabletLlamaConfig {
  model: string;
  contextSize: number;
  otherArgs: string;
  hotCold: boolean;
  expertSkip: boolean;
  skipRange: string;
  distMode: string;
  peerIp: string;
  roleMaster: boolean;
  port: number;
}

interface TabletLlamaRuntime {
  state?: string;
  rss?: number;
  expertRam?: number;
  disk?: number;
  hit?: number;
}

interface TabletLlamaState {
  ok?: boolean;
  message?: string;
  models?: string[];
  config?: TabletLlamaConfig;
  runtime?: TabletLlamaRuntime;
  peer?: TabletLlamaPeer;
}

const ORIGINAL_MODEL_MEMORY_BYTES: number = 45 * 1024 * 1024 * 1024;

interface TabletLlamaPeer {
  online?: boolean;
  ready?: boolean;
  serving?: boolean;
  ip?: string;
  rank?: number;
  rss?: number;
  expertRam?: number;
  hit?: number;
  disk?: number;
  memTotal?: number;
  memAvail?: number;
  updatedAt?: number;
}

function percentText(value: number | undefined): string {
  return value !== undefined && Number.isFinite(value) ? Math.round(value).toString() + '%' : '—';
}

function temperatureText(value: number | undefined): string {
  return value !== undefined && Number.isFinite(value) ? Math.round(value).toString() + '℃' : '—';
}

function byteText(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return '—';
  }
  const gb = bytes / 1024 / 1024 / 1024;
  if (gb >= 1) {
    return gb.toFixed(1) + ' GB';
  }
  return (bytes / 1024 / 1024).toFixed(0) + ' MB';
}

@Component
export struct TabletLlamaManagerView {
  @Prop eventJson: string = '{}';
  @Prop @Watch('applyManagerState') stateJson: string = '{}';
  @Prop refreshRevision: number = 0;
  @Prop focusDeviceId: string = '';
  onClose: () => void = (): void => {};
  onRefresh: () => void = (): void => {};
  onSaveConfig: (configJson: string) => void = (_configJson: string): void => {};

  @State managerModels: string[] = [];
  @State modelOptions: SelectOption[] = [];
  @State selectedModel: string = '';
  @State contextSize: number = 4096;
  @State port: number = 8080;
  @State otherArgs: string = '--memory-budget 14336';
  @State hotColdOn: boolean = true;
  @State bisectOn: boolean = true;
  @State skipRange: string = '5:20';
  @State distMode: string = 'layer';
  @State peerIp: string = '';
  @State roleIsMaster: boolean = true;
  @State managerMessage: string = '正在读取算力端 Llama 配置';
  @State runtimeState: string = 'idle';
  @State runtimeRss: number = 0;
  @State runtimeExpertRam: number = 0;
  @State runtimeDisk: number = 0;
  @State runtimeHit: number = -1;
  @State peerOnline: boolean = false;
  @State peerRank: number = 1;
  @State peerRss: number = 0;
  @State peerExpertRam: number = 0;
  @State peerDisk: number = 0;
  @State peerHit: number = -1;
  @State formDirty: boolean = false;

  private applyManagerState(): void {
    try {
      const state = JSON.parse(this.stateJson) as TabletLlamaState;
      const config = state.config;
      if (config !== undefined && !this.formDirty) {
        this.selectedModel = config.model;
        this.contextSize = config.contextSize;
        this.port = config.port;
        this.otherArgs = config.otherArgs;
        this.hotColdOn = config.hotCold;
        this.bisectOn = config.expertSkip;
        this.skipRange = config.skipRange;
        this.distMode = config.distMode;
        this.peerIp = config.peerIp;
        this.roleIsMaster = config.roleMaster;
      }
      const models = state.models ?? [];
      this.managerModels = models;
      this.modelOptions = models.map((name: string): SelectOption => ({ value: name }));
      if (this.selectedModel.length === 0 && models.length > 0) {
        this.selectedModel = models[0];
      }
      const runtime = state.runtime;
      this.runtimeState = runtime?.state ?? 'idle';
      this.runtimeRss = runtime?.rss ?? 0;
      this.runtimeExpertRam = runtime?.expertRam ?? 0;
      this.runtimeDisk = runtime?.disk ?? 0;
      this.runtimeHit = runtime?.hit ?? -1;
      const peer = state.peer;
      this.peerOnline = peer?.online === true;
      this.peerRank = peer?.rank ?? 1;
      this.peerRss = peer?.rss ?? 0;
      this.peerExpertRam = peer?.expertRam ?? 0;
      this.peerDisk = peer?.disk ?? 0;
      this.peerHit = peer?.hit ?? -1;
      if (this.peerOnline && peer?.ip !== undefined && peer.ip.length > 0 && this.peerIp.length === 0) {
        this.peerIp = peer.ip;
      }
      this.managerMessage = state.message && state.message.length > 0 ? state.message : '配置已同步';
    } catch (_error) {
      this.managerMessage = '算力端 Llama 配置尚未同步';
    }
  }

  private computeDevices(): TabletLlamaDevice[] {
    try {
      const snapshot = JSON.parse(this.eventJson) as TabletLlamaSnapshot;
      return (snapshot.devices ?? []).filter((device: TabletLlamaDevice): boolean =>
        device.role !== 'chat' && device.pendingInfo !== true);
    } catch (_error) {
      return [];
    }
  }

  private topologyNodes(): TabletTopologyNode[] {
    const devices = this.computeDevices();
    const nodes: TabletTopologyNode[] = [];
    for (let index = 0; index < devices.length; index++) {
      const device = devices[index];
      const slot = device.slot !== undefined && device.slot > 0 ? device.slot : index + 1;
      const isPrimary = index === 0;
      const memoryBytes = isPrimary && this.runtimeRss > 0 ? this.runtimeRss :
        (!isPrimary && this.peerRss > 0 ? this.peerRss :
          (device.memTotal !== undefined && device.memUsage !== undefined ? device.memTotal * device.memUsage / 100 : 0));
      nodes.push({
        id: device.id,
        title: isPrimary ? '算力主节点' : '级联对端',
        rankLabel: 'rank' + Math.max(0, slot - 1).toString(),
        address: isPrimary ? '近场连接' : (this.peerIp.length > 0 ? this.peerIp : '协同地址待同步'),
        online: device.ready || (!isPrimary && this.peerOnline),
        model: device.model && device.model.length > 0 ? device.model :
          (isPrimary ? '模型信息待同步' : (this.peerOnline ? '级联推理状态已同步' : '模型信息待同步')),
        memoryBytes: memoryBytes,
        expertBytes: isPrimary ? this.runtimeExpertRam : this.peerExpertRam,
        diskBytes: isPrimary ? this.runtimeDisk : this.peerDisk,
        hit: isPrimary ? this.runtimeHit : this.peerHit,
        cpu: percentText(device.cpuUsage),
        temperature: temperatureText(device.batteryTemp)
      });
    }
    if (nodes.length < 2 && this.peerIp.length > 0) {
      nodes.push({
        id: 'configured-peer:' + this.peerIp,
        title: '级联对端',
        rankLabel: 'rank' + this.peerRank.toString(),
        address: this.peerIp,
        online: this.peerOnline,
        model: this.peerOnline ? '级联推理状态已同步' : '等待级联节点同步模型信息',
        memoryBytes: this.peerRss,
        expertBytes: this.peerExpertRam,
        diskBytes: this.peerDisk,
        hit: this.peerHit,
        cpu: '—',
        temperature: '—'
      });
    }
    return nodes;
  }

  private selectedModelValue(): string {
    return this.selectedModel.length > 0 ? this.selectedModel : '选择内置模型（沙箱）';
  }

  private distModeLabel(): string {
    if (this.distMode === 'expert') return '专家并行';
    if (this.distMode === 'neuron') return '神经元并行';
    return 'PP（流水线并行）';
  }

  private runtimeLabel(): string {
    if (this.runtimeState === 'ready' || this.runtimeState === 'busy') return 'Llama.cpp 已就绪';
    if (this.runtimeState === 'loading') return 'Llama.cpp 正在加载';
    if (this.runtimeState === 'error') return 'Llama.cpp 启动失败';
    return 'Llama.cpp 尚未启动';
  }

  private hitText(hit: number): string {
    return hit >= 0 ? hit.toFixed(0) + '%' : '—';
  }

  private actualMemoryBytes(): number {
    const nodes = this.topologyNodes();
    const activeNodes = nodes.filter((node: TabletTopologyNode): boolean =>
      node.memoryBytes >= 1024 * 1024 * 1024);
    // PP 双机等分时，任一节点短暂空闲不能把另一台的推理占用当作整个集群占用。
    if (nodes.length >= 2 && activeNodes.length === 1) {
      return activeNodes[0].memoryBytes * nodes.length;
    }
    let total = 0;
    for (const node of nodes) {
      total += node.memoryBytes;
    }
    return total;
  }

  private actualMemoryGb(): number {
    return this.actualMemoryBytes() / 1024 / 1024 / 1024;
  }

  private actualMemoryPct(): number {
    if (this.actualMemoryBytes() <= 0) return 0;
    return Math.min(100, this.actualMemoryBytes() * 100 / ORIGINAL_MODEL_MEMORY_BYTES);
  }

  private savedMemoryPct(): number {
    return Math.max(0, Math.round(100 - this.actualMemoryPct()));
  }

  private saveConfig(): void {
    const config: TabletLlamaConfig = {
      model: this.selectedModel,
      contextSize: this.contextSize,
      otherArgs: this.otherArgs,
      hotCold: this.hotColdOn,
      expertSkip: this.bisectOn,
      skipRange: this.skipRange,
      distMode: this.distMode,
      peerIp: this.peerIp,
      roleMaster: this.roleIsMaster,
      port: this.port
    };
    this.managerMessage = '正在保存到算力端...';
    this.formDirty = false;
    this.onSaveConfig(JSON.stringify(config));
  }

  @Builder
  topologyMetric(label: string, value: string, color: string) {
    Column({ space: 2 }) {
      Text(label).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#3F5851')
      Text(value).fontSize(16).fontWeight(FontWeight.Bold).fontColor(color)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  private topologySystemPct(): number {
    return 9 * 100 / 24;
  }

  private topologyMemoryPct(node: TabletTopologyNode): number {
    const capacity = 24 * 1024 * 1024 * 1024;
    return Math.min(100 - this.topologySystemPct(), node.memoryBytes * 100 / capacity);
  }

  private topologyExpertPct(node: TabletTopologyNode): number {
    const capacity = 24 * 1024 * 1024 * 1024;
    return Math.min(this.topologyMemoryPct(node), node.expertBytes * 100 / capacity);
  }

  @Builder
  topologyMemoryBar(node: TabletTopologyNode) {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(12)
        .backgroundColor('#E8EEF1')
        .borderRadius(6)
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width('100%')
          .height(12)
          .backgroundColor('#5E6662')
        Text('系统 9G')
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width(this.topologySystemPct().toString() + '%')
      .height(12)
      .borderRadius({ topLeft: 6, topRight: 0, bottomLeft: 6, bottomRight: 0 })
      .clip(true)
      Row()
        .width(this.topologyMemoryPct(node).toString() + '%')
        .height(12)
        .backgroundColor('#A6D9CD')
        .borderRadius({ topLeft: 0, topRight: 6, bottomLeft: 0, bottomRight: 6 })
        .position({ x: this.topologySystemPct().toString() + '%', y: 0 })
      Row()
        .width(this.topologyExpertPct(node).toString() + '%')
        .height(8.4)
        .backgroundColor('#126B5A')
        .borderRadius({ topLeft: 0, topRight: 4.2, bottomLeft: 0, bottomRight: 4.2 })
        .position({ x: this.topologySystemPct().toString() + '%', y: 1.8 })
    }
    .width('100%')
    .height(12)
  }

  @Builder
  topologyNode(node: TabletTopologyNode) {
    Column({ space: 12 }) {
      Row({ space: 16 }) {
        Column() {
          Row().width(76).height(42).borderRadius(5)
            .border({ width: 2, color: '#354B43' }).backgroundColor('#F6FBF9')
          Row().width(40).height(5).borderRadius(3).backgroundColor('#354B43').margin({ top: 4 })
        }
        .width(104)
        .alignItems(HorizontalAlign.Center)
        Column({ space: 10 }) {
          Row({ space: 6 }) {
            Text(node.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#16332C')
            Text(node.rankLabel)
              .fontSize(11)
              .fontColor('#0F8A74')
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor('#E7F5F0')
              .borderRadius(8)
          }
          Row({ space: 6 }) {
            Row().width(7).height(7).borderRadius(4)
              .backgroundColor(node.online ? '#15966D' : '#C58A28')
            Text(node.online ? '在线' : '等待同步').fontSize(12)
              .fontColor(node.online ? '#15966D' : '#A77517')
          }
          Row({ space: 18 }) {
            this.topologyMetric('推理内存占用', byteText(node.memoryBytes), '#2E6F61')
            this.topologyMetric('专家缓存', byteText(node.expertBytes), '#155A4D')
            this.topologyMetric('热点专家命中', this.hitText(node.hit), '#16332C')
          }
          .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      this.topologyMemoryBar(node)
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#F8FBFA')
    .border({ width: 1, color: '#DDE8E4' })
    .borderRadius(14)
  }

  @Builder
  topologyConnector() {
    Row() {
      Blank().width(52)
      Column({ space: 1 }) {
        Row().width(2).height(14).backgroundColor('#8CB6A8')
        Text('↓').fontSize(18).fontColor('#4C8C78').height(20)
      }
      .width(104)
      .alignItems(HorizontalAlign.Center)
      Blank()
    }
    .width('100%')
    .height(38)
  }

  @Builder
  memoryComparison() {
    Column({ space: 12 }) {
      Row() {
        Text('内存优化效果').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#16332C')
        Blank()
        Text('降低约 ' + this.savedMemoryPct().toString() + '%')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0F8A74')
      }
      Text('同一模型独立运行原需约 45 GB 内存，协同推理后实际占用明显降低。')
        .fontSize(13)
        .fontColor('#52665F')
        .width('100%')
      Column({ space: 6 }) {
        Row() {
          Text('原模型独立运行').fontSize(13).fontColor('#52665F')
          Blank()
          Text('45 GB').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#16332C')
        }
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(15)
            .backgroundColor('#E8EEF1')
            .borderRadius(7.5)
          Row()
            .width('100%')
            .height(15)
            .backgroundColor('#91A7B5')
            .borderRadius(7.5)
        }
          .width('100%')
          .height(15)
      }
      Column({ space: 6 }) {
        Row() {
          Text('当前集群实际推理占用').fontSize(13).fontColor('#52665F')
          Blank()
          Text(this.actualMemoryGb().toFixed(1) + ' GB')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0F8A74')
        }
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(15)
            .backgroundColor('#E8F5F0')
            .borderRadius(7.5)
          Row()
            .width(this.actualMemoryPct().toString() + '%')
            .height(15)
            .backgroundColor('#2F8A74')
            .borderRadius(7.5)
        }
          .width('100%')
          .height(15)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#F3FAF7')
    .borderRadius(14)
    .border({ width: 1, color: '#CDE8DD' })
  }

  @Builder
  topologySection() {
    Column({ space: 12 }) {
      Row() {
        Text('设备拓扑').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#16332C')
        Blank()
        Text(this.topologyNodes().length.toString() + ' 个节点')
          .fontSize(12)
          .fontColor('#0F8A74')
      }
      ForEach(this.topologyNodes(), (node: TabletTopologyNode, index: number) => {
        this.topologyNode(node)
        if (index < this.topologyNodes().length - 1) {
          this.topologyConnector()
        }
      }, (node: TabletTopologyNode) => node.id + ':' + node.online.toString() + ':' + this.refreshRevision.toString())
      if (this.topologyNodes().length > 0) {
        this.memoryComparison()
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(16)
    .border({ width: 1, color: '#DDE8E4' })
  }

  @Builder
  configurationSection() {
    Column({ space: 4 }) {
      Row() {
        Text('Llama.cpp 推理配置').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#16332C')
        Blank()
        Text(this.runtimeLabel())
          .fontSize(12)
          .fontColor(this.runtimeState === 'ready' || this.runtimeState === 'busy' ? '#15966D' : '#A77517')
      }
      Row({ space: 10 }) {
        Select(this.modelOptions)
          .layoutWeight(1)
          .height(40)
          .value(this.selectedModelValue())
          .onSelect((index: number): void => {
            if (index >= 0 && index < this.managerModels.length) {
              this.selectedModel = this.managerModels[index];
              this.formDirty = true;
            }
          })
        Button('保存')
          .width(116)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor('#0F8A74')
          .enabled(this.selectedModel.length > 0)
          .onClick((): void => { this.saveConfig(); })
      }
      .width('100%')
      Row() {
        Text('分布式模式').fontSize(14).fontColor('#52665F')
        Blank()
        Select([{ value: 'PP（流水线并行）' }, { value: '专家并行' }, { value: '神经元并行' }])
          .selected(this.distMode === 'layer' ? 0 : (this.distMode === 'expert' ? 1 : 2))
          .value(this.distModeLabel())
          .width(280)
          .height(38)
          .font({ size: 14 })
          .selectedOptionFont({ size: 14 })
          .optionFont({ size: 14 })
          .backgroundColor('#F5F8F7')
          .borderRadius(10)
          .onSelect((index: number): void => {
            this.distMode = index === 0 ? 'layer' : (index === 1 ? 'expert' : 'neuron');
            this.formDirty = true;
          })
      }
      .width('100%')
      Row() {
        Text('冷热分层').fontSize(14).fontColor('#52665F')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.hotColdOn })
          .onChange((on: boolean): void => { this.hotColdOn = on; this.formDirty = true; })
      }
      .width('100%')
      Row() {
        Text('专家跳过').fontSize(14).fontColor('#52665F')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.bisectOn })
          .onChange((on: boolean): void => { this.bisectOn = on; this.formDirty = true; })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(Color.White)
    .borderRadius(16)
    .border({ width: 1, color: '#DDE8E4' })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Button('←')
          .width(42)
          .height(42)
          .fontSize(20)
          .fontColor('#0F8A74')
          .backgroundColor('#EAF6F2')
          .borderRadius(12)
          .accessibilityText('返回算力面板')
          .onClick((): void => { this.onClose(); })
        Text('Llama 管理').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#16332C')
        Blank()
        Row({ space: 6 }) {
          Row().width(8).height(8).borderRadius(4)
            .backgroundColor(this.runtimeState === 'ready' || this.runtimeState === 'busy' ? '#15966D' : '#C58A28')
          Text(this.runtimeLabel()).fontSize(12).fontColor('#52665F')
        }
      }
      .width('100%')
      .height(64)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.White)
      .border({ width: { bottom: 1 }, color: '#DDE8E4' })
      Scroll() {
        Column({ space: 10 }) {
          this.topologySection()
          this.configurationSection()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .padding(14)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EEF6F3')
  }
}
