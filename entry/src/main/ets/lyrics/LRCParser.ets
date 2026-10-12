export class LyricLine {
  timeMs: number = 0;
  text: string = '';

  constructor(timeMs: number, text: string) {
    this.timeMs = timeMs;
    this.text = text;
  }
}

const TAG_RE = new RegExp('\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\]', 'g');

export class LRCParser {
  static parse(raw: string): LyricLine[] {
    const lines: LyricLine[] = [];
    for (const line of raw.split(/\r?\n/)) {
      TAG_RE.lastIndex = 0;
      const times: number[] = [];
      let m = TAG_RE.exec(line);
      while (m !== null) {
        const min = parseInt(m[1], 10);
        const sec = parseInt(m[2], 10);
        let frac = 0;
        if (m[3] !== undefined && m[3].length > 0) {
          frac = parseInt(m[3], 10) / Math.pow(10, m[3].length);
        }
        times.push((min * 60 + sec + frac) * 1000);
        m = TAG_RE.exec(line);
      }
      if (times.length === 0) {
        continue;
      }
      const text = line.replace(TAG_RE, '').trim();
      if (text.length === 0) {
        continue;
      }
      for (const t of times) {
        lines.push(new LyricLine(t, text));
      }
    }
    lines.sort((a: LyricLine, b: LyricLine) => a.timeMs - b.timeMs);
    return lines;
  }
}
