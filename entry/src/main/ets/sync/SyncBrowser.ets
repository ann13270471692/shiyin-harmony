import { mdns } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class ServerEntry {
  name: string = '';
  host: string = '';
  port: number = 0;

  constructor(name: string, host: string, port: number) {
    this.name = name;
    this.host = host;
    this.port = port;
  }
}

export class SyncBrowser {
  private static inst: SyncBrowser | null = null;

  static shared(): SyncBrowser {
    if (SyncBrowser.inst === null) {
      SyncBrowser.inst = new SyncBrowser();
    }
    return SyncBrowser.inst;
  }

  servers: ServerEntry[] = [];
  private service: mdns.Service | null = null;
  private listeners: Array<() => void> = [];

  addListener(l: () => void): void {
    this.listeners.push(l);
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  start(): void {
    if (this.service !== null) {
      return;
    }
    try {
      const svc = mdns.createService('_shiyin', '_tcp');
      svc.on('serviceFound', (info: mdns.ServiceInfo) => {
        const host = info.hostAddr ?? '';
        if (host.length === 0) {
          return;
        }
        const name = info.instanceName ?? '同步服务器';
        const port = info.port ?? 8450;
        if (!this.servers.some((s: ServerEntry) => s.host === host && s.port === port)) {
          this.servers.push(new ServerEntry(name, host, port));
          this.notify();
        }
      });
      svc.on('serviceLost', (info: mdns.ServiceInfo) => {
        const host = info.hostAddr ?? '';
        const port = info.port ?? 8450;
        this.servers = this.servers.filter((s: ServerEntry) => !(s.host === host && s.port === port));
        this.notify();
      });
      svc.startSearchingServices();
      this.service = svc;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'Shiyin', 'mdns browse failed %{public}d', err.code);
    }
  }

  addManual(host: string, port: number): void {
    if (!this.servers.some((s: ServerEntry) => s.host === host && s.port === port)) {
      this.servers.push(new ServerEntry(`${host}`, host, port));
      this.notify();
    }
  }
}
