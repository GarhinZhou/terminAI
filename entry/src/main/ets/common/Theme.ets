// Design tokens ported from herdrm's Theme.swift (waku-derived), light/dark.
export class Theme {
  // ── text ramp (herdrm exact) ──
  static text(dark: boolean): string {
    return dark ? '#E2E2E2' : '#242424';
  }

  static subText(dark: boolean): string {
    return dark ? '#A3A3A3' : '#666666';
  }

  static tertiary(dark: boolean): string {
    return dark ? '#7D7D7D' : '#858585';
  }

  static faintText(dark: boolean): string {
    return dark ? '#575757' : '#A4A4A4';
  }

  // ── accent + status (herdrm exact) ──
  /** Salmon accent (herdrm), overridable via AppStorage "accent". */
  static accent(dark: boolean): string {
    const custom = AppStorage.get<string>('accent');
    if (custom !== undefined && custom.length > 0) {
      return custom;
    }
    return dark ? '#E2795B' : '#C85F44';
  }

  static accentWash(dark: boolean): string {
    return dark ? '#33E2795B' : '#1FC85F44';
  }

  static working(dark: boolean): string {
    return dark ? '#3B82F6' : '#2563EB';
  }

  static success(dark: boolean): string {
    return dark ? '#62C987' : '#2FA35F';
  }

  static warning(dark: boolean): string {
    return dark ? '#E0B36A' : '#B8862E';
  }

  static danger(dark: boolean): string {
    return dark ? '#E2726A' : '#C94F44';
  }

  // ── surfaces ──
  static windowBg(dark: boolean): string {
    return dark ? '#181818' : '#F6F6F6';
  }

  static terminalBg(dark: boolean): string {
    return dark ? '#101012' : '#FFFFFF';
  }

  static panel(dark: boolean): string {
    return dark ? '#1E1E20' : '#F0F0F0';
  }

  static card(dark: boolean): string {
    return dark ? '#27272A' : '#FFFFFF';
  }

  static input(dark: boolean): string {
    return dark ? '#2A2A2E' : '#FFFFFF';
  }

  static button(dark: boolean): string {
    return dark ? '#353538' : '#DFDFE2';
  }

  static buttonGhost(dark: boolean): string {
    return dark ? '#2F2F31' : '#E4E4E6';
  }

  static divider(dark: boolean): string {
    return dark ? '#1FFFFFFF' : '#14000000';
  }

  static selected(dark: boolean): string {
    return dark ? '#24FFFFFF' : '#10000000';
  }

  static hover(dark: boolean): string {
    return dark ? '#22FFFFFF' : '#10000000';
  }

  static pressed(dark: boolean): string {
    return dark ? '#3AFFFFFF' : '#24000000';
  }

  static border(dark: boolean): string {
    return dark ? '#2BFFFFFF' : '#1A000000';
  }

  static workingWash(dark: boolean): string {
    return dark ? '#243B82F6' : '#182563EB';
  }

  static successWash(dark: boolean): string {
    return dark ? '#2462C987' : '#182FA35F';
  }

  /** Text on accent background: white or near-black based on luminance. */
  static onAccent(dark: boolean): string {
    const hex = Theme.accent(dark).replace('#', '');
    if (hex.length !== 6) return '#ffffff';
    const r = parseInt(hex.substring(0, 2), 16);
    const g = parseInt(hex.substring(2, 4), 16);
    const b = parseInt(hex.substring(4, 6), 16);
    const lum = 0.299 * r + 0.587 * g + 0.114 * b;
    return lum > 150 ? '#0e1420' : '#ffffff';
  }
}
