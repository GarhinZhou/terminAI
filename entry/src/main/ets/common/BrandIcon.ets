// Brand icon for agent kinds, reusing herdrm's AgentIcons SVGs.
// The SVGs are currentColor monochrome; Image.fillColor tints them.
import { IconName, UiIcon } from './Icons';

@Component
export struct BrandIcon {
  @Prop kind: string = '';
  @Prop iconSize: number = 14;
  @Prop color: string = '#A3A3A3';
  @Prop isDark: boolean = true;

  static resOf(kind: string): Resource | null {
    const normalized = kind.toLowerCase();
    switch (normalized) {
      case 'claude': return $r('app.media.claude');
      case 'codex': return $r('app.media.codex');
      case 'cursor': return $r('app.media.cursor');
      case 'gemini': return $r('app.media.gemini');
      case 'grok': return $r('app.media.grok');
      case 'kimi': return $r('app.media.kimi');
      case 'opencode': return $r('app.media.opencode');
      case 'copilot': return $r('app.media.copilot');
      default:
        if (normalized.includes('claude')) return $r('app.media.claude');
        if (normalized.includes('codex')) return $r('app.media.codex');
        if (normalized.includes('cursor')) return $r('app.media.cursor');
        if (normalized.includes('gemini')) return $r('app.media.gemini');
        if (normalized.includes('grok')) return $r('app.media.grok');
        if (normalized.includes('kimi')) return $r('app.media.kimi');
        if (normalized.includes('opencode')) return $r('app.media.opencode');
        if (normalized.includes('copilot')) return $r('app.media.copilot');
        return null;
    }
  }

  static hasBrand(kind: string): boolean {
    return BrandIcon.resOf(kind) !== null;
  }

  static imageOf(kind: string): Resource {
    const resource = BrandIcon.resOf(kind);
    return resource === null ? $r('app.media.ui_spark') : resource;
  }

  build() {
    if (BrandIcon.hasBrand(this.kind)) {
      Image(BrandIcon.imageOf(this.kind))
        .width(this.iconSize)
        .height(this.iconSize)
        .fillColor(this.color)
        .objectFit(ImageFit.Contain)
        .accessibilityLevel('no')
    } else {
      UiIcon({
        name: this.kind.toLowerCase() === 'zsh' ? IconName.Terminal : IconName.Spark,
        iconSize: this.iconSize,
        color: this.color
      })
    }
  }
}
