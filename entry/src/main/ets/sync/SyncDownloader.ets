import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class RemoteFile {
  name: string = '';
  size: number = 0;
  mtime: number = 0;
  /// 影视金曲的剧名（服务器 movie-meta.json 提供，普通歌没有这个字段）
  movie?: string;
}

export class Manifest {
  files: RemoteFile[] = [];
}

const SEGMENT = 1048576; // 1MB 分段：绕开 http 模块 5MB 响应上限，且天然断点续传

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

export class SyncDownloader {
  host: string = '';
  port: number = 0;
  downloading: boolean = false;
  cancelRequested: boolean = false;
  progressText: string = '';
  localNames: Set<string> = new Set();
  staleNames: Set<string> = new Set();
  /// 每个文件上次下载时对应的电脑 mtime，用来判断"电脑上改过没有"
  knownMtimes: Map<string, number> = new Map();
  /// 在手机上被删过的歌（含它的歌词）：导入页标成「已删除」，不会被自动重下；
  /// 手动重新下载成功后标记自动清掉。
  deletedNames: Set<string> = new Set();
  private mtimeFile: string = '';
  private deletedFile: string = '';
  private listeners: Array<() => void> = [];

  setMtimeFile(path: string): void {
    this.mtimeFile = path;
  }

  setDeletedFile(path: string): void {
    this.deletedFile = path;
    this.deletedNames = new Set<string>();
    if (this.deletedFile.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(this.deletedFile)) {
        return;
      }
      const arr = JSON.parse(fs.readTextSync(this.deletedFile)) as string[];
      for (const n of arr) {
        this.deletedNames.add(n);
      }
    } catch (e) {
      this.deletedNames = new Set<string>();
    }
  }

  private saveDeleted(): void {
    if (this.deletedFile.length === 0) {
      return;
    }
    try {
      const arr: string[] = [];
      this.deletedNames.forEach((n: string) => {
        arr.push(n);
      });
      const fh = fs.openSync(this.deletedFile,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fh.fd, JSON.stringify(arr));
      } finally {
        fs.closeSync(fh);
      }
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'save deleted list failed');
    }
  }

  markDeleted(name: string): void {
    if (name.length === 0 || this.deletedNames.has(name)) {
      return;
    }
    this.deletedNames.add(name);
    this.saveDeleted();
  }

  clearDeleted(name: string): void {
    if (this.deletedNames.delete(name)) {
      this.saveDeleted();
    }
  }

  loadMtimes(): void {
    this.knownMtimes = new Map<string, number>();
    if (this.mtimeFile.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(this.mtimeFile)) {
        return;
      }
      const obj = JSON.parse(fs.readTextSync(this.mtimeFile)) as Record<string, number>;
      for (const k of Object.keys(obj)) {
        this.knownMtimes.set(k, obj[k]);
      }
    } catch (e) {
      this.knownMtimes = new Map<string, number>();
    }
  }

  private saveMtimes(): void {
    if (this.mtimeFile.length === 0) {
      return;
    }
    try {
      const obj: Record<string, number> = {};
      this.knownMtimes.forEach((v: number, k: string) => {
        obj[k] = v;
      });
      const fh = fs.openSync(this.mtimeFile,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fh.fd, JSON.stringify(obj));
      } finally {
        fs.closeSync(fh);
      }
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'save mtimes failed');
    }
  }

  addListener(l: () => void): void {
    this.listeners.push(l);
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  cancel(): void {
    this.cancelRequested = true;
  }

  scanLocal(dir: string): void {
    this.localNames = new Set<string>();
    try {
      for (const n of fs.listFileSync(dir)) {
        this.localNames.add(n);
      }
    } catch (e) {
      // dir missing
    }
  }

  markStale(files: RemoteFile[], dir: string): void {
    this.staleNames = new Set<string>();
    for (const f of files) {
      if (!this.localNames.has(f.name)) {
        continue;
      }
      try {
        const st = fs.statSync(`${dir}/${f.name}`);
        // 大小不同：一定是旧文件
        if (st.size !== f.size) {
          this.staleNames.add(f.name);
          continue;
        }
        // 记住过这台电脑上的 mtime：直接比它，这才是"电脑上改过没有"
        const known = this.knownMtimes.get(f.name);
        if (known !== undefined) {
          if (known !== f.mtime) {
            this.staleNames.add(f.name);
          }
          continue;
        }
        // 从没记过：本地 mtime 是下载时间，跟电脑上的原始 mtime 必然不同，
        // 只能先粗判一次（会全部标记一轮），重新下载后就按记下的 mtime 精确判断
        let m = st.mtime;
        if (m > 1e12) {
          m = Math.floor(m / 1000);   // 某些接口返回毫秒
        }
        if (Math.abs(m - f.mtime) > 2) {
          this.staleNames.add(f.name);
        }
      } catch (e) {
        this.staleNames.add(f.name);
      }
    }
  }

  private lastEtag: string = '';
  private lastFiles: RemoteFile[] = [];

  async fetchManifest(): Promise<RemoteFile[]> {
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      };
      if (this.lastEtag.length > 0) {
        const h: Record<string, string> = { 'If-None-Match': this.lastEtag };
        opts.header = h;
      }
      const resp = await req.request(`${this.baseUrl()}/manifest.json`, opts);
      if (resp.responseCode === 304 && this.lastFiles.length > 0) {
        // 列表没变：不再传 2MB、不再解析 2 万条
        return this.lastFiles;
      }
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const hd = resp.header as Record<string, string>;
      if (hd !== null && hd !== undefined && hd['etag'] !== undefined) {
        this.lastEtag = hd['etag'];
      }
      const m = JSON.parse(resp.result as string) as Manifest;
      this.lastFiles = m.files;
      return m.files;
    } finally {
      req.destroy();
    }
  }

  private baseUrl(): string {
    return `http://${this.host}:${this.port}`;
  }

  async downloadAll(files: RemoteFile[], dir: string): Promise<void> {
    if (this.downloading) {
      return;
    }
    this.downloading = true;
    this.cancelRequested = false;
    let done = 0;
    let failed = 0;
    try {
      for (const f of files) {
        if (this.cancelRequested) {
          this.progressText = '已停止';
          break;
        }
        const stale = this.staleNames.has(f.name);
        if (stale) {
          // 电脑上文件已更新：丢弃旧断点，整份重下
          try {
            if (fs.accessSync(`${dir}/${f.name}.part`)) {
              fs.unlinkSync(`${dir}/${f.name}.part`);
            }
          } catch (e) {
            // ignore
          }
        }
        this.progressText = `下载 ${f.name}（剩余约 ${files.length - done - failed} 个）`;
        this.notify();
        try {
          await this.downloadOne(f, dir);
          this.localNames.add(f.name);
          this.knownMtimes.set(f.name, f.mtime);
          this.saveMtimes();
          this.clearDeleted(f.name);   // 重新下回来了，「已删除」标记自动消掉
          done++;
        } catch (e) {
          failed++;
          hilog.error(0x0000, 'Shiyin', 'download %{public}s failed', f.name);
          this.progressText = `失败 ${f.name}（已保留进度，可重下续传）`;
          this.notify();
        }
      }
      this.progressText = failed === 0
        ? `完成，共 ${done} 个文件`
        : `结束：成功 ${done}，失败 ${failed}（失败的再点一次即可续传）`;
    } finally {
      this.downloading = false;
      this.notify();
    }
  }

  private async fetchSegment(name: string, start: number, end: number): Promise<http.HttpResponse> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = { 'Range': `bytes=${start}-${end}` };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 30000
      };
      const url = `${this.baseUrl()}/file/${encodeURIComponent(name).replace(/%2F/g, '/')}`;
      return await req.request(url, options);
    } finally {
      req.destroy();
    }
  }

  private async downloadOne(f: RemoteFile, dir: string): Promise<void> {
    const finalPath = `${dir}/${f.name}`;
    const partPath = `${finalPath}.part`;
    let have = 0;
    try {
      if (fs.accessSync(partPath)) {
        have = fs.statSync(partPath).size;
      }
    } catch (e) {
      have = 0;
    }
    if (have > f.size) {
      have = 0;
      try {
        fs.unlinkSync(partPath);
      } catch (e) {
        // ignore
      }
    }
    const file = fs.openSync(partPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    try {
      while (have < f.size) {
        if (this.cancelRequested) {
          throw new Error('cancelled');
        }
        const end = Math.min(have + SEGMENT - 1, f.size - 1);
        let body: ArrayBuffer | null = null;
        let serverFull = false;
        for (let attempt = 1; attempt <= 3 && body === null; attempt++) {
          try {
            const resp = await this.fetchSegment(f.name, have, end);
            if (resp.responseCode === 206) {
              body = resp.result as ArrayBuffer;
            } else if (resp.responseCode === 200) {
              // 服务器忽略 Range：整文件返回，从头覆盖
              body = resp.result as ArrayBuffer;
              serverFull = true;
            } else if (resp.responseCode === 416) {
              body = new ArrayBuffer(0);
            } else {
              throw new Error(`HTTP ${resp.responseCode}`);
            }
          } catch (e) {
            if (attempt < 3) {
              await delay(400 * attempt);
            }
          }
        }
        if (body === null) {
          throw new Error(`segment ${have} failed`);
        }
        if (serverFull) {
          fs.truncateSync(file.fd, 0);
          have = 0;
        }
        fs.writeSync(file.fd, body);
        have += body.byteLength;
        if (body.byteLength === 0) {
          break;
        }
        this.progressText = `${f.name} ${(have / 1048576).toFixed(1)}/${(f.size / 1048576).toFixed(1)}MB`;
        this.notify();
      }
    } finally {
      fs.closeSync(file);
    }
    if (have < f.size) {
      throw new Error(`incomplete ${have}/${f.size}`);
    }
    if (fs.accessSync(finalPath)) {
      fs.unlinkSync(finalPath);
    }
    fs.renameSync(partPath, finalPath);
  }
}
