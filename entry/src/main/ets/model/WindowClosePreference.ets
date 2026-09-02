import { common } from '@kit.AbilityKit';
import { TerminaiPreferences } from './TerminaiPreferences';

const PREF_CLOSE_BEHAVIOR_CONFIGURED = 'closeBehaviorConfigured';
const PREF_KEEP_BACKGROUND_ON_CLOSE = 'keepBackgroundOnClose';

export class WindowClosePolicy {
  configured: boolean = false;
  keepBackground: boolean = true;

  constructor(configured: boolean, keepBackground: boolean) {
    this.configured = configured;
    this.keepBackground = keepBackground;
  }
}

/** Persistent policy shared by EntryAbility and the ArkUI settings dialog. */
export class WindowClosePreference {
  static load(context: common.Context): WindowClosePolicy {
    try {
      const store = TerminaiPreferences.get(context);
      const configuredValue = store.getSync(PREF_CLOSE_BEHAVIOR_CONFIGURED, false);
      const keepBackgroundValue = store.getSync(PREF_KEEP_BACKGROUND_ON_CLOSE, true);
      const configured = typeof configuredValue === 'boolean' ? configuredValue : false;
      const keepBackground = typeof keepBackgroundValue === 'boolean' ? keepBackgroundValue : true;
      return new WindowClosePolicy(configured, keepBackground);
    } catch (error) {
      console.error('TERMINAI load window close preference failed: ' + JSON.stringify(error));
      return new WindowClosePolicy(false, true);
    }
  }

  /** Saving from either the first-run prompt or Settings completes the one-time choice. */
  static save(context: common.Context, keepBackground: boolean): boolean {
    try {
      const store = TerminaiPreferences.get(context);
      store.putSync(PREF_KEEP_BACKGROUND_ON_CLOSE, keepBackground);
      store.putSync(PREF_CLOSE_BEHAVIOR_CONFIGURED, true);
      store.flushSync();
      AppStorage.setOrCreate('keepBackgroundOnClose', keepBackground);
      AppStorage.setOrCreate('closeBehaviorConfigured', true);
      return true;
    } catch (error) {
      console.error('TERMINAI save window close preference failed: ' + JSON.stringify(error));
      return false;
    }
  }

  static publish(context: common.Context): WindowClosePolicy {
    const policy = WindowClosePreference.load(context);
    AppStorage.setOrCreate('keepBackgroundOnClose', policy.keepBackground);
    AppStorage.setOrCreate('closeBehaviorConfigured', policy.configured);
    return policy;
  }
}
