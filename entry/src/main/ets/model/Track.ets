export class Track {
  path: string = '';
  title: string = '';
  artist: string = '';
  durationMs: number = 0;
  hasLyrics: boolean = false;

  constructor(path: string, title: string, artist: string, hasLyrics: boolean) {
    this.path = path;
    this.title = title;
    this.artist = artist;
    this.hasLyrics = hasLyrics;
  }
}

export class FilenameInfo {
  title: string = '';
  artist: string = '';
}

/// "01 - 杨宗纬 - 其实都没有" → (其实都没有, 杨宗纬)
export function parseFilename(name: string): FilenameInfo {
  const info = new FilenameInfo();
  const parts = name.split(' - ');
  if (parts.length >= 3) {
    info.artist = parts[parts.length - 2];
    info.title = parts[parts.length - 1];
  } else if (parts.length === 2) {
    info.artist = parts[0];
    info.title = parts[1];
  } else {
    info.title = name;
    info.artist = '未知歌手';
  }
  return info;
}

export class TimeFormat {
  static ms(ms: number): string {
    if (!Number.isFinite(ms) || ms < 0) {
      return '--:--';
    }
    const t = Math.floor(ms / 1000);
    const m = Math.floor(t / 60);
    const s = t % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }
}
