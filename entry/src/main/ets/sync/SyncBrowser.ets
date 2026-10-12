import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
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
  private discovery: mdns.DiscoveryService | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private listeners: Array<() => void> = [];

  addListener(l: () => void): void {
    this.listeners.push(l);
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  start(context: common.UIAbilityContext): void {
    if (this.discovery !== null) {
      return;
    }
    this.ctx = context;
    try {
      const svc = mdns.createDiscoveryService(context, '_shiyin._tcp');
      svc.on('serviceFound', (info: mdns.LocalServiceInfo) => {
        const host = info.host !== undefined ? info.host.address : '';
        const port = info.port !== undefined ? info.port : 8450;
        const name = info.serviceName.length > 0 ? info.serviceName : '同步服务器';
        if (host.length > 0) {
          this.addServer(name, host, port);
        } else if (this.ctx !== null) {
          const req: mdns.LocalServiceInfo = {
            serviceType: info.serviceType,
            serviceName: info.serviceName,
            host: { address: '' }
          };
          mdns.resolveLocalService(this.ctx, req).then((r: mdns.LocalServiceInfo) => {
            const h = r.host !== undefined ? r.host.address : '';
            const p = r.port !== undefined ? r.port : 8450;
            if (h.length > 0) {
              this.addServer(info.serviceName, h, p);
            }
          }).catch((e: BusinessError) => {
            hilog.warn(0x0000, 'Shiyin', 'mdns resolve failed %{public}d', e.code);
          });
        }
      });
      svc.on('serviceLost', (info: mdns.LocalServiceInfo) => {
        const host = info.host !== undefined ? info.host.address : '';
        this.servers = this.servers.filter((s: ServerEntry) => !(s.host === host && s.name === info.serviceName));
        this.notify();
      });
      svc.startSearchingMDNS();
      this.discovery = svc;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'Shiyin', 'mdns discovery failed %{public}d', err.code);
    }
  }

  private addServer(name: string, host: string, port: number): void {
    if (!this.servers.some((s: ServerEntry) => s.host === host && s.port === port)) {
      this.servers.push(new ServerEntry(name, host, port));
      this.notify();
    }
  }

  addManual(host: string, port: number): void {
    if (!this.servers.some((s: ServerEntry) => s.host === host && s.port === port)) {
      this.servers.push(new ServerEntry(host, host, port));
      this.notify();
    }
  }
}
