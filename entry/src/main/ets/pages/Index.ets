import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { PlayerEngine, RepeatMode } from '../playback/PlayerEngine';
import { LibraryStore } from '../library/LibraryStore';
import { EmbeddedLyrics } from '../library/ID3Parser';
import { LRCParser, LyricLine } from '../lyrics/LRCParser';
import { Track, TimeFormat } from '../model/Track';
import { SyncBrowser, ServerEntry } from '../sync/SyncBrowser';
import { SyncDownloader, RemoteFile } from '../sync/SyncDownloader';

@Entry
@Component
struct Index {
  @State tabIdx: number = 0;
  @State libTracks: Track[] = [];
  @State curTitle: string = '';
  @State curArtist: string = '';
  @State curPosMs: number = 0;
  @State curDurMs: number = 0;
  @State isPlaying: boolean = false;
  @State shuffleOn: boolean = false;
  @State repeatMode: number = 0;
  @State lyrics: LyricLine[] = [];
  @State lyricIdx: number = -1;
  private lastLyricChange: number = 0;
  @State servers: ServerEntry[] = [];
  @State remoteFiles: RemoteFile[] = [];
  @State selected: string[] = [];
  @State dlProgress: string = '';
  @State dlActive: boolean = false;
  @State manualHost: string = '';
  @State connectedServer: string = '';
  @State seekValue: number = 0;
  @State seekDragging: boolean = false;

  private engine: PlayerEngine = PlayerEngine.shared();
  private library: LibraryStore = LibraryStore.shared();
  private browser: SyncBrowser = SyncBrowser.shared();
  private downloader: SyncDownloader = new SyncDownloader();
  private scroller: Scroller = new Scroller();
  private lastTrackPath: string = '';
  private manualUntil: number = 0;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctx = ctx;
    this.engine.addListener(() => {
      this.syncEngine();
    });
    this.library.addListener(() => {
      this.libTracks = this.library.tracks.slice();
    });
    this.browser.addListener(() => {
      this.servers = this.browser.servers.slice();
    });
    this.downloader.addListener(() => {
      this.dlProgress = this.downloader.progressText;
      this.dlActive = this.downloader.downloading;
    });
    this.engine.init(ctx);
    this.library.refresh(ctx);
    this.browser.start(ctx);
    this.downloader.scanLocal(this.library.musicDir(ctx));
    this.libTracks = this.library.tracks.slice();
    this.servers = this.browser.servers.slice();
  }

  private syncEngine(): void {
    const c = this.engine.current;
    this.curTitle = c !== null ? c.title : '';
    this.curArtist = c !== null ? c.artist : '';
    this.curPosMs = this.engine.currentTimeMs;
    this.curDurMs = this.engine.durationMs;
    this.isPlaying = this.engine.isPlaying;
    this.shuffleOn = this.engine.shuffle;
    this.repeatMode = this.engine.repeatMode;
    if (!this.seekDragging) {
      this.seekValue = this.engine.currentTimeMs;
    }
    if (c !== null && c.path !== this.lastTrackPath) {
      this.lastTrackPath = c.path;
      this.loadLyrics(c);
    }
    this.autoScrollLyrics();
  }

  private loadLyrics(t: Track): void {
    let raw: string | null = null;
    if (t.hasLyrics) {
      raw = this.readTextFile(t.path.substring(0, t.path.length - 4) + '.lrc');
    }
    if (raw === null) {
      raw = EmbeddedLyrics.read(t.path);
    }
    this.lyrics = raw !== null ? LRCParser.parse(raw) : [];
    this.lyricIdx = -1;
  }

  private readTextFile(path: string): string | null {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf, { length: stat.size });
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      return null;
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  private currentLyricIndex(): number {
    const t = this.curPosMs;
    let idx = -1;
    for (let i = 0; i < this.lyrics.length; i++) {
      if (this.lyrics[i].timeMs <= t + 300) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  private autoScrollLyrics(): void {
    if (this.lyrics.length === 0) {
      return;
    }
    const idx = this.currentLyricIndex();
    if (idx !== this.lyricIdx) {
      const now = Date.now();
      const fast = now - this.lastLyricChange < 800;
      this.lastLyricChange = now;
      this.lyricIdx = idx;
      if (idx >= 0 && now >= this.manualUntil) {
        // 快嘴段落行距 <0.8s：关闭平滑动画，避免整页连滚
        this.scroller.scrollToIndex(idx, !fast, ScrollAlign.CENTER);
      }
    }
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.tabIdx }) {
      TabContent() {
        this.libraryTab()
      }.tabBar('曲库')

      TabContent() {
        this.nowPlayingTab()
      }.tabBar('播放')

      TabContent() {
        this.importTab()
      }.tabBar('导入')
    }
    .barMode(BarMode.Fixed)
    .onChange((i: number) => {
      this.tabIdx = i;
    })
    .backgroundColor('#101014')
  }

  @Builder libraryTab() {
    Column() {
      Row() {
        Text('梦秋音乐').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#F5F5F7')
        Blank()
        Button('刷新').fontSize(14).onClick(() => {
          if (this.ctx !== null) {
            this.library.refresh(this.ctx);
          }
        })
      }.padding(12).width('100%')

      if (this.libTracks.length === 0) {
        Column() {
          Text('曲库为空\n到「导入」标签从电脑拉取音乐').fontColor('#8E8E93').fontSize(15).textAlign(TextAlign.Center)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        List() {
          ForEach(this.libTracks, (t: Track) => {
            ListItem() {
              Column() {
                Text(t.title).fontSize(16).fontColor('#F5F5F7').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${t.artist} · ${TimeFormat.ms(t.durationMs)}`).fontSize(13).fontColor('#8E8E93').margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
            }
            .onClick(() => {
              this.engine.playQueue(this.libTracks, t);
              this.tabIdx = 1;
            })
          }, (t: Track) => t.path)
        }
        .divider({ strokeWidth: 0.5, color: '#2C2C2E' })
        .layoutWeight(1)
      }
    }.width('100%').height('100%')
  }

  @Builder nowPlayingTab() {
    Column() {
      Text(this.curTitle === '' ? '未在播放' : this.curTitle)
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F5F5F7').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.curArtist).fontSize(14).fontColor('#8E8E93').margin({ top: 4, bottom: 12 })

      Row() {
        Text(TimeFormat.ms(this.curPosMs)).fontSize(12).fontColor('#8E8E93')
        Slider({ value: this.seekValue, min: 0, max: Math.max(this.curDurMs, 1000), step: 1000 })
          .layoutWeight(1)
          .onChange((v: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.seekDragging = true;
              this.seekValue = v;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.engine.seekTo(v);
              this.seekDragging = false;
            }
          })
        Text(TimeFormat.ms(this.curDurMs)).fontSize(12).fontColor('#8E8E93')
      }.width('100%')

      Row() {
        Text(this.shuffleOn ? '🔀' : '🔀̶').fontSize(22).fontColor(this.shuffleOn ? '#FF9F0A' : '#6B6B70')
          .onClick(() => {
            this.engine.setShuffle(!this.shuffleOn);
          })
        Text('⏮').fontSize(26).fontColor('#F5F5F7').margin({ left: 20 })
          .onClick(() => {
            this.engine.advance(-1);
          })
        Text(this.isPlaying ? '⏸' : '▶').fontSize(40).fontColor('#F5F5F7').margin({ left: 24, right: 24 })
          .onClick(() => {
            this.engine.togglePlay();
          })
        Text('⏭').fontSize(26).fontColor('#F5F5F7')
          .onClick(() => {
            this.engine.advance(1);
          })
        Text(this.repeatMode === RepeatMode.Off ? '🔁̶' : (this.repeatMode === RepeatMode.All ? '🔁' : '🔂'))
          .fontSize(22)
          .fontColor(this.repeatMode === RepeatMode.Off ? '#6B6B70' : '#FF9F0A')
          .margin({ left: 20 })
          .onClick(() => {
            this.engine.cycleRepeat();
          })
      }.justifyContent(FlexAlign.Center).width('100%').margin({ top: 8, bottom: 12 })

      if (this.lyrics.length === 0) {
        Column() {
          Text(this.curTitle === '' ? '选择歌曲开始播放' : '暂无歌词').fontColor('#8E8E93').fontSize(15)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.lyrics, (line: LyricLine, idx: number) => {
            ListItem() {
              Text(line.text)
                .fontSize(idx === this.lyricIdx ? 19 : 15)
                .fontColor(idx === this.lyricIdx ? '#FFFFFF' : '#6B6B70')
                .fontWeight(idx === this.lyricIdx ? FontWeight.Bold : FontWeight.Normal)
                .textAlign(TextAlign.Center)
                .width('100%')
                .padding({ top: 6, bottom: 6 })
            }
            .onClick(() => {
              this.engine.seekTo(line.timeMs);
            })
          }, (line: LyricLine, idx: number) => `${idx}-${line.timeMs}`)
        }
        .layoutWeight(1)
        .onScrollStart(() => {
          this.manualUntil = Date.now() + 4000;
        })
      }
    }.padding(16).width('100%').height('100%')
  }

  @Builder importTab() {
    Column() {
      Text('局域网导入').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F5F5F7')
      Text('在电脑上运行 SyncServer\\启动同步服务器.bat，手机与电脑同一 WiFi').fontSize(12).fontColor('#8E8E93').margin({ top: 4 })

      Text('发现的服务器').fontSize(14).fontColor('#8E8E93').margin({ top: 14 })
      ForEach(this.servers, (s: ServerEntry) => {
        Row() {
          Column() {
            Text(s.name).fontSize(15).fontColor('#F5F5F7')
            Text(`${s.host}:${s.port}`).fontSize(12).fontColor('#8E8E93')
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Button('连接').fontSize(13).onClick(() => {
            this.connectServer(s);
          })
        }.width('100%').padding(10)
      }, (s: ServerEntry) => `${s.host}:${s.port}`)

      Row() {
        TextInput({ placeholder: '手动输入电脑 IP（如 192.168.1.9）', text: this.manualHost })
          .fontSize(13)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.manualHost = v;
          })
        Button('添加').fontSize(13).margin({ left: 8 }).onClick(() => {
          if (this.manualHost.length > 0) {
            this.browser.addManual(this.manualHost, 8450);
          }
        })
      }.margin({ top: 8 }).width('100%')

      if (this.connectedServer.length > 0) {
        Row() {
          Text(`已连接 ${this.connectedServer}`).fontSize(13).fontColor('#8E8E93')
          Blank()
          Button('全选未下载').fontSize(12).onClick(() => {
            this.selectAllPending();
          })
          Button('清空').fontSize(12).margin({ left: 6 }).onClick(() => {
            this.selected = [];
          })
          Button(this.dlActive ? '停止' : '下载选中').fontSize(12).margin({ left: 6 }).onClick(() => {
            if (this.dlActive) {
              this.downloader.cancelRequested = true;
            } else {
              this.startDownload();
            }
          })
        }.width('100%').margin({ top: 12 })

        List() {
          ForEach(this.remoteFiles, (f: RemoteFile) => {
            ListItem() {
              Row() {
                Text(this.selected.includes(f.name) ? '☑' : '☐')
                  .fontSize(22)
                  .fontColor(this.selected.includes(f.name) ? '#FF9F0A' : '#8E8E93')
                  .onClick(() => {
                    this.toggleSelect(f.name, !this.selected.includes(f.name));
                  })
                Text(f.name).fontSize(13).fontColor('#F5F5F7').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ left: 6 })
                Text(this.downloader.localNames.has(f.name) ? '已下载' : `${(f.size / 1048576).toFixed(1)}MB`)
                  .fontSize(12)
                  .fontColor(this.downloader.localNames.has(f.name) ? '#30D158' : '#8E8E93')
              }.width('100%').padding(6)
            }
          }, (f: RemoteFile) => f.name)
        }
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: '#2C2C2E' })
      } else {
        Blank()
      }

      if (this.dlProgress.length > 0) {
        Text(this.dlProgress).fontSize(13).fontColor('#FF9F0A').margin({ top: 8 }).width('100%')
      }
    }.padding(16).width('100%').height('100%')
  }

  private async connectServer(s: ServerEntry): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    this.downloader.host = s.host;
    this.downloader.port = s.port;
    this.downloader.scanLocal(this.library.musicDir(this.ctx));
    try {
      this.remoteFiles = await this.downloader.fetchManifest();
      this.connectedServer = `${s.host}:${s.port}`;
      this.dlProgress = '';
      this.selectAllPending();
    } catch (e) {
      this.dlProgress = '连接失败：检查 IP、防火墙与同步服务器窗口';
    }
  }

  private selectAllPending(): void {
    this.selected = this.remoteFiles
      .filter((f: RemoteFile) => !this.downloader.localNames.has(f.name))
      .map((f: RemoteFile) => f.name);
  }

  private toggleSelect(name: string, on: boolean): void {
    if (on) {
      if (!this.selected.includes(name)) {
        this.selected = this.selected.concat([name]);
      }
    } else {
      this.selected = this.selected.filter((n: string) => n !== name);
    }
  }

  private async startDownload(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    const chosen = this.remoteFiles.filter((f: RemoteFile) => this.selected.includes(f.name));
    if (chosen.length === 0) {
      return;
    }
    await this.downloader.downloadAll(chosen, this.library.musicDir(this.ctx));
    await this.library.refresh(this.ctx);
  }
}
