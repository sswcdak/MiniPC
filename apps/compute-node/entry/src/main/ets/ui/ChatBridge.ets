export class ChatBridge {
  private onSend: (text: string) => string;
  private onStop: () => void;
  private onConnect: () => void;
  private onPrepare: () => void;
  private onPick: () => void;
  private onClear: () => void;
  private onClearImage: () => void;
  private onSelectModel: (model: string) => string;
  private onModels: () => string;
  private onImportModel: () => string;
  private onLlamaStatus: () => string;
  private onTakeLlamaFirstOpen: () => boolean;
  private onOpenLlamaManager: () => void;
  private onSetOutputMode: (mode: string) => string;
  private onUsageSettings: () => string;
  private onSaveUsageSettings: (payload: string) => string;
  private onSetRouterAlgorithm: (name: string) => string;
  constructor(send: (text: string) => string, stop: () => void, connect: () => void, prepare: () => void,
    pick: () => void, clear: () => void = (): void => {}, clearImage: () => void = (): void => {},
    selectModel: (model: string) => string = (): string => '当前设备不支持切换模型。',
    models: () => string = (): string => 'null',
    importModel: () => string = (): string => '当前设备不支持导入模型。',
    llamaStatus: () => string = (): string => '{"state":"error","error":"unsupported"}',
    takeLlamaFirstOpen: () => boolean = (): boolean => false,
    openLlamaManager: () => void = (): void => {},
    setOutputMode: (mode: string) => string = (): string => '当前设备不支持切换输出方式。',
    usageSettings: () => string = (): string => 'null',
    saveUsageSettings: (payload: string) => string = (payload: string): string =>
      payload.length >= 0 ? '当前设备不支持修改累计统计。' : '',
    setRouterAlgorithm: (name: string) => string = (): string => '当前设备不支持切换路由算法。') {
    this.onSend = send; this.onStop = stop; this.onConnect = connect; this.onPrepare = prepare; this.onPick = pick;
    this.onClear = clear;
    this.onClearImage = clearImage;
    this.onSelectModel = selectModel;
    this.onModels = models;
    this.onImportModel = importModel;
    this.onLlamaStatus = llamaStatus;
    this.onTakeLlamaFirstOpen = takeLlamaFirstOpen;
    this.onOpenLlamaManager = openLlamaManager;
    this.onSetOutputMode = setOutputMode;
    this.onUsageSettings = usageSettings;
    this.onSaveUsageSettings = saveUsageSettings;
    this.onSetRouterAlgorithm = setRouterAlgorithm;
  }
  send(text: string): string { return this.onSend(text); }
  stop(): void { this.onStop(); }
  connect(): void { this.onConnect(); }
  prepare(): void { this.onPrepare(); }
  pickImage(): void { this.onPick(); }
  clear(): void { this.onClear(); }
  clearImage(): void { this.onClearImage(); }
  selectModel(model: string): string { return this.onSelectModel(model); }
  models(): string { return this.onModels(); }
  importModel(): string { return this.onImportModel(); }
  llamaStatus(): string { return this.onLlamaStatus(); }
  takeLlamaFirstOpen(): boolean { return this.onTakeLlamaFirstOpen(); }
  openLlamaManager(): void { this.onOpenLlamaManager(); }
  setOutputMode(mode: string): string { return this.onSetOutputMode(mode); }
  usageSettings(): string { return this.onUsageSettings(); }
  saveUsageSettings(payload: string): string { return this.onSaveUsageSettings(payload); }
  setRouterAlgorithm(name: string): string { return this.onSetRouterAlgorithm(name); }
}
