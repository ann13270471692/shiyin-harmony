// 模糊检索：直接包含 / 拼音首字母 / 跳字匹配
// 例：输入「晴天」「qt」「qing」「2019」都能命中「2019-012 - 周杰伦 - 晴天.mp3」
import { PY_CHARS, PY_BOUND, PY_FULL } from './PinyinTable';

let PY_MAP: Map<string, string> | null = null;
let PY_FULLMAP: Map<string, string> | null = null;

function buildFullMap(): Map<string, string> {
  const m = new Map<string, string>();
  const parts = PY_FULL.split(',');
  for (let i = 0; i < PY_CHARS.length && i < parts.length; i++) {
    m.set(PY_CHARS.charAt(i), parts[i]);
  }
  return m;
}

function fullOf(ch: string): string {
  if (PY_FULLMAP === null) {
    PY_FULLMAP = buildFullMap();
  }
  const v = PY_FULLMAP.get(ch);
  return v === undefined ? '' : v;
}

function buildMap(): Map<string, string> {
  const m = new Map<string, string>();
  const bounds: number[] = [];
  const letters: string[] = [];
  for (let i = 0; i < PY_BOUND.length; i++) {
    bounds.push(PY_CHARS.indexOf(PY_BOUND[i][0]));
    letters.push(PY_BOUND[i][1]);
  }
  let bi = 0;
  for (let i = 0; i < PY_CHARS.length; i++) {
    while (bi + 1 < bounds.length && bounds[bi + 1] <= i) {
      bi++;
    }
    m.set(PY_CHARS.charAt(i), letters[bi]);
  }
  return m;
}

function initialOf(ch: string): string {
  if (PY_MAP === null) {
    PY_MAP = buildMap();
  }
  const v = PY_MAP.get(ch);
  return v === undefined ? '' : v;
}

function isHan(c: string): boolean {
  return c >= '\u4e00' && c <= '\u9fff';
}

function isAlnum(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

// 只留字母数字与汉字，去掉空格、连字符、扩展名等噪声
export function compact(s: string): string {
  const low = s.toLowerCase();
  let r = '';
  for (let i = 0; i < low.length; i++) {
    const c = low.charAt(i);
    if (isHan(c) || isAlnum(c)) {
      r += c;
    }
  }
  return r;
}

// 汉字取拼音首字母，字母数字原样保留
export function initials(s: string): string {
  let r = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (isHan(c)) {
      r += initialOf(c).toLowerCase();
    } else if (isAlnum(c.toLowerCase())) {
      r += c.toLowerCase();
    }
  }
  return r;
}

// 汉字取完整拼音（无声调）连写，字母数字原样：晴天 → qingtian
export function pinyinFull(s: string): string {
  let r = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (isHan(c)) {
      r += fullOf(c);
    } else if (isAlnum(c.toLowerCase())) {
      r += c.toLowerCase();
    }
  }
  return r;
}

function subseq(needle: string, hay: string): boolean {
  let p = 0;
  for (let i = 0; i < hay.length && p < needle.length; i++) {
    if (hay.charAt(i) === needle.charAt(p)) {
      p++;
    }
  }
  return p === needle.length;
}

// 「 - 」分隔的最后一段视为歌名；歌名里命中的排在前面
function titlePart(name: string): string {
  const base = name.replace(/\.(mp3|lrc|jpg|png|txt)$/i, '');
  const i = base.lastIndexOf(' - ');
  return i > 0 ? base.substring(i + 3) : base;
}

// 3=原文包含 2=拼音（首字母或全拼）包含 1=跳字命中 0=不匹配
export function fuzzyScore(name: string, q: string): number {
  const needle = compact(q);
  if (needle.length === 0) {
    return 3;
  }
  const base = name.replace(/\.(mp3|lrc|jpg|png|txt)$/i, '');
  if (compact(base).indexOf(needle) >= 0) {
    return 3;
  }
  const ini = initials(base);
  const full = pinyinFull(base);
  if (ini.indexOf(needle) >= 0 || full.indexOf(needle) >= 0) {
    return 2;
  }
  // 跳字只按拼音判定：太短的查询走跳字会把无关长文件名捞进来
  if (needle.length >= 3 && (subseq(needle, ini) || subseq(needle, full))) {
    return 1;
  }
  return 0;
}

// 过滤 + 按匹配度排序（同分时歌名命中的优先，再按文件名）
export function fuzzyFilter<T>(items: T[], nameOf: (t: T) => string, q: string): T[] {
  if (compact(q).length === 0) {
    return items;
  }
  const keep: T[] = [];
  const score: number[] = [];
  const titleHit: number[] = [];
  for (let i = 0; i < items.length; i++) {
    const nm = nameOf(items[i]);
    const sc = fuzzyScore(nm, q);
    if (sc > 0) {
      keep.push(items[i]);
      score.push(sc);
      titleHit.push(fuzzyScore(titlePart(nm), q) > 0 ? 1 : 0);
    }
  }
  const order: number[] = [];
  for (let i = 0; i < keep.length; i++) {
    order.push(i);
  }
  order.sort((a: number, b: number) => {
    if (score[a] !== score[b]) {
      return score[b] - score[a];
    }
    if (titleHit[a] !== titleHit[b]) {
      return titleHit[b] - titleHit[a];
    }
    const na = nameOf(keep[a]);
    const nb = nameOf(keep[b]);
    return na < nb ? -1 : (na > nb ? 1 : 0);
  });
  const out: T[] = [];
  for (let i = 0; i < order.length; i++) {
    out.push(keep[order[i]]);
  }
  return out;
}
