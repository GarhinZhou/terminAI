// Project-local SVG icon system. Every glyph is bundled, scalable and tintable.
export enum IconName {
  NewAgent = 'new_agent',
  Terminal = 'terminal',
  Search = 'search',
  Folder = 'folder',
  Grid = 'grid',
  FolderAdd = 'folder_add',
  Settings = 'settings',
  SidebarHide = 'sidebar_hide',
  SidebarShow = 'sidebar_show',
  ChevronDown = 'chevron_down',
  ChevronRight = 'chevron_right',
  More = 'more',
  ArrowUp = 'arrow_up',
  Browse = 'browse',
  Spark = 'spark',
  Appearance = 'appearance',
  Agents = 'agents',
  Notifications = 'notifications',
  Info = 'info',
  Check = 'check',
  EmptyTerminal = 'empty_terminal'
}

@Component
export struct UiIcon {
  @Prop name: IconName = IconName.Terminal;
  @Prop iconSize: number = 18;
  @Prop color: string = '#A3A3A3';

  private resourceOf(): Resource {
    switch (this.name) {
      case IconName.NewAgent: return $r('app.media.ui_new_agent');
      case IconName.Terminal: return $r('app.media.ui_terminal');
      case IconName.Search: return $r('app.media.ui_search');
      case IconName.Folder: return $r('app.media.ui_folder');
      case IconName.Grid: return $r('app.media.ui_grid');
      case IconName.FolderAdd: return $r('app.media.ui_folder_add');
      case IconName.Settings: return $r('app.media.ui_settings');
      case IconName.SidebarHide: return $r('app.media.ui_sidebar_hide');
      case IconName.SidebarShow: return $r('app.media.ui_sidebar_show');
      case IconName.ChevronDown: return $r('app.media.ui_chevron_down');
      case IconName.ChevronRight: return $r('app.media.ui_chevron_right');
      case IconName.More: return $r('app.media.ui_more');
      case IconName.ArrowUp: return $r('app.media.ui_arrow_up');
      case IconName.Browse: return $r('app.media.ui_browse');
      case IconName.Spark: return $r('app.media.ui_spark');
      case IconName.Appearance: return $r('app.media.ui_appearance');
      case IconName.Agents: return $r('app.media.ui_agents');
      case IconName.Notifications: return $r('app.media.ui_notifications');
      case IconName.Info: return $r('app.media.ui_info');
      case IconName.Check: return $r('app.media.ui_check');
      case IconName.EmptyTerminal: return $r('app.media.ui_empty_terminal');
      default: return $r('app.media.ui_terminal');
    }
  }

  build() {
    Image(this.resourceOf())
      .width(this.iconSize)
      .height(this.iconSize)
      .fillColor(this.color)
      .objectFit(ImageFit.Contain)
      .accessibilityLevel('no')
  }
}
