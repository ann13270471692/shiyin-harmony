import { fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Track, FilenameInfo, parseFilename } from '../model/Track';

export class LibraryStore {
  private static inst: LibraryStore | null = null;

  static shared(): LibraryStore {
    if (LibraryStore.inst === null) {
      LibraryStore.inst = new LibraryStore();
    }
    return LibraryStore.inst;
  }

  tracks: Track[] = [];
  refreshing: boolean = false;
  private listeners: Array<() => void> = [];

  addListener(l: () => void): void {
    this.listeners.push(l);
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  musicDir(context: common.UIAbilityContext): string {
    const dir = context.filesDir + '/Music';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    return dir;
  }

  async refresh(context: common.UIAbilityContext): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      const dir = this.musicDir(context);
      const names = fs.listFileSync(dir);
      const tracks: Track[] = [];
      for (const n of names) {
        if (!n.toLowerCase().endsWith('.mp3')) {
          continue;
        }
        const path = dir + '/' + n;
        try {
          const st = fs.statSync(path);
          if (!st.isFile()) {
            continue;
          }
        } catch (e) {
          continue;
        }
        const base = n.substring(0, n.length - 4);
        const info: FilenameInfo = parseFilename(base);
        let hasLrc = false;
        try {
          hasLrc = fs.accessSync(dir + '/' + base + '.lrc');
        } catch (e) {
          hasLrc = false;
        }
        const t = new Track(path, info.title, info.artist, hasLrc);
        t.durationMs = await LibraryStore.probeDuration(path);
        tracks.push(t);
      }
      tracks.sort((a: Track, b: Track) => a.path.localeCompare(b.path));
      this.tracks = tracks;
      this.notify();
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'library refresh failed');
    } finally {
      this.refreshing = false;
    }
  }

  // 只删手机上已下载的副本（音频 + 同名歌词），电脑上的文件不受影响
  remove(track: Track): boolean {
    let ok = false;
    try {
      fs.unlinkSync(track.path);
      ok = true;
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'remove failed');
    }
    const lrc = track.path.substring(0, track.path.length - 4) + '.lrc';
    try {
      if (fs.accessSync(lrc)) {
        fs.unlinkSync(lrc);
      }
    } catch (e) {
      // 没有歌词文件，忽略
    }
    if (ok) {
      this.tracks = this.tracks.filter((t: Track) => t.path !== track.path);
      this.notify();
    }
    return ok;
  }

  private static async probeDuration(path: string): Promise<number> {
    let file: fs.File | null = null;
    try {
      const extractor = await media.createAVMetadataExtractor();
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      extractor.fdSrc = { fd: file.fd };
      const meta = await extractor.fetchMetadata();
      await extractor.release();
      const d = parseInt(meta.duration ?? '0', 10);
      return Number.isNaN(d) ? 0 : d;
    } catch (e) {
      return 0;
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }
}
