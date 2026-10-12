import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/// 从 MP3 的 ID3v2 标签里读 USLT 内嵌歌词（移植自 iOS 版 ID3Parser）
export class EmbeddedLyrics {
  static read(path: string): string | null {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const head = new ArrayBuffer(10);
      if (fs.readSync(file.fd, head, { length: 10 }) < 10) {
        return null;
      }
      const hv = new DataView(head);
      if (hv.getUint8(0) !== 0x49 || hv.getUint8(1) !== 0x44 || hv.getUint8(2) !== 0x33) {
        return null;
      }
      const major = hv.getUint8(3);
      if (major < 3) {
        return null;
      }
      const size = (hv.getUint8(6) << 21) | (hv.getUint8(7) << 14) | (hv.getUint8(8) << 7) | hv.getUint8(9);
      if (size <= 0 || size > 2 * 1024 * 1024) {
        return null;
      }
      const tag = new ArrayBuffer(size);
      if (fs.readSync(file.fd, tag, { length: size }) < size) {
        return null;
      }
      const dv = new DataView(tag);
      let pos = 0;
      let best: string | null = null;
      while (pos + 10 <= size) {
        let id = '';
        for (let i = 0; i < 4; i++) {
          id += String.fromCharCode(dv.getUint8(pos + i));
        }
        if (!new RegExp('^[A-Z0-9]{4}$').test(id)) {
          break;
        }
        let frameSize = 0;
        if (major === 4) {
          frameSize = (dv.getUint8(pos + 4) << 21) | (dv.getUint8(pos + 5) << 14) | (dv.getUint8(pos + 6) << 7) | dv.getUint8(pos + 7);
        } else {
          frameSize = dv.getUint32(pos + 4, false);
        }
        if (frameSize <= 0 || pos + 10 + frameSize > size) {
          break;
        }
        if (id === 'USLT') {
          const text = EmbeddedLyrics.decodeUSLT(tag, pos + 10, frameSize);
          if (text !== null && text.trim().length > 0 && (best === null || best.length === 0)) {
            best = text;
          }
        }
        pos += 10 + frameSize;
      }
      return best;
    } catch (e) {
      return null;
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  private static decodeUSLT(buf: ArrayBuffer, off: number, len: number): string | null {
    if (len < 5) {
      return null;
    }
    const bytes = new Uint8Array(buf);
    const enc = bytes[off];
    let p = off + 1 + 3; // 跳过编码字节 + 语言(3)
    if (enc === 0 || enc === 3) {
      while (p < off + len && bytes[p] !== 0) {
        p++;
      }
      p++;
    } else {
      while (p + 1 < off + len && !(bytes[p] === 0 && bytes[p + 1] === 0)) {
        p += 2;
      }
      p += 2;
    }
    const n = off + len - p;
    if (n <= 0) {
      return null;
    }
    const slice = bytes.subarray(p, p + n);
    try {
      if (enc === 3) {
        return EmbeddedLyrics.decodeUtf8(slice);
      }
      if (enc === 1) {
        if (slice.length >= 2 && slice[0] === 0xFF && slice[1] === 0xFE) {
          return EmbeddedLyrics.decodeUtf16(slice.subarray(2), false);
        }
        if (slice.length >= 2 && slice[0] === 0xFE && slice[1] === 0xFF) {
          return EmbeddedLyrics.decodeUtf16(slice.subarray(2), true);
        }
        return EmbeddedLyrics.decodeUtf16(slice, false);
      }
      if (enc === 2) {
        return EmbeddedLyrics.decodeUtf16(slice, true);
      }
      let s = '';
      for (let i = 0; i < slice.length; i++) {
        s += String.fromCharCode(slice[i]);
      }
      return s;
    } catch (e) {
      return null;
    }
  }

  private static decodeUtf8(slice: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(slice);
  }

  private static decodeUtf16(slice: Uint8Array, bigEndian: boolean): string {
    let s = '';
    for (let i = 0; i + 1 < slice.length; i += 2) {
      const u = bigEndian ? (slice[i] << 8) | slice[i + 1] : (slice[i + 1] << 8) | slice[i];
      s += String.fromCharCode(u);
    }
    return s;
  }
}
