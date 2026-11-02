import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export struct TaskRoutingView {
  @Prop @Watch('refresh') eventJson: string = '{}';
  @Prop @Watch('refresh') refreshRevision: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private loaded: boolean = false;
  private applying: boolean = false;
  private pending: boolean = false;
  private pageEpoch: number = 0;
  private retryTimer: number = -1;
  private failures: number = 0;
  private attemptedRevision: number = -1;

  private clearRetry(): void {
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
  }

  private refresh(): void {
    this.pending = true;
    if (!this.loaded || this.applying) { return; }
    this.clearRetry();
    if (this.attemptedRevision !== this.refreshRevision) {
      this.attemptedRevision = this.refreshRevision; this.failures = 0;
    }
    const epoch = this.pageEpoch;
    const revision = this.refreshRevision;
    const payload = this.eventJson;
    const script = '(()=>{const event=' + payload + ';window.onNativeEvent(event);' +
      'return JSON.stringify({inputComputes:(event.devices||[]).filter(d=>d.role===\"compute\"||d.role===\"self\").length,' +
      'cards:document.querySelectorAll(\".flow-compute:not(.flow-cloud)\").length,' +
      'pendingCards:document.querySelectorAll(\".flow-compute.is-pending\").length});})()';
    this.pending = false; this.applying = true;
    Promise.resolve().then((): Promise<string> => this.controller.runJavaScript(script)).then((result: string): void => {
      if (epoch !== this.pageEpoch || !this.loaded) { return; }
      this.applying = false; this.failures = 0;
      hilog.info(0, 'NearbyChat', 'tablet-route-applied revision=%{public}d result=%{public}s', revision, result);
      if (this.pending || payload !== this.eventJson || revision !== this.refreshRevision) { this.refresh(); }
    }).catch((_error: Error): void => {
      if (epoch !== this.pageEpoch || !this.loaded) { return; }
      this.applying = false; this.pending = true; this.failures++;
      hilog.warn(0, 'NearbyChat', 'tablet-route-apply-failed revision=%{public}d attempt=%{public}d', revision, this.failures);
      if (this.failures <= 4) {
        this.retryTimer = setTimeout((): void => {
          this.retryTimer = -1; this.refresh();
        }, Math.min(4000, 250 * Math.pow(2, this.failures - 1)));
      }
    });
  }

  private pageReady(): void {
    this.clearRetry(); this.pageEpoch++; this.loaded = true;
    this.applying = false; this.failures = 0; this.refresh();
  }

  aboutToDisappear(): void {
    this.clearRetry(); this.pageEpoch++; this.loaded = false; this.applying = false;
  }
  build() {
    Web({ src: $rawfile('task-routing.html'), controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(false)
      .onPageEnd(() => { this.pageReady(); })
      .width('100%').height('100%')
  }
}
