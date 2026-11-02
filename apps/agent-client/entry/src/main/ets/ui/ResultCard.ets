import { ResultTurn, resultElapsed, resultIsActive, resultPhaseLabel, resultSnippet, resultInputLabel } from './ResultOverview';

@Component
export struct ResultCard {
  @Prop @Watch('syncTurn') turn: ResultTurn = new ResultTurn();
  @Prop index: number = 1;
  @Prop displayScale: number = 1;
  @Prop compact: boolean = false;
  onOpen: (key: string) => void = (_key: string): void => {};
  @State elapsed: string = '—';
  @State failedImage: string = '';
  @State breathing: boolean = false;
  private visible: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void { this.elapsed = resultElapsed(this.turn, Date.now()); }
  aboutToDisappear(): void { this.visible = false; this.stopTimer(); this.syncBreathing(); }

  private syncTurn(): void {
    this.syncTimer();
    this.syncBreathing();
  }

  private syncBreathing(): void {
    const active = this.visible && (this.turn.phase === 'running' || this.turn.phase === 'prefill');
    if (active === this.breathing) return;
    this.getUIContext().animateTo(active ?
      { duration: 1800, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate } :
      { duration: 0, iterations: 1 }, (): void => { this.breathing = active; });
  }

  private surface(): string {
    if (resultIsActive(this.turn.phase)) return this.breathing ? '#CCDDFC' : '#E4EDFF';
    return this.turn.phase === 'done' ? '#E1F1E6' : '#FFFFFF';
  }

  private stopTimer(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private syncTimer(): void {
    this.stopTimer();
    this.elapsed = resultElapsed(this.turn, Date.now());
    if (this.visible && resultIsActive(this.turn.phase)) {
      this.timer = setInterval((): void => { this.elapsed = resultElapsed(this.turn, Date.now()); }, 1000);
    }
  }

  private color(): string {
    if (this.turn.phase === 'failed') return '#B6382D';
    if (this.turn.phase === 'partial') return '#8A590F';
    if (this.turn.phase === 'cancelled') return '#6B7F76';
    return resultIsActive(this.turn.phase) ? '#4C65BE' : '#217B59';
  }

  private tint(): string {
    if (this.turn.phase === 'failed') return '#FCEEEA';
    if (this.turn.phase === 'partial') return '#FBF3E5';
    if (this.turn.phase === 'cancelled') return '#EFF3F0';
    return resultIsActive(this.turn.phase) ? '#CBDAFA' : '#CEE6D6';
  }

  @Builder
  contentLine(label: string, text: string, input: boolean) {
    Row({ space: 8 * this.displayScale }) {
      Text(label).width(26 * this.displayScale).height(16 * this.displayScale).fontSize(10 * this.displayScale)
        .fontColor(input ? '#638573' : '#7C8C92').textAlign(TextAlign.Center)
        .backgroundColor(input ? '#EEF5F0' : '#F0F3F6').borderRadius(4 * this.displayScale)
      if (input && this.turn.imagePath.length > 0) {
        if (this.failedImage === this.turn.imagePath) {
          Image($r('app.media.task_image')).width(32 * this.displayScale).height(23 * this.displayScale)
            .padding(3 * this.displayScale).backgroundColor('#F2EEE6').borderRadius(5 * this.displayScale)
        } else {
          Image('file://' + this.turn.imagePath).width(32 * this.displayScale).height(23 * this.displayScale)
            .objectFit(ImageFit.Cover).borderRadius(5 * this.displayScale)
            .onError(() => { this.failedImage = this.turn.imagePath; })
        }
      }
      Text(text).fontSize(13 * this.displayScale).lineHeight(18 * this.displayScale).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        .fontColor(input ? '#244238' : this.turn.phase === 'failed' ? '#B6382D' : '#718478')
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  build() {
    Button() {
      Row() {
        Column() {
          Text(String(this.index).padStart(2, '0')).width(25 * this.displayScale).height(27 * this.displayScale)
            .fontSize(13 * this.displayScale).fontFamily('monospace').fontWeight(FontWeight.Medium).textAlign(TextAlign.Center)
            .fontColor(resultIsActive(this.turn.phase) ? '#536FC1' : '#6E8C7D')
            .backgroundColor(resultIsActive(this.turn.phase) ? '#D6E2FC' : '#D5E9DD').borderRadius(8 * this.displayScale)
            .border({ width: 1, color: resultIsActive(this.turn.phase) ? '#E0E7F8' : '#E2EAE5' })
        }.width((this.compact ? 28 : 36) * this.displayScale).justifyContent(FlexAlign.Center)
        Column({ space: 5 * this.displayScale }) {
          Row({ space: 4 * this.displayScale }) {
            if (resultIsActive(this.turn.phase)) {
              LoadingProgress().width(12 * this.displayScale).height(12 * this.displayScale).color(this.color()).accessibilityLevel('no')
            } else {
              Image(this.turn.phase === 'done' ? $r('app.media.result_done') : $r('app.media.result_notice'))
                .width(12 * this.displayScale).height(12 * this.displayScale).accessibilityLevel('no')
            }
            Text(resultPhaseLabel(this.turn.phase)).fontSize(13 * this.displayScale).fontWeight(FontWeight.Medium).fontColor(this.color())
          }.padding({ left: 5 * this.displayScale, right: 5 * this.displayScale, top: 3 * this.displayScale, bottom: 3 * this.displayScale })
            .backgroundColor(this.tint()).borderRadius(6 * this.displayScale)
          Row({ space: 3 * this.displayScale }) {
            Image($r('app.media.result_device')).width(10 * this.displayScale).height(10 * this.displayScale).accessibilityLevel('no')
            Text(this.turn.device || (resultIsActive(this.turn.phase) ? '等待分配' : '—'))
              .fontSize(12 * this.displayScale).fontColor('#74887E').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%')
        }.width((this.compact ? 86 : 94) * this.displayScale).padding({ left: 6 * this.displayScale, right: 6 * this.displayScale })
          .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        Column() {
          Text(this.elapsed).fontFamily('monospace').fontSize((this.elapsed.length > 5 ? 13 : 18) * this.displayScale)
            .fontWeight(FontWeight.Medium).fontColor(resultIsActive(this.turn.phase) ? '#4C65BE' : '#5C7568')
            .padding({ left: 4 * this.displayScale, right: 4 * this.displayScale, top: 5 * this.displayScale, bottom: 5 * this.displayScale })
            .backgroundColor(resultIsActive(this.turn.phase) ? '#D6E2FC' : '#D5E9DD').borderRadius(7 * this.displayScale)
            .accessibilityText('用时 ' + this.elapsed)
        }.width((this.compact ? 66 : 72) * this.displayScale).justifyContent(FlexAlign.Center)
        Column({ space: 6 * this.displayScale }) {
          this.contentLine('输入', resultInputLabel(this.turn), true)
          this.contentLine('输出', resultSnippet(this.turn.answer, 32) ||
            (this.turn.phase === 'empty' ? '—' : this.turn.phase === 'prefill' && this.turn.imagePath ? '正在理解图片…' :
              this.turn.phase === 'queued' ? '等待执行…' : '等待回答…'), false)
        }.layoutWeight(1).padding({ left: 12 * this.displayScale, right: 12 * this.displayScale })
          .margin({ top: 10 * this.displayScale, bottom: 10 * this.displayScale })
          .border({ width: { left: 1 }, color: resultIsActive(this.turn.phase) ? '#B8CCE9' : '#BFDCC8' }).alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 68 * this.displayScale }).alignItems(VerticalAlign.Center)
    }.type(ButtonType.Normal).width('100%').padding(0).borderRadius(13 * this.displayScale)
      .backgroundColor(this.surface())
      .border({ width: 1, color: resultIsActive(this.turn.phase) ? '#B8CCE9' : '#BFDCC8' })
      .shadow({ radius: 3, color: '#05173B2E', offsetY: 1 })
      .accessibilityText(resultPhaseLabel(this.turn.phase) + '，' + (this.turn.device || '未记录设备') + '，' +
        (this.turn.imagePath ? '图片输入，' : '') + '阅读完整对话：' + resultSnippet(this.turn.input, 24))
      .onAppear(() => { this.visible = true; this.syncTurn(); })
      .onClick(() => { this.onOpen(this.turn.key); })
  }
}
