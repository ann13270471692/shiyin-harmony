import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class RemoteFile {
  name: string = '';
  size: number = 0;
}

export class Manifest {
  files: RemoteFile[] = [];
}

export class SyncDownloader {
  host: string = '';
  port: number = 0;
  downloading: boolean = false;
  progressText: string = '';
  localNames: Set<string> = new Set();
  private listeners: Array<() => void> = [];

  addListener(l: () => void): void {
    this.listeners.push(l);
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  private baseUrl(): string {
    return `http://${this.host}:${this.port}`;
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

  async downloadAll(files: RemoteFile[], dir: string): Promise<void> {
    if (this.downloading) {
      return;
    }
    this.downloading = true;
    let done = 0;
    let failed = 0;
    try {
      for (const f of files) {
        if (this.localNames.has(f.name)) {
          continue;
        }
        done++;
        this.progressText = `下载 ${f.name}（${done}/${files.length}）`;
        this.notify();
        try {
          await this.downloadOne(f.name, dir);
          this.localNames.add(f.name);
        } catch (e) {
          failed++;
          const err = e as BusinessError;
          hilog.error(0x0000, 'Shiyin', 'download %{public}s failed', f.name);
          this.progressText = `失败 ${f.name}，继续其余（累计失败 ${failed}）`;
          this.notify();
        }
      }
      this.progressText = failed === 0 ? `完成，共 ${done} 个文件` : `结束：成功 ${done - failed}，失败 ${failed}`;
    } finally {
      this.downloading = false;
      this.notify();
    }
  }

  private async downloadOne(name: string, dir: string): Promise<void> {
    const finalPath = `${dir}/${name}`;
    const partPath = `${finalPath}.part`;
    let have = 0;
    try {
      if (fs.accessSync(partPath)) {
        have = fs.statSync(partPath).size;
      }
    } catch (e) {
      have = 0;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 8000,
      readTimeout: 120000
    };
    if (have > 0) {
      const headers: Record<string, string> = { 'Range': `bytes=${have}-` };
      options.header = headers;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/${encodeURIComponent(name).replace(/%2F/g, '/')}`, options);
      if (resp.responseCode !== 200 && resp.responseCode !== 206) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const body = resp.result as ArrayBuffer;
      let file: fs.File | null = null;
      try {
        file = fs.openSync(partPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
        if (resp.responseCode === 200) {
          // 服务器忽略了 Range：从头覆盖
          fs.truncateSync(file.fd, 0);
        }
        fs.writeSync(file.fd, body);
      } finally {
        if (file !== null) {
          fs.closeSync(file);
        }
      }
      if (fs.accessSync(finalPath)) {
        fs.unlinkSync(finalPath);
      }
      fs.renameSync(partPath, finalPath);
    } finally {
      req.destroy();
    }
  }
}
