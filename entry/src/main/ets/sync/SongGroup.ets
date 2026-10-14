import { RemoteFile } from './SyncDownloader';
import { pinyinFull } from '../util/FuzzyMatch';

/// 导入页的一行 = 一首歌：mp3 和它的歌词绑在一起，选一次两个都下。
/// 电脑上没有歌词的歌，lyric 为 null，下载时自然跳过，不提示。
export class SongEntry {
  key: string = '';            // 去掉扩展名的文件名，作为一首歌的标识
  audio: RemoteFile | null = null;
  lyric: RemoteFile | null = null;
  size: number = 0;            // 显示用的大小（音频）
  stale: boolean = false;      // 音频或歌词任一在电脑上改过
  downloaded: boolean = false; // 音频已在本机（歌词缺失不算没下完）
  deleted: boolean = false;    // 曾在手机上下载、后来被删掉（不是没下过）
  // 文件名解析出来的展示/排序字段：YYYY-NNN - 歌手 - 歌名【影视】
  year: number = 0;
  artist: string = '';
  title: string = '';
  movie: boolean = false;      // 影视金曲
  movieName: string = '';      // 影视金曲的剧名（服务器给的，可能为空）
  artistPy: string = '';       // 歌手的拼音，用来按歌手排序
}

/// 排序方式（「已下载 / 未下载」已去掉：想看哪一类用「只看」筛选，不重复）
export const SORT_YEAR: number = 0;         // 年份（默认）
export const SORT_ARTIST: number = 1;       // 歌手
export const SORT_MOVIE: number = 2;        // 影视金曲优先
export const SORT_DELETED: number = 3;      // 手机上删过的优先

export const SORT_LABELS: string[] = ['年份', '歌手', '影视', '已删除'];

/// 只看某一类：全部 / 只看影视 / 只看未下载 / 只看已删除
export const FILTER_ALL: number = 0;
export const FILTER_MOVIE: number = 1;
export const FILTER_UNDOWNLOADED: number = 2;
export const FILTER_DELETED: number = 3;
export const FILTER_LABELS: string[] = ['全部', '只看影视', '只看未下载', '只看已删除'];

function baseOf(name: string): string {
  const i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

function isMp3(name: string): boolean {
  return name.toLowerCase().endsWith('.mp3');
}

function isLrc(name: string): boolean {
  return name.toLowerCase().endsWith('.lrc');
}

/// 拆 "1984-900 - 郑少秋 - 楚留香【影视】" -> 年份 / 歌手 / 歌名
function parseKey(s: SongEntry): void {
  const key = s.key;
  const a = key.indexOf(' - ');
  if (a < 0) {
    s.title = key;
    return;
  }
  const head = key.substring(0, a);
  if (head.length === 4) {
    const y = Number(head);
    s.year = Number.isNaN(y) ? 0 : y;
  }
  const rest = key.substring(a + 3);
  const b = rest.indexOf(' - ');
  if (b < 0) {
    s.title = rest;
    return;
  }
  s.artist = rest.substring(0, b);
  let t = rest.substring(b + 3);
  if (t.endsWith('【影视】')) {
    s.movie = true;
    t = t.substring(0, t.length - 4);
  }
  s.title = t;
  s.artistPy = pinyinFull(s.artist);
}

export function groupSongs(files: RemoteFile[], local: Set<string>,
                           stale: Set<string>, deleted: Set<string>): SongEntry[] {
  const map: Map<string, SongEntry> = new Map<string, SongEntry>();
  for (const f of files) {
    if (!isMp3(f.name) && !isLrc(f.name)) {
      continue;
    }
    const key = baseOf(f.name);
    let s = map.get(key);
    if (s === undefined) {
      s = new SongEntry();
      s.key = key;
      map.set(key, s);
    }
    if (isMp3(f.name)) {
      s.audio = f;
      s.size = f.size;
    } else {
      s.lyric = f;
    }
  }
  const out: SongEntry[] = [];
  map.forEach((s: SongEntry) => {
    const a = s.audio;
    if (a === null) {
      return;   // 只有歌词没有音频的行不显示
    }
    const l = s.lyric;
    s.movieName = a.movie === undefined ? '' : a.movie;
    s.stale = stale.has(a.name) || (l !== null && stale.has(l.name));
    s.downloaded = local.has(a.name) && (l === null || local.has(l.name));
    // 本机已经没有它了，但它曾在手机上下载过：显示成「已删除」而不是「未下载」
    s.deleted = !s.downloaded && (deleted.has(a.name) || (l !== null && deleted.has(l.name)));
    parseKey(s);
    // 文件名没写【影视】，但服务器剧名表认它是影视金曲的，也算影视
    if (s.movieName.length > 0) {
      s.movie = true;
    }
    out.push(s);
  });
  return out;
}

function cmpKey(x: SongEntry, y: SongEntry): number {
  return x.key < y.key ? -1 : (x.key > y.key ? 1 : 0);
}

/// 按选中的排序方式原地排序；同一方式内始终回落到文件名序（= 年份序），保证稳定
export function sortSongs(list: SongEntry[], mode: number): void {
  list.sort((x: SongEntry, y: SongEntry) => {
    if (mode === SORT_DELETED) {
      if (x.deleted !== y.deleted) {
        return x.deleted ? -1 : 1;
      }
    } else if (mode === SORT_YEAR) {
      if (x.year !== y.year) {
        return x.year - y.year;
      }
    } else if (mode === SORT_ARTIST) {
      if (x.artistPy !== y.artistPy) {
        return x.artistPy < y.artistPy ? -1 : 1;
      }
      if (x.artist !== y.artist) {
        return x.artist < y.artist ? -1 : 1;
      }
    } else if (mode === SORT_MOVIE) {
      if (x.movie !== y.movie) {
        return x.movie ? -1 : 1;
      }
    }
    return cmpKey(x, y);
  });
}
