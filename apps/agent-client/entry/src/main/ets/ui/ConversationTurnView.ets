import { ResultTurn, resultElapsed, resultIsActive, resultPhaseLabel } from './ResultOverview';
import { chatCharacterLabel } from './ChatTextMetrics';

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

  private replyText(): string {
    return this.turn.answer || (this.turn.phase === 'hub-queued' ? '等待路由中心分派…' : this.turn.phase === 'queued' ? '等待执行…' :
      this.turn.phase === 'sending' ? '正在发送…' : this.turn.phase === 'loading' ? '正在加载模型…' :
      this.turn.phase === 'preparing' ? '正在准备…' : this.turn.phase === 'prefill' ? '正在理解问题…' : resultIsActive(this.turn.phase) ? '正在生成…' : '暂无回答');
  }

  @Builder
  textBubble(text: string, user: boolean, process: boolean = false) {
    Column({ space: 6 }) {
      Text(text).fontSize(process ? 13 : 15).lineHeight(process ? 22 : 27)
        .fontColor(process ? '#6B7F79' : !user && this.turn.phase === 'failed' ? '#C4473A' : '#16332C')
        .copyOption(CopyOptions.LocalDevice).width('100%')
      Text(chatCharacterLabel(text)).fontSize(11).lineHeight(16).fontColor('#617A71')
        .width('100%').textAlign(TextAlign.End).accessibilityText('内容字数 ' + chatCharacterLabel(text))
    }.width('100%').padding(12).backgroundColor(user ? '#D8F3EA' : '#F7FBFA').borderRadius(12)
  }

  build() {
    Column({ space: 10 }) {
      if (this.turn.imagePath.length > 0 || this.turn.input.length > 0) {
        Row() {
          Column({ space: 8 }) {
            if (this.turn.imagePath.length > 0) {
              Image('file://' + this.turn.imagePath).width('100%').aspectRatio(1.6).constraintSize({ maxHeight: 300 })
                .borderRadius(12).objectFit(ImageFit.Contain).backgroundColor('#F2EEE6')
                .accessibilityText('发送的图片')
            }
            if (this.turn.input.length > 0 && !(this.turn.imagePath.length > 0 && this.turn.input === '（附图）')) {
              this.textBubble(this.turn.input, true)
            }
          }.width('90%').alignItems(HorizontalAlign.Start)
        }.width('100%').justifyContent(FlexAlign.End)
      }
      Column({ space: 8 }) {
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
        this.textBubble(this.replyText(), false)
        if (this.turn.process.length > 0) {
          Text('思考和行动').fontSize(12).fontColor('#6B7F79').width('100%')
          this.textBubble(this.turn.process, false, true)
        }
      }.width('90%').alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
