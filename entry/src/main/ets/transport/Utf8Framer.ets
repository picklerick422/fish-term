import { util } from '@kit.ArkTS';

// Decodes a stream of UTF-8 byte frames into strings, buffering any trailing
// partial multibyte sequence until the next frame completes it (spec §4.2).
export class Utf8Framer {
  private decoder: util.TextDecoder = util.TextDecoder.create(
    'utf-8', { fatal: false, ignoreBOM: true });
  private readonly streamOpts: util.DecodeToStringOptions = { stream: true };

  push(bytes: Uint8Array): string {
    if (bytes.length === 0) {
      return '';
    }
    return this.decoder.decodeToString(bytes, this.streamOpts);
  }

  reset(): void {
    this.decoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  }
}
