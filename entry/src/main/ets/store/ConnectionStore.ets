import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

// Persists the fish-agent connection profile:
//   - host / port / tls / rememberToken  -> @ohos.data.preferences (plain)
//   - token                              -> Asset Store Kit (encrypted at rest)
// All operations degrade gracefully (log + carry on) so storage hiccups never
// break the connect flow.

const PREF_NAME: string = 'fish_conn';
const KEY_HOST: string = 'host';
const KEY_PORT: string = 'port';
const KEY_TLS: string = 'tls';
const KEY_REMEMBER: string = 'remember_token';
const KEY_FONT: string = 'font_size';
const KEY_LINE_SPACING: string = 'line_spacing';
const KEY_THEME: string = 'theme_name';
const KEY_CURSOR_STYLE: string = 'cursor_style';
const KEY_CURSOR_BLINK: string = 'cursor_blink';
const KEY_SCROLLBACK: string = 'scrollback_lines';
const KEY_ONBOARDED: string = 'onboarded';
const KEY_FONT_FAMILY_UI: string = 'font_family_ui';
const KEY_FONT_FAMILY_TERM: string = 'font_family_term';
const KEY_FONT_SCALE_BOOST: string = 'font_scale_boost';
const KEY_CJK_VERTICAL_OFFSET: string = 'cjk_vertical_offset';
const KEY_CHARACTER_SPACING: string = 'character_spacing';
const KEY_SHOW_CRASH_ON_STARTUP: string = 'show_crash_on_startup';
const TOKEN_ALIAS: string = 'fish_agent_token';
const KEY_RESTORE_TABS: string = 'restore_tabs_enabled';
const KEY_SESSION_STATE: string = 'session_state';
const KEY_TAB_COMPACT: string = 'tab_compact';
const KEY_UI_SCHEME: string = 'ui_scheme';
// Notification preferences
const KEY_NOTIFY_ENABLED: string = 'notify_enabled';
const KEY_NOTIFY_COMPLETED: string = 'notify_completed';
const KEY_NOTIFY_AWAITING: string = 'notify_awaiting';
const KEY_NOTIFY_BACKGROUND_ONLY: string = 'notify_background_only';
const KEY_NOTIFY_BELL: string = 'notify_bell';

export interface SavedTab {
  title: string;
  host: string;
  port: number;
  token: string;
  tls: boolean;
  cwd?: string;
  shell?: string;
  sessionId?: string;  // PTY session id for server-side session persistence
}

export interface SavedSession {
  activeIndex: number;
  tabs: SavedTab[];
}

export interface NotificationPrefs {
  enabled: boolean;
  taskCompleted: boolean;
  taskAwaitingInput: boolean;
  onlyWhenBackground: boolean;
  bellEnabled: boolean;
}

export const DEFAULT_NOTIFICATION_PREFS: NotificationPrefs = {
  enabled: true,
  taskCompleted: true,
  taskAwaitingInput: true,
  onlyWhenBackground: true,
  bellEnabled: false,  // Bell is too noisy — off by default
};

const ASSET_NOT_FOUND: number = 24000002;

export interface ConnectionProfile {
  host: string;
  port: string;
  tls: boolean;
  rememberToken: boolean;
  token: string;
}

export const DEFAULT_PROFILE: ConnectionProfile = {
  host: '192.168.1.10',
  port: '8765',
  tls: false,
  rememberToken: false,
  token: ''
};

export interface TerminalPrefs {
  cursorStyle: number;   // 0=block, 1=underline, 2=bar
  cursorBlink: boolean;
  scrollbackLines: number;
}

export const DEFAULT_TERMINAL_PREFS: TerminalPrefs = {
  cursorStyle: 0,
  cursorBlink: true,
  scrollbackLines: 20000,
};

function strToBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function bytesToStr(b: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(b);
}

// Deterministic Asset Store alias for a per-tab token, keyed by host:port so
// tabs sharing one connection reuse the same encrypted credential.  FNV-1a hash
// keeps the alias short and free of characters Asset Store may reject.
function hostAlias(host: string, port: number): string {
  let h: number = 2166136261;
  const key: string = host + ':' + port;
  for (let i: number = 0; i < key.length; i++) {
    h ^= key.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return 'fish_tab_' + (h >>> 0).toString(16);
}

export class ConnectionStore {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async load(): Promise<ConnectionProfile> {
    const profile: ConnectionProfile = {
      host: DEFAULT_PROFILE.host,
      port: DEFAULT_PROFILE.port,
      tls: DEFAULT_PROFILE.tls,
      rememberToken: DEFAULT_PROFILE.rememberToken,
      token: ''
    };
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      profile.host = await pref.get(KEY_HOST, DEFAULT_PROFILE.host) as string;
      profile.port = await pref.get(KEY_PORT, DEFAULT_PROFILE.port) as string;
      profile.tls = await pref.get(KEY_TLS, DEFAULT_PROFILE.tls) as boolean;
      profile.rememberToken = await pref.get(KEY_REMEMBER, DEFAULT_PROFILE.rememberToken) as boolean;
    } catch (e) {
      console.error('fish-termload prefs failed: ' + JSON.stringify(e));
    }
    if (profile.rememberToken) {
      profile.token = await this.loadToken();
    }
    return profile;
  }

  async save(profile: ConnectionProfile): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_HOST, profile.host);
      await pref.put(KEY_PORT, profile.port);
      await pref.put(KEY_TLS, profile.tls);
      await pref.put(KEY_REMEMBER, profile.rememberToken);
      await pref.flush();
    } catch (e) {
      console.error('fish-termsave prefs failed: ' + JSON.stringify(e));
    }
    if (profile.rememberToken && profile.token.length > 0) {
      await this.saveToken(profile.token);
    } else {
      await this.clearToken();
    }
  }

  async loadFontSize(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_FONT, fallback) as number;
    } catch (e) {
      console.error('fish-termload fontSize failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontSize(size: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_FONT, size);
      await pref.flush();
    } catch (e) {
      console.error('fish-termsave fontSize failed: ' + JSON.stringify(e));
    }
  }

  async loadLineSpacing(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_LINE_SPACING, fallback) as number;
    } catch (e) {
      console.error('fish-term load lineSpacing failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveLineSpacing(spacing: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_LINE_SPACING, spacing);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save lineSpacing failed: ' + JSON.stringify(e));
    }
  }

  async loadTheme(fallback: string): Promise<string> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_THEME, fallback) as string;
    } catch (e) {
      console.error('fish-termload theme failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveTheme(name: string): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_THEME, name);
      await pref.flush();
    } catch (e) {
      console.error('fish-termsave theme failed: ' + JSON.stringify(e));
    }
  }

  async loadTerminalPrefs(fallback: TerminalPrefs): Promise<TerminalPrefs> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      const cursorStyle: number = await pref.get(KEY_CURSOR_STYLE, fallback.cursorStyle) as number;
      const cursorBlink: boolean = await pref.get(KEY_CURSOR_BLINK, fallback.cursorBlink) as boolean;
      const scrollbackLines: number = await pref.get(KEY_SCROLLBACK, fallback.scrollbackLines) as number;
      return { cursorStyle, cursorBlink, scrollbackLines };
    } catch (e) {
      console.error('fish-termload terminalPrefs failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveTerminalPrefs(prefs: TerminalPrefs): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_CURSOR_STYLE, prefs.cursorStyle);
      await pref.put(KEY_CURSOR_BLINK, prefs.cursorBlink);
      await pref.put(KEY_SCROLLBACK, prefs.scrollbackLines);
      await pref.flush();
    } catch (e) {
      console.error('fish-termsave terminalPrefs failed: ' + JSON.stringify(e));
    }
  }

  async loadOnboarded(): Promise<boolean> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_ONBOARDED, false) as boolean;
    } catch (e) {
      console.error('fish-termload onboarded failed: ' + JSON.stringify(e));
      return false;
    }
  }

  async saveOnboarded(done: boolean): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_ONBOARDED, done);
      await pref.flush();
    } catch (e) {
      console.error('fish-termsave onboarded failed: ' + JSON.stringify(e));
    }
  }

  async loadFontFamily(fallback: string, isUI: boolean): Promise<string> {
    const key = isUI ? KEY_FONT_FAMILY_UI : KEY_FONT_FAMILY_TERM;
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(key, fallback) as string;
    } catch (e) {
      console.error('fish-term load fontFamily failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontFamily(family: string, isUI: boolean): Promise<void> {
    const key = isUI ? KEY_FONT_FAMILY_UI : KEY_FONT_FAMILY_TERM;
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(key, family);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save fontFamily failed: ' + JSON.stringify(e));
    }
  }

  async loadFontScaleBoost(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_FONT_SCALE_BOOST, fallback) as number;
    } catch (e) {
      console.error('fish-term load fontScaleBoost failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontScaleBoost(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_FONT_SCALE_BOOST, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save fontScaleBoost failed: ' + JSON.stringify(e));
    }
  }

  async loadCjkVerticalOffset(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_CJK_VERTICAL_OFFSET, fallback) as number;
    } catch (e) {
      console.error('fish-term load cjkVerticalOffset failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveCjkVerticalOffset(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_CJK_VERTICAL_OFFSET, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save cjkVerticalOffset failed: ' + JSON.stringify(e));
    }
  }

  async loadCharacterSpacing(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_CHARACTER_SPACING, fallback) as number;
    } catch (e) {
      console.error('fish-term load characterSpacing failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveCharacterSpacing(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_CHARACTER_SPACING, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save characterSpacing failed: ' + JSON.stringify(e));
    }
  }

  async loadShowCrashOnStartup(): Promise<boolean> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_SHOW_CRASH_ON_STARTUP, true) as boolean;
    } catch (e) {
      console.error('fish-term load showCrashOnStartup failed: ' + JSON.stringify(e));
      return true;
    }
  }

  async saveShowCrashOnStartup(show: boolean): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_SHOW_CRASH_ON_STARTUP, show);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save showCrashOnStartup failed: ' + JSON.stringify(e));
    }
  }

  // Persist the tab session.  Non-sensitive fields go to preferences as a JSON
  // blob; per-tab tokens go to Asset Store (encrypted at rest), keyed by
  // host:port, so no credential ever lands in plaintext preferences.
  async saveSession(session: SavedSession): Promise<void> {
    await this.saveTabTokens(session.tabs);
    // Strip tokens from the preferences copy — they live in Asset Store only.
    const sanitized: SavedSession = {
      activeIndex: session.activeIndex,
      tabs: session.tabs.map((t: SavedTab): SavedTab => ({
        title: t.title,
        host: t.host,
        port: t.port,
        token: '',
        tls: t.tls,
        cwd: t.cwd,
        shell: t.shell,
        sessionId: t.sessionId
      }))
    };
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_SESSION_STATE, JSON.stringify(sanitized));
      await pref.flush();
    } catch (e) {
      console.error('fish-term save session failed: ' + JSON.stringify(e));
    }
  }

  // Load the persisted tab session.  Tabs are sanitized (entries with a missing
  // host or an invalid port are dropped) and tokens are resolved from Asset
  // Store keyed by host:port.  A legacy token still embedded in preferences is
  // honoured as a fallback so pre-upgrade saves keep working.
  async loadSession(): Promise<SavedSession | null> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      const raw: string = await pref.get(KEY_SESSION_STATE, '') as string;
      if (raw.length === 0) {
        return null;
      }
      const parsed: SavedSession = JSON.parse(raw) as SavedSession;
      if (!parsed.tabs || !Array.isArray(parsed.tabs)) {
        return null;
      }
      const tabs: SavedTab[] = [];
      for (let i: number = 0; i < parsed.tabs.length; i++) {
        const t: SavedTab = parsed.tabs[i];
        if (!t || typeof t.host !== 'string' || t.host.length === 0) {
          continue;
        }
        const port: number = Number(t.port);
        if (!Number.isInteger(port) || port <= 0 || port > 65535) {
          continue;
        }
        let token: string = typeof t.token === 'string' ? t.token : '';
        if (token.length === 0) {
          token = await this.loadTabToken(hostAlias(t.host, port));
        }
        tabs.push({
          title: typeof t.title === 'string' ? t.title : '',
          host: t.host,
          port: port,
          token: token,
          tls: t.tls === true,
          cwd: typeof t.cwd === 'string' && t.cwd.length > 0 ? t.cwd : undefined,
          shell: typeof t.shell === 'string' && t.shell.length > 0 ? t.shell : undefined,
          sessionId: typeof t.sessionId === 'string' && t.sessionId.length > 0 ? t.sessionId : undefined
        });
      }
      if (tabs.length === 0) {
        return null;
      }
      const activeIndexNum: number = Number(parsed.activeIndex);
      let activeIndex: number = Number.isInteger(activeIndexNum) ? activeIndexNum : 0;
      if (activeIndex < 0 || activeIndex >= tabs.length) {
        activeIndex = 0;
      }
      return { activeIndex, tabs };
    } catch (e) {
      console.error('fish-term load session failed: ' + JSON.stringify(e));
      return null;
    }
  }

  async saveRestoreTabsEnabled(enabled: boolean): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_RESTORE_TABS, enabled);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save restoreTabsEnabled failed: ' + JSON.stringify(e));
    }
  }

  async saveTabCompact(compact: boolean): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_TAB_COMPACT, compact);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save tabCompact failed: ' + JSON.stringify(e));
    }
  }

  async loadTabCompact(): Promise<boolean> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_TAB_COMPACT, false) as boolean;
    } catch (e) {
      console.error('fish-term load tabCompact failed: ' + JSON.stringify(e));
      return false;
    }
  }

  async loadRestoreTabsEnabled(): Promise<boolean> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_RESTORE_TABS, true) as boolean;
    } catch (e) {
      console.error('fish-term load restoreTabsEnabled failed: ' + JSON.stringify(e));
      return true;
    }
  }

  private async loadToken(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const res: Array<asset.AssetMap> = await asset.query(query);
      if (res.length > 0) {
        const secret: Uint8Array = res[0].get(asset.Tag.SECRET) as Uint8Array;
        if (secret) {
          return bytesToStr(secret);
        }
      }
    } catch (e) {
      const code: number = (e as BusinessError).code;
      if (code !== ASSET_NOT_FOUND) {
        console.error('fish-termload token failed: ' + JSON.stringify(e));
      }
    }
    return '';
  }

  private async saveToken(token: string): Promise<void> {
    await this.clearToken();
    try {
      const attr: asset.AssetMap = new Map();
      attr.set(asset.Tag.SECRET, strToBytes(token));
      attr.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attr);
    } catch (e) {
      console.error('fish-termsave token failed: ' + JSON.stringify(e));
    }
  }

  private async clearToken(): Promise<void> {
    await this.removeAsset(TOKEN_ALIAS);
  }

  // Remove an Asset Store entry, tolerating "not found".
  private async removeAsset(alias: string): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(alias));
      await asset.remove(query);
    } catch (e) {
      const code: number = (e as BusinessError).code;
      if (code !== ASSET_NOT_FOUND) {
        console.error('fish-term remove asset failed: ' + JSON.stringify(e));
      }
    }
  }

  // Upsert one token into Asset Store under `alias`, replacing any prior value.
  private async saveTabToken(alias: string, token: string): Promise<void> {
    await this.removeAsset(alias);
    try {
      const attr: asset.AssetMap = new Map();
      attr.set(asset.Tag.SECRET, strToBytes(token));
      attr.set(asset.Tag.ALIAS, strToBytes(alias));
      attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attr);
    } catch (e) {
      console.error('fish-term save tab token failed: ' + JSON.stringify(e));
    }
  }

  // Persist every distinct tab token (deduped by host:port) to Asset Store.
  private async saveTabTokens(tabs: SavedTab[]): Promise<void> {
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < tabs.length; i++) {
      const t: SavedTab = tabs[i];
      if (t.token.length === 0) {
        continue;
      }
      const alias: string = hostAlias(t.host, t.port);
      if (seen.has(alias)) {
        continue;
      }
      seen.add(alias);
      await this.saveTabToken(alias, t.token);
    }
  }

  // Load a per-host token previously stored by saveTabTokens.
  private async loadTabToken(alias: string): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const res: Array<asset.AssetMap> = await asset.query(query);
      if (res.length > 0) {
        const secret: Uint8Array = res[0].get(asset.Tag.SECRET) as Uint8Array;
        if (secret) {
          return bytesToStr(secret);
        }
      }
    } catch (e) {
      const code: number = (e as BusinessError).code;
      if (code !== ASSET_NOT_FOUND) {
        console.error('fish-term load tab token failed: ' + JSON.stringify(e));
      }
    }
    return '';
  }

  async loadNotificationPrefs(): Promise<NotificationPrefs> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      const enabled: boolean = await pref.get(KEY_NOTIFY_ENABLED, true) as boolean;
      const taskCompleted: boolean = await pref.get(KEY_NOTIFY_COMPLETED, true) as boolean;
      const taskAwaitingInput: boolean = await pref.get(KEY_NOTIFY_AWAITING, true) as boolean;
      const onlyWhenBackground: boolean = await pref.get(KEY_NOTIFY_BACKGROUND_ONLY, true) as boolean;
      const bellEnabled: boolean = await pref.get(KEY_NOTIFY_BELL, false) as boolean;
      return { enabled, taskCompleted, taskAwaitingInput, onlyWhenBackground, bellEnabled };
    } catch (e) {
      console.error(`Failed to load notification preferences. Code: ${(e as Object).toString()}`);
      return DEFAULT_NOTIFICATION_PREFS;
    }
  }

  async saveNotificationPrefs(prefs: NotificationPrefs): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_NOTIFY_ENABLED, prefs.enabled);
      await pref.put(KEY_NOTIFY_COMPLETED, prefs.taskCompleted);
      await pref.put(KEY_NOTIFY_AWAITING, prefs.taskAwaitingInput);
      await pref.put(KEY_NOTIFY_BACKGROUND_ONLY, prefs.onlyWhenBackground);
      await pref.put(KEY_NOTIFY_BELL, prefs.bellEnabled);
      await pref.flush();
    } catch (e) {
      console.error(`Failed to save notification preferences. Code: ${(e as Object).toString()}`);
    }
  }

  async loadUiScheme(): Promise<string> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_UI_SCHEME, 'refined') as string;
    } catch (e) {
      console.error('fish-term load ui scheme failed: ' + JSON.stringify(e));
      return 'refined';
    }
  }

  async saveUiScheme(scheme: string): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_UI_SCHEME, scheme);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save ui scheme failed: ' + JSON.stringify(e));
    }
  }
}
