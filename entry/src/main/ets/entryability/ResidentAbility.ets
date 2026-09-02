import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BackgroundSessionService } from '../model/BackgroundSessionService';
import { ResidentSessionBackend } from '../model/ResidentSessionBackend';
import { StatusBarResidentService } from '../model/StatusBarResidentService';
import { TerminaiPreferences } from '../model/TerminaiPreferences';

/** Invisible UIAbility bound to the PC status-bar item in the app process. */
export default class ResidentAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const applicationContext = this.context.getApplicationContext();
    TerminaiPreferences.configure(applicationContext);
    StatusBarResidentService.bindResidentContext(this.context);
    BackgroundSessionService.configure(this.context);
    // The visible EntryAbility owns persistence lifecycle rearming. A resident
    // Ability can start while explicit exit is already underway, so it only
    // supplies context and monitoring here.
    ResidentSessionBackend.shared().configure(applicationContext, false);
  }

  onDestroy(): void {
    StatusBarResidentService.unbindResidentContext(this.context);
  }
}
