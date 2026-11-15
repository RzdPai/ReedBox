import { Profile } from '../../model/Profile';
import { bytesText, endpointText, protocolName, protocolTint } from '../Format';
import { Theme } from '../Theme';
import { ProfileRowModel } from './ProfileRowSource';

/** Preserve the three-row profile layout while observing a stable row model. */
@ComponentV2
export struct ProfileCard {
  @Param row: ProfileRowModel = new ProfileRowModel(new Profile());
  @Event onSelect: (profile: Profile) => void = (profile: Profile): void => {};
  @Event onEdit: (profile: Profile) => void = (profile: Profile): void => {};
  @Event onShare: (profile: Profile) => void = (profile: Profile): void => {};
  @Event onRemove: (profile: Profile) => void = (profile: Profile): void => {};
  @Event onMore: (profile: Profile) => void = (profile: Profile): void => {};

  private trafficVisible(): boolean {
    return this.row.profile.rx + this.row.profile.tx !== 0;
  }

  private trafficText(): string {
    if (!this.trafficVisible()) {
      return '';
    }
    return `↑${bytesText(this.row.profile.tx)} ↓${bytesText(this.row.profile.rx)}`;
  }

  private addressText(): string {
    if (this.row.profile.name.trim().length === 0 || !this.row.showAddress) {
      return '';
    }
    const address: string = endpointText(this.row.profile, true);
    return this.trafficVisible() && address.length >= 30 ? `${address.substring(0, 27)}...` : address;
  }

  private showSecondLine(): boolean {
    return !((!this.trafficVisible() || this.row.profile.latencyMs === 0) && this.addressText().length === 0);
  }

  private latencyText(): string {
    if (this.row.profile.latencyMs > 0) {
      return `可用 ${this.row.profile.latencyMs} ms`;
    }
    return this.row.profile.latencyMs < 0 ? '不可用' : '';
  }

  private latencyColor(): ResourceColor {
    if (this.row.profile.latencyMs < 0) {
      return Theme.DANGER;
    }
    return this.row.profile.latencyMs > 0 ? Theme.OK : Theme.TEXT_3;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 2 }) {
        if (this.row.profile.pinned) {
          SymbolGlyph($r('sys.symbol.pin_fill'))
            .fontSize('11fp')
            .fontColor([Theme.BRAND])
            .margin({ right: 2 })
        }
        Text(this.row.profile.name.trim().length > 0
          ? this.row.profile.name : `${this.row.profile.server}:${this.row.profile.serverPort}`)
          .fontSize('16fp')
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 右上角只留一颗 grid 图标：点它 = 原来的行菜单（编辑/分享/移动/删除都在里面）
        ProfileCardAction({
          actionSymbol: $r('sys.symbol.dot_grid_1x2'),
          actionId: `profile_more_btn_${this.row.profileId}`,
          onTap: (): void => {
            this.onMore(this.row.currentProfile());
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showSecondLine()) {
        Row({ space: 8 }) {
          Text(this.addressText())
            .fontSize('11fp')
            .fontColor(Theme.TEXT_3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.trafficText().length > 0) {
            Text(this.trafficText())
              .fontSize('11fp')
              .fontColor(Theme.TEXT_3)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        Text(protocolName(this.row.profile.type))
          .fontSize('11fp')
          .fontColor(protocolTint(this.row.profile.type))
        Blank()
        if (this.latencyText().length > 0) {
          Text(this.latencyText())
            .fontSize('11fp')
            .fontColor(this.latencyColor())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .id(`profile_more_${this.row.profileId}`)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 8, top: 10, bottom: 12 })
    .borderRadius(18)
    .backgroundColor(this.row.selected ? Theme.BRAND_SOFT : Theme.SURFACE)
    .border({
      width: { left: 4 },
      color: this.row.selected ? Theme.BRAND : (this.row.running ? Theme.OK : Color.Transparent)
    })
    .onClick((): void => {
      if (this.row.canSelect) {
        this.onSelect(this.row.currentProfile());
      }
    })
  }
}

/** Separate click targets keep edit/share/delete from selecting the outer card. */
@ComponentV2
struct ProfileCardAction {
  @Param actionSymbol: Resource = $r('sys.symbol.square_and_pencil');
  @Param actionId: string = '';
  @Param destructive: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Row() {
      SymbolGlyph(this.actionSymbol)
        .fontSize('16fp')
        .fontColor([this.destructive ? Theme.DANGER : Theme.TEXT_3])
    }
    .id(this.actionId)
    .width(30)
    .height(30)
    .borderRadius(15)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onTouch((event: TouchEvent): void => {
      event.stopPropagation();
    })
    .onClick((): void => {
      this.onTap();
    })
  }
}
