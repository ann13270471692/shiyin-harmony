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

const BG: string = '#0D0D11';
const CARD: string = '#191920';
const LINE: string = '#26262E';
const TXT: string = '#F2F2F5';
const SUB: string = '#9A9AA4';
const DIM: string = '#5C5C66';
const ACCENT: string = '#FF9F0A';

@Entry
@Component
struct Index {
  @State tabIdx: number = 0;
  @State libTracks: Track[] = [];
  @State curTitle: string = '';
  @State curArtist: string = '';
  @State curPath: string = '';
  @State curPosMs: number = 0;
  @State curDurMs: number = 0;
  @State isPlaying: boolean = false;
  @State shuffleOn: boolean = false;
  @State repeatMode: number = 0;
  @State lyrics: LyricLine[] = [];
  @State lyricIdx: number = -1;
  @State lyricOffset: number = 0;
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
  private lastLyricChange: number = 0;
  private timerId: number = -1;
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
    this.lyricOffset = this.engine.lyricOffsetMs;
    // 100ms 心跳：进度条与歌词按墙钟插值平滑走
    this.timerId = setInterval(() => {
      this.tick();
    }, 100);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private tick(): void {
    if (!this.engine.isPlaying) {
      return;
    }
    const pos = this.engine.positionMs();
    this.curPosMs = pos;
    if (!this.seekDragging) {
      this.seekValue = pos;
    }
    this.autoScrollLyrics();
  }

  private syncEngine(): void {
    const c = this.engine.current;
    this.curTitle = c !== null ? c.title : '';
    this.curArtist = c !== null ? c.artist : '';
    this.curPath = c !== null ? c.path : '';
    this.curPosMs = this.engine.positionMs();
    this.curDurMs = this.engine.durationMs;
    this.isPlaying = this.engine.isPlaying;
    this.shuffleOn = this.engine.shuffle;
    this.repeatMode = this.engine.repeatMode;
    this.lyricOffset = this.engine.lyricOffsetMs;
    if (!this.seekDragging) {
      this.seekValue = this.curPosMs;
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

  // 制作信息 / 版权水印 / 空行：不是唱出来的词，不参与高亮
  private nonVocal(s: string): boolean {
    const t = s.trim();
    if (t.length === 0) {
      return true;
    }
    const pat = new RegExp('作词|作曲|编曲|制作人|出品|发行|录音|混音|母带|和声|监制|统筹|总监|版权|厂牌|经纪|'
      + '宣传|文案|封面|设计|摄影|吉他|贝斯|鼓手|弦乐|提琴|铜管|钢琴|合成|Program|Engineer|Studio|Label|'
      + 'Recorded|Mixed|Master|Written|Arrang|未经许可|翻唱|禁止|ISRC|OPI|PBM|SPD|OP\\s*[:：]');
    if (pat.test(t)) {
      return true;
    }
    return new RegExp('^\\S{1,8}\\s*[:：]\\s*\\S').test(t);
  }

  private currentLyricIndex(): number {
    // 墙钟插值 + 用户偏移 − 输出通路延迟（蓝牙耳机 180ms 量级）
    const t = this.engine.positionMs() + this.engine.lyricOffsetMs - this.engine.outputLatencyMs;
    let idx = -1;
    for (let i = 0; i < this.lyrics.length; i++) {
      if (this.lyrics[i].timeMs > t) {
        break;
      }
      // 空行与制作信息行不高亮：保持上一句，避免"歌词在跳但没人在唱"
      if (!this.nonVocal(this.lyrics[i].text)) {
        idx = i;
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
        this.scroller.scrollToIndex(idx, !fast, ScrollAlign.CENTER);
      }
    }
  }

  build() {
    Column() {
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
      .barHeight(0)
      .scrollable(false)
      .onChange((i: number) => {
        this.tabIdx = i;
      })
      .layoutWeight(1)

      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  @Builder tabItem(label: string, glyph: string, idx: number) {
    Column({ space: 3 }) {
      Text(glyph)
        .fontSize(21)
        .fontColor(this.tabIdx === idx ? ACCENT : DIM)
      Text(label)
        .fontSize(12)
        .fontColor(this.tabIdx === idx ? ACCENT : SUB)
        .fontWeight(this.tabIdx === idx ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 10 })
    .onClick(() => {
      this.tabIdx = idx;
    })
  }

  @Builder bottomBar() {
    Column() {
      Divider().strokeWidth(0.5).color(LINE)
      Row() {
        this.tabItem('曲库', '♫', 0)
        this.tabItem('播放', '▷', 1)
        this.tabItem('导入', '⇩', 2)
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor('#121218')
  }

  @Builder sectionTitle(t: string) {
    Text(t).fontSize(13).fontColor(SUB).fontFamily('HarmonyOS Sans')
  }

  @Builder pillButton(label: string, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(primary ? '#111114' : TXT)
      .backgroundColor(primary ? ACCENT : CARD)
      .borderRadius(16)
      .border({ width: primary ? 0 : 1, color: LINE })
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .onClick(action)
  }

  @Builder libraryTab() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('梦秋音乐').fontSize(26).fontWeight(FontWeight.Bold).fontColor(TXT)
          Text(`${this.libTracks.length} 首 · 本地`).fontSize(12).fontColor(SUB)
        }.alignItems(HorizontalAlign.Start)
        Blank()
        this.pillButton('刷新', false, () => {
          if (this.ctx !== null) {
            this.library.refresh(this.ctx);
          }
        })
      }.padding({ left: 18, right: 18, top: 16, bottom: 12 }).width('100%')

      if (this.libTracks.length === 0) {
        Column({ space: 8 }) {
          Text('♫').fontSize(44).fontColor(DIM)
          Text('曲库为空').fontSize(16).fontColor(TXT)
          Text('到「导入」标签从电脑拉取音乐').fontSize(13).fontColor(SUB)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        List({ space: 6 }) {
          ForEach(this.libTracks, (t: Track, i: number) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  Text(i % 2 === 0 ? '♪' : '♫').fontSize(16).fontColor(ACCENT)
                }
                .width(40)
                .height(40)
                .borderRadius(10)
                .backgroundColor('#22222B')

                Column({ space: 3 }) {
                  Text(t.title)
                    .fontSize(16)
                    .fontColor(t.path === this.curPath ? ACCENT : TXT)
                    .fontWeight(t.path === this.curPath ? FontWeight.Medium : FontWeight.Normal)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(t.artist)
                    .fontSize(12)
                    .fontColor(SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (t.path === this.curPath) {
                  Text(this.isPlaying ? '▮▮' : '▶').fontSize(13).fontColor(ACCENT)
                }
                Text(TimeFormat.ms(t.durationMs)).fontSize(12).fontColor(DIM)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .backgroundColor(t.path === this.curPath ? '#1E1A14' : CARD)
              .borderRadius(12)
            }
            .onClick(() => {
              this.engine.playQueue(this.libTracks, t);
              this.tabIdx = 1;
            })
          }, (t: Track) => t.path)
        }
        .padding({ left: 12, right: 12 })
        .layoutWeight(1)
      }
    }.width('100%').height('100%')
  }

  @Builder nowPlayingTab() {
    Column() {
      if (this.curTitle === '') {
        Column({ space: 8 }) {
          Text('♪').fontSize(44).fontColor(DIM)
          Text('未在播放').fontSize(16).fontColor(TXT)
          Text('到「曲库」选一首开始').fontSize(13).fontColor(SUB)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        Row({ space: 14 }) {
          Stack() {
            Text('♪').fontSize(30).fontColor('#FFFFFF')
          }
          .width(72)
          .height(72)
          .borderRadius(14)
          .linearGradient({ angle: 135, colors: [['#5A3A10', 0.0], ['#241A2E', 1.0]] })

          Column({ space: 4 }) {
            Text(this.curTitle)
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(TXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.curArtist).fontSize(13).fontColor(SUB).maxLines(1).width('100%')
            Text(`${TimeFormat.ms(this.curPosMs)} / ${TimeFormat.ms(this.curDurMs)}`)
              .fontSize(11)
              .fontColor(DIM)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14 })

        Slider({ value: this.seekValue, min: 0, max: Math.max(this.curDurMs, 1000), step: 100 })
          .selectedColor(ACCENT)
          .trackColor(LINE)
          .blockColor(ACCENT)
          .blockSize({ width: 14, height: 14 })
          .trackThickness(4)
          .width('100%')
          .margin({ top: 10 })
          .onChange((v: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.seekDragging = true;
              this.seekValue = v;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.engine.seekTo(v);
              this.seekDragging = false;
            }
          })

        Row({ space: 26 }) {
          Text(this.shuffleOn ? '🔀' : '🔀')
            .fontSize(20)
            .fontColor(this.shuffleOn ? ACCENT : DIM)
            .onClick(() => {
              this.engine.setShuffle(!this.shuffleOn);
            })
          Text('⏮').fontSize(26).fontColor(TXT)
            .onClick(() => {
              this.engine.advance(-1);
            })
          Stack() {
            Text(this.isPlaying ? '❚❚' : '▷').fontSize(this.isPlaying ? 20 : 26).fontColor('#111114')
          }
          .width(62)
          .height(62)
          .borderRadius(31)
          .backgroundColor(ACCENT)
          .onClick(() => {
            this.engine.togglePlay();
          })
          Text('⏭').fontSize(26).fontColor(TXT)
            .onClick(() => {
              this.engine.advance(1);
            })
          Text(this.repeatMode === RepeatMode.Off ? '🔁' : (this.repeatMode === RepeatMode.All ? '🔁' : '🔂'))
            .fontSize(20)
            .fontColor(this.repeatMode === RepeatMode.Off ? DIM : ACCENT)
            .onClick(() => {
              this.engine.cycleRepeat();
            })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .margin({ top: 12 })

        if (this.lyrics.length > 0) {
          Row({ space: 10 }) {
            this.sectionTitle(`歌词偏移 ${this.lyricOffset >= 0 ? '+' : ''}${(this.lyricOffset / 1000).toFixed(1)}s`
              + (this.engine.outputLatencyMs > 0 ? `（自动 −${this.engine.outputLatencyMs}ms）` : ''))
            this.pillButton('−0.5s', false, () => {
              this.engine.nudgeLyricOffset(-500);
            })
            this.pillButton('+0.5s', false, () => {
              this.engine.nudgeLyricOffset(500);
            })
            Blank()
            if (Date.now() < this.manualUntil) {
              this.pillButton('回到当前', true, () => {
                this.manualUntil = 0;
                if (this.lyricIdx >= 0) {
                  this.scroller.scrollToIndex(this.lyricIdx, true, ScrollAlign.CENTER);
                }
              })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 })
        }

        if (this.lyrics.length === 0) {
          Column() {
            Text('暂无歌词').fontColor(SUB).fontSize(14)
          }.justifyContent(FlexAlign.Center).layoutWeight(1)
        } else {
          List({ scroller: this.scroller, space: 2 }) {
            ForEach(this.lyrics, (line: LyricLine, idx: number) => {
              ListItem() {
                Text(line.text)
                  .fontSize(idx === this.lyricIdx ? 19 : 15)
                  .fontColor(idx === this.lyricIdx ? '#FFFFFF' : (idx < this.lyricIdx ? DIM : SUB))
                  .fontWeight(idx === this.lyricIdx ? FontWeight.Bold : FontWeight.Normal)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .padding({ top: 7, bottom: 7 })
              }
              .onClick(() => {
                this.engine.seekTo(line.timeMs);
                this.manualUntil = 0;
              })
            }, (line: LyricLine, idx: number) => `${idx}-${line.timeMs}`)
          }
          .layoutWeight(1)
          .padding({ top: 40, bottom: 40 })
          .onScrollStart(() => {
            this.manualUntil = Date.now() + 4000;
          })
        }
      }
    }.width('100%').height('100%')
  }

  @Builder importTab() {
    Column() {
      Column({ space: 3 }) {
        Text('局域网导入').fontSize(26).fontWeight(FontWeight.Bold).fontColor(TXT)
        Text('电脑运行 SyncServer\\启动同步服务器.bat，手机与电脑同一 WiFi')
          .fontSize(12)
          .fontColor(SUB)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 12 })

      Column({ space: 8 }) {
        this.sectionTitle('发现的服务器')
        if (this.servers.length === 0) {
          Text('未发现服务器，可在下方手动输入电脑 IP').fontSize(12).fontColor(DIM)
        }
        ForEach(this.servers, (s: ServerEntry) => {
          Row() {
            Column({ space: 2 }) {
              Text(s.name).fontSize(15).fontColor(TXT)
              Text(`${s.host}:${s.port}`).fontSize(12).fontColor(SUB)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.pillButton('连接', true, () => {
              this.connectServer(s);
            })
          }.width('100%')
        }, (s: ServerEntry) => `${s.host}:${s.port}`)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(CARD)
      .borderRadius(14)
      .margin({ left: 12, right: 12 })

      Row({ space: 8 }) {
        TextInput({ placeholder: '手动输入电脑 IP（如 192.168.2.12）', text: this.manualHost })
          .fontSize(13)
          .backgroundColor('#14141A')
          .fontColor(TXT)
          .placeholderColor(DIM)
          .borderRadius(10)
          .height(40)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.manualHost = v;
          })
        this.pillButton('添加', false, () => {
          if (this.manualHost.length > 0) {
            this.browser.addManual(this.manualHost, 8450);
          }
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      if (this.connectedServer.length > 0) {
        Row({ space: 8 }) {
          Text(`已连接 ${this.connectedServer}`).fontSize(12).fontColor(SUB).layoutWeight(1)
          this.pillButton('全选未下载', false, () => {
            this.selectAllPending();
          })
          this.pillButton('清空', false, () => {
            this.selected = [];
          })
          this.pillButton(this.dlActive ? '停止' : '下载选中', true, () => {
            if (this.dlActive) {
              this.downloader.cancelRequested = true;
            } else {
              this.startDownload();
            }
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12 })

        Text(`已选 ${this.selected.length} / ${this.remoteFiles.length} 个文件`)
          .fontSize(12)
          .fontColor(DIM)
          .padding({ left: 14, top: 6 })

        List({ space: 4 }) {
          ForEach(this.remoteFiles, (f: RemoteFile) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(this.selected.includes(f.name) ? '☑' : '☐')
                  .fontSize(20)
                  .fontColor(this.selected.includes(f.name) ? ACCENT : DIM)
                  .onClick(() => {
                    this.toggleSelect(f.name, !this.selected.includes(f.name));
                  })
                Text(f.name)
                  .fontSize(13)
                  .fontColor(TXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.downloader.staleNames.has(f.name) ? '需更新'
                  : (this.downloader.localNames.has(f.name) ? '已下载' : `${(f.size / 1048576).toFixed(1)}MB`))
                  .fontSize(12)
                  .fontColor(this.downloader.staleNames.has(f.name) ? '#FF9F0A'
                    : (this.downloader.localNames.has(f.name) ? '#30D158' : SUB))
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(CARD)
              .borderRadius(10)
            }
          }, (f: RemoteFile) => f.name)
        }
        .padding({ left: 12, right: 12, top: 6 })
        .layoutWeight(1)
      } else {
        Blank()
      }

      if (this.dlProgress.length > 0) {
        Text(this.dlProgress)
          .fontSize(12)
          .fontColor(ACCENT)
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 10 })
      }
    }.width('100%').height('100%')
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
      this.downloader.markStale(this.remoteFiles, this.library.musicDir(this.ctx));
      this.connectedServer = `${s.host}:${s.port}`;
      this.dlProgress = '';
      this.selectAllPending();
    } catch (e) {
      this.dlProgress = '连接失败：检查 IP、防火墙与同步服务器窗口';
    }
  }

  private selectAllPending(): void {
    this.selected = this.remoteFiles
      .filter((f: RemoteFile) => !this.downloader.localNames.has(f.name)
        || this.downloader.staleNames.has(f.name))
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
