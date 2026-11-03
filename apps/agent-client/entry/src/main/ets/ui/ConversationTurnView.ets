import { ResultTurn, resultElapsed, resultIsActive, resultPhaseLabel } from './ResultOverview';

/** The selected conversation's complete exchange, including live execution metadata. */
@Component
export struct ConversationTurnView {
  @Prop @Watch('syncTimer') turn: ResultTurn = new ResultTurn();
  @State elapsed: string = '—';
  private timer: number = -1;
  private visible: boolean = false;

  aboutToAppear(): void { this.visible = true; this.syncTimer(); }
  aboutToDisappear(): void { this.visible = false; this.stopTimer(); }

  private stopTimer(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private syncTimer(): void {
    this.elapsed = resultElapsed(this.turn, Date.now());
    if (!this.visible || !resultIsActive(this.turn.phase)) { this.stopTimer(); return; }
    if (this.timer >= 0) return;
    this.timer = setInterval((): void => { this.elapsed = resultElapsed(this.turn, Date.now()); }, 1000);
  }

  build() {
    Column({ space: 10 }) {
      if (this.turn.imagePath.length > 0) {
        Image('file://' + this.turn.imagePath).width('100%').aspectRatio(1.6).constraintSize({ maxHeight: 300 })
          .borderRadius(12).objectFit(ImageFit.Contain).backgroundColor('#F2EEE6')
          .accessibilityText('发送的图片')
      }
      if (this.turn.input.length > 0 && !(this.turn.imagePath.length > 0 && this.turn.input === '（附图）')) {
        Text(this.turn.input).fontSize(15).lineHeight(26).fontColor('#16332C').copyOption(CopyOptions.LocalDevice)
          .width('100%').padding(12).backgroundColor('#D8F3EA').borderRadius(12)
      }
      Row({ space: 8 }) {
        Text(resultPhaseLabel(this.turn.phase)).fontSize(11).fontColor('#6B7F79')
        if (this.turn.device.length > 0) {
          Text(this.turn.device).fontSize(11).fontColor('#6B7F79').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        } else {
          Blank()
        }
        Text(this.elapsed).fontSize(11).fontColor('#6B7F79')
          .accessibilityText('本轮用时 ' + this.elapsed)
      }.width('100%')
      Text(this.turn.answer || (this.turn.phase === 'hub-queued' ? '等待路由中心分派…' : this.turn.phase === 'queued' ? '等待执行…' :
        this.turn.phase === 'sending' ? '正在发送…' : this.turn.phase === 'loading' ? '正在加载模型…' :
        this.turn.phase === 'preparing' ? '正在准备…' : this.turn.phase === 'prefill' ? '正在理解问题…' : resultIsActive(this.turn.phase) ? '正在生成…' : '暂无回答'))
        .fontSize(15).lineHeight(27).fontColor(this.turn.phase === 'failed' ? '#C4473A' : '#16332C')
        .copyOption(CopyOptions.LocalDevice).width('100%').padding(12).backgroundColor('#F7FBFA').borderRadius(12)
      if (this.turn.process.length > 0) {
        Text('思考和行动').fontSize(12).fontColor('#6B7F79').width('100%')
        Text(this.turn.process).fontSize(13).lineHeight(22).fontColor('#6B7F79').copyOption(CopyOptions.LocalDevice)
          .width('100%').padding(12).backgroundColor('#F7FBFA').borderRadius(12)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
