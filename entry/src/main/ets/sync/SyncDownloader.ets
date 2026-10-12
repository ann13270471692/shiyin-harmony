import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class RemoteFile {
  name: string = '';
  size: number = 0;
  mtime: number = 0;
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
  private listeners: Array<() => void> = [];

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
        let m = fs.statSync(`${dir}/${f.name}`).mtime;
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

  async fetchManifest(): Promise<RemoteFile[]> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/manifest.json`, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const m = JSON.parse(resp.result as string) as Manifest;
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
        if (this.localNames.has(f.name) && !stale) {
          continue;
        }
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
