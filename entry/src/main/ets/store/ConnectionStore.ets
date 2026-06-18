import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

// Persists the wand-agent connection profile:
//   - host / port / tls / rememberToken  -> @ohos.data.preferences (plain)
//   - token                              -> Asset Store Kit (encrypted at rest)
// All operations degrade gracefully (log + carry on) so storage hiccups never
// break the connect flow.

const PREF_NAME: string = 'wand_conn';
const KEY_HOST: string = 'host';
const KEY_PORT: string = 'port';
const KEY_TLS: string = 'tls';
const KEY_REMEMBER: string = 'remember_token';
const KEY_FONT: string = 'font_size';
const TOKEN_ALIAS: string = 'wand_agent_token';
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

function strToBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function bytesToStr(b: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(b);
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
      console.error('wand load prefs failed: ' + JSON.stringify(e));
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
      console.error('wand save prefs failed: ' + JSON.stringify(e));
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
      console.error('wand load fontSize failed: ' + JSON.stringify(e));
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
      console.error('wand save fontSize failed: ' + JSON.stringify(e));
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
        console.error('wand load token failed: ' + JSON.stringify(e));
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
      console.error('wand save token failed: ' + JSON.stringify(e));
    }
  }

  private async clearToken(): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, strToBytes(TOKEN_ALIAS));
      await asset.remove(query);
    } catch (e) {
      const code: number = (e as BusinessError).code;
      if (code !== ASSET_NOT_FOUND) {
        console.error('wand clear token failed: ' + JSON.stringify(e));
      }
    }
  }
}
