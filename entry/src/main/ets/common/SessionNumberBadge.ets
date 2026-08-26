import { Theme } from './Theme';

/** Compact numeric badge shared by sidebar, title bar and search results. */
@Component
export struct SessionNumberBadge {
  @Prop value: number = 1;
  @Prop isDark: boolean = true;

  build() {
    Text(this.value.toString())
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.tertiary(this.isDark))
      .textAlign(TextAlign.Center)
      .height(18)
      .constraintSize({ minWidth: 18 })
      .padding({ left: 5, right: 5 })
      .backgroundColor(Theme.button(this.isDark))
      .borderRadius(6)
      .accessibilityText('序号 ' + this.value.toString())
  }
}
