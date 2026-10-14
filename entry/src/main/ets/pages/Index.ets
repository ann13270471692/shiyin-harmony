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
import { SongEntry, groupSongs, sortSongs, SORT_LABELS, SORT_YEAR,
  FILTER_LABELS, FILTER_MOVIE, FILTER_DELETED, FILTER_UNDOWNLOADED } from '../sync/SongGroup';
import { fuzzyFilter } from '../util/FuzzyMatch';

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
  @State lyricAdj: number = 0;
  @State servers: ServerEntry[] = [];
  @State remoteFiles: RemoteFile[] = [];
  // 导入页显示的是「一首歌」而不是一个个文件：mp3 与歌词合并成一行
  @State songs: SongEntry[] = [];
  // 排序方式：默认年份，可切到 歌手 / 影视 / 已删除（看哪一类用「只看」筛选）
  @State sortMode: number = SORT_YEAR;
  @State showServers: boolean = true;
  @State dlCount: number = 0;
  // 手机上删过的歌数量
  @State delCount: number = 0;
  // 只看某一类：0 全部 / 1 只看影视 / 2 只看已删除 / 3 只看未下载
  @State filterMode: number = 0;
  @State importQuery: string = '';
  @State selected: string[] = [];
  @State dlProgress: string = '';
  @State dlActive: boolean = false;
  @State manualHost: string = '';
  @State connectedServer: string = '';
  // 状态文字必须由 @State 驱动：ForEach 的 key 不变就不会重建行，
  // 行内直接读 downloader.staleNames（普通类字段）不会刷新
  @State staleArr: string[] = [];
  @State localArr: string[] = [];
  @State seekValue: number = 0;
  @State seekDragging: boolean = false;

  private engine: PlayerEngine = PlayerEngine.shared();
  private library: LibraryStore = LibraryStore.shared();
  private browser: SyncBrowser = SyncBrowser.shared();
  private downloader: SyncDownloader = new SyncDownloader();
  // 当前连着的服务器，「刷新」按钮直接重新读它的清单
  private connectedEntry: ServerEntry | null = null;
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
      this.syncFileStates();
    });
    // init 是异步的：偏好里的随机/循环要等它完成才读得到
    this.engine.init(ctx).then(() => {
      this.shuffleOn = this.engine.shuffle;
      this.repeatMode = this.engine.repeatMode;
    });
    this.library.refresh(ctx);
    this.browser.start(ctx);
    this.downloader.setMtimeFile(`${ctx.filesDir}/remote-mtimes.json`);
    this.downloader.setDeletedFile(`${ctx.filesDir}/deleted-songs.json`);
    this.downloader.loadMtimes();
    this.downloader.scanLocal(this.library.musicDir(ctx));
    this.syncFileStates();
    this.libTracks = this.library.tracks.slice();
    this.servers = this.browser.servers.slice();
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
    this.lyricAdj = this.engine.lyricAdjFor(t.path);
  }

  private bumpLyricAdj(deltaMs: number): void {
    if (this.curPath.length === 0) {
      return;
    }
    const v = this.lyricAdj + deltaMs;
    this.lyricAdj = v;
    this.engine.setLyricAdj(this.curPath, v);
    const idx = this.currentLyricIndex();
    if (idx >= 0) {
      this.lyricIdx = idx;
      this.scroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    }
    this.toast('歌词' + (v === 0 ? '已对齐' : (v > 0 ? '提前 ' : '延后 ') + Math.abs(v / 1000).toFixed(1) + ' 秒'));
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
  private nonVocal(s: string, early: boolean = false): boolean {
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
    // (间奏) (主歌) (副歌) (桥段) 这类段落标记也不是唱出来的
    if (/^[（(].*[）)]$/.test(t)) {
      return true;
    }
    // 开头几行的「歌名 – 歌手」是标题行
    if (early && /\s[–—-]\s/.test(t)) {
      return true;
    }
    return new RegExp('^\\S{1,8}\\s*[:：]\\s*\\S').test(t);
  }

  private currentLyricIndex(): number {
    // 墙钟插值 − 输出通路延迟（蓝牙耳机 180ms 量级）
    const t = this.engine.positionMs() - this.engine.outputLatencyMs + this.lyricAdj;
    let idx = -1;
    for (let i = 0; i < this.lyrics.length; i++) {
      if (this.lyrics[i].timeMs > t) {
        break;
      }
      // 空行与制作信息行不高亮：保持上一句，避免"歌词在跳但没人在唱"
      if (!this.nonVocal(this.lyrics[i].text, i < 3)) {
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

  private toast(m: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: m, duration: 1200 });
    } catch (e) {
      // 提示失败不影响操作本身
    }
  }

  // 删除只作用于手机上的下载副本：电脑端 SyncServer 的文件不动，
  // 之后在「导入」里它会标成「已删除」，想拉回来手动点下载即可
  private confirmDelete(t: Track): void {
    this.getUIContext().showAlertDialog({
      title: '从手机删除',
      message: `${t.title}\n${t.artist}\n\n只删除手机上已下载的副本，电脑上的文件不受影响。`,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF453A',
        action: () => {
          this.deleteTrack(t);
        }
      }
    });
  }

  private deleteTrack(t: Track): void {
    if (this.ctx === null) {
      return;
    }
    if (t.path === this.curPath) {
      this.engine.stop();
      this.curTitle = '';
      this.curArtist = '';
      this.curPath = '';
      this.lyrics = [];
      this.lyricIdx = -1;
    }
    const ok = this.library.remove(t);
    // 记下「这首歌在手机上被删过」：导入页标成「已删除」，不会被自动重下
    const nm = t.path.substring(t.path.lastIndexOf('/') + 1);
    if (nm.length > 0) {
      this.downloader.markDeleted(nm);
      const dot = nm.lastIndexOf('.');
      if (dot > 0) {
        const lrc = nm.substring(0, dot) + '.lrc';
        for (const f of this.remoteFiles) {
          if (f.name === lrc) {
            this.downloader.markDeleted(lrc);
            break;
          }
        }
      }
    }
    this.downloader.scanLocal(this.library.musicDir(this.ctx));
    this.syncFileStates();
    this.refreshSongs();
    this.libTracks = this.library.tracks.slice();
    this.toast(ok ? '已从手机删除，电脑上的文件保留' : '删除失败');
  }

  private toggleShuffle(): void {
    const on = !this.shuffleOn;
    this.engine.setShuffle(on);
    // @Builder 按值传参不刷新，这里直接同步 @State 让按钮立刻变色
    this.shuffleOn = on;
    this.toast(on ? '随机播放' : '顺序播放');
  }

  private repeatLabel(): string {
    if (this.repeatMode === RepeatMode.One) {
      return '单曲循环';
    }
    return this.repeatMode === RepeatMode.All ? '列表循环' : '不循环';
  }

  private cycleRepeatMode(): void {
    this.engine.cycleRepeat();
    this.repeatMode = this.engine.repeatMode;
    this.toast(this.repeatLabel());
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

  @Builder tabItem(label: string, icon: Resource, idx: number) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.tabIdx === idx ? ACCENT : SUB])
      Text(label)
        .fontSize(11)
        .fontColor(this.tabIdx === idx ? ACCENT : SUB)
        .fontWeight(this.tabIdx === idx ? FontWeight.Medium : FontWeight.Normal)
      Circle()
        .width(5)
        .height(5)
        .fill(this.tabIdx === idx ? ACCENT : Color.Transparent)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 9 })
    .onClick(() => {
      this.tabIdx = idx;
    })
  }

  @Builder bottomBar() {
    Column() {
      Divider().strokeWidth(0.5).color(LINE)
      Row() {
        this.tabItem('曲库', $r('sys.symbol.music_note_list'), 0)
        this.tabItem('播放', $r('sys.symbol.play_round_triangle_fill'), 1)
        this.tabItem('导入', $r('sys.symbol.download'), 2)
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor('#121218')
  }

  @Builder sectionTitle(t: string) {
    Text(t).fontSize(13).fontColor(SUB).fontFamily('HarmonyOS Sans')
  }

  // 图标按钮：无底色，只有符号 + 点击热区
  @Builder iconBtn(icon: Resource, size: number, color: string, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(size)
        .fontColor([color])
    }
    .width(46)
    .height(46)
    .borderRadius(23)
    .onClick(action)
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

  // 小号胶囊：用于歌词偏移这类次级操作
  @Builder chipButton(label: string, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(SUB)
      .backgroundColor('#15151B')
      .borderRadius(14)
      .border({ width: 1, color: LINE })
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .onClick(action)
  }

  @Builder libraryTab() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('梦秋音乐').fontSize(26).fontWeight(FontWeight.Bold).fontColor(TXT)
          Text(`${this.libTracks.length} 首 · 本地`).fontSize(12).fontColor(SUB)
          if (this.libTracks.length > 0) {
            Text('长按歌曲可删除（只删手机上的副本）').fontSize(11).fontColor(DIM)
          }
        }.alignItems(HorizontalAlign.Start)
        Blank()
        this.iconBtn($r('sys.symbol.arrow_clockwise'), 20, SUB, () => {
          if (this.ctx !== null) {
            this.library.refresh(this.ctx);
          }
        })
      }.padding({ left: 18, right: 14, top: 16, bottom: 10 }).width('100%')

      if (this.libTracks.length === 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(44)
            .fontColor([DIM])
          Text('曲库为空').fontSize(16).fontColor(TXT)
          Text('到「导入」标签从电脑拉取音乐').fontSize(13).fontColor(SUB)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        List({ space: 6 }) {
          ForEach(this.libTracks, (t: Track) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  SymbolGlyph($r('sys.symbol.music_fill'))
                    .fontSize(16)
                    .fontColor([ACCENT])
                }
                .width(42)
                .height(42)
                .borderRadius(11)
                .backgroundColor(t.path === this.curPath ? '#2E2314' : '#22222B')

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
                  SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                    .fontSize(13)
                    .fontColor([ACCENT])
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
            .gesture(
              LongPressGesture({ duration: 420 })
                .onAction(() => {
                  this.confirmDelete(t);
                })
            )
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
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.music_note_circle_fill'))
            .fontSize(46)
            .fontColor([DIM])
          Text('未在播放').fontSize(16).fontColor(TXT)
          Text('到「曲库」选一首开始').fontSize(13).fontColor(SUB)
        }.justifyContent(FlexAlign.Center).layoutWeight(1)
      } else {
        Row({ space: 16 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.music_fill'))
              .fontSize(30)
              .fontColor(['#FFFFFF'])
          }
          .width(84)
          .height(84)
          .borderRadius(18)
          .linearGradient({ angle: 135, colors: [['#6B4410', 0.0], ['#2A1E36', 1.0]] })

          Column({ space: 5 }) {
            Text(this.curTitle)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(TXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.curArtist)
              .fontSize(13)
              .fontColor(SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18 })

        Slider({ value: this.seekValue, min: 0, max: Math.max(this.curDurMs, 1000), step: 100 })
          .selectedColor(ACCENT)
          .trackColor('#2C2C36')
          .blockColor('#FFFFFF')
          .blockSize({ width: 12, height: 12 })
          .trackThickness(3)
          .width('100%')
          .margin({ top: 16 })
          .onChange((v: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.seekDragging = true;
              this.seekValue = v;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.engine.seekTo(v);
              this.seekDragging = false;
            }
          })

        Row() {
          Text(TimeFormat.ms(this.curPosMs)).fontSize(11).fontColor(DIM)
          Blank()
          Text(`-${TimeFormat.ms(Math.max(this.curDurMs - this.curPosMs, 0))}`).fontSize(11).fontColor(DIM)
        }
        .width('100%')
        .padding({ left: 22, right: 22 })
        .margin({ top: 4 })

        Row() {
          // 随机：图标与文字直接读 @State（走 iconBtn 按值传参不会刷新）
          Column({ space: 1 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.shuffle'))
                .fontSize(20)
                .fontColor([this.shuffleOn ? ACCENT : SUB])
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .onClick(() => {
              this.toggleShuffle();
            })
            Text(this.shuffleOn ? '随机' : '顺序')
              .fontSize(10)
              .fontColor(this.shuffleOn ? ACCENT : DIM)
          }
          this.iconBtn($r('sys.symbol.backward_end_fill'), 24, TXT, () => {
            this.engine.advance(-1);
          })
          Stack() {
            SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(26)
              .fontColor(['#111114'])
          }
          .width(66)
          .height(66)
          .borderRadius(33)
          .backgroundColor(ACCENT)
          .shadow({ radius: 18, color: '#4DFF9F0A', offsetY: 6 })
          .onClick(() => {
            this.engine.togglePlay();
          })
          this.iconBtn($r('sys.symbol.forward_end_fill'), 24, TXT, () => {
            this.engine.advance(1);
          })
          // 循环：不循环 → 列表循环 → 单曲循环，图标与文字直接读 @State
          Column({ space: 1 }) {
            Stack() {
              SymbolGlyph(this.repeatMode === RepeatMode.One
                ? $r('sys.symbol.repeat_1')
                : $r('sys.symbol.repeat'))
                .fontSize(20)
                .fontColor([this.repeatMode === RepeatMode.Off ? SUB : ACCENT])
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .onClick(() => {
              this.cycleRepeatMode();
            })
            Text(this.repeatMode === RepeatMode.One ? '单曲' : (this.repeatMode === RepeatMode.All ? '列表' : '不循环'))
              .fontSize(10)
              .fontColor(this.repeatMode === RepeatMode.Off ? DIM : ACCENT)
          }
        }
        .justifyContent(FlexAlign.SpaceEvenly)
        .width('100%')
        .margin({ top: 16 })

        if (Date.now() < this.manualUntil) {
          Row() {
            Blank()
            this.chipButton('回到当前', () => {
              this.manualUntil = 0;
              if (this.lyricIdx >= 0) {
                this.scroller.scrollToIndex(this.lyricIdx, true, ScrollAlign.CENTER);
              }
            })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12 })
        }

        if (this.lyrics.length > 0) {
          Row({ space: 12 }) {
            this.chipButton('歌词晚 0.5 秒', () => {
              this.bumpLyricAdj(-500);
            })
            Text(this.lyricAdj === 0 ? '歌词已对齐'
              : ((this.lyricAdj > 0 ? '提前 ' : '延后 ') + Math.abs(this.lyricAdj / 1000).toFixed(1) + ' 秒'))
              .fontSize(11)
              .fontColor(this.lyricAdj === 0 ? SUB : ACCENT)
            this.chipButton('歌词早 0.5 秒', () => {
              this.bumpLyricAdj(500);
            })
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .padding({ top: 10 })
        }

        if (this.lyrics.length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.music_slash_fill'))
              .fontSize(34)
              .fontColor([DIM])
            Text('暂无歌词').fontColor(SUB).fontSize(14)
          }.justifyContent(FlexAlign.Center).layoutWeight(1)
        } else {
          List({ scroller: this.scroller, space: 2 }) {
            ForEach(this.lyrics, (line: LyricLine, idx: number) => {
              ListItem() {
                Text(line.text)
                  .fontSize(idx === this.lyricIdx ? 20 : 15)
                  .fontColor(idx === this.lyricIdx ? '#FFFFFF' : (idx < this.lyricIdx ? DIM : '#8A8A94'))
                  .fontWeight(idx === this.lyricIdx ? FontWeight.Bold : FontWeight.Normal)
                  .lineHeight(idx === this.lyricIdx ? 30 : 22)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .padding({ top: 9, bottom: 9 })
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
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('局域网导入').fontSize(24).fontWeight(FontWeight.Bold).fontColor(TXT)
          Text(this.connectedServer.length > 0
            ? `已连接 ${this.connectedServer} · 共 ${this.songs.length} 首 · 本机已下载 ${this.dlCount} 首`
            : '电脑运行 SyncServer\\启动同步服务器.bat，手机与电脑同一 WiFi')
            .fontSize(13)
            .fontColor(this.connectedServer.length > 0 ? SUB : DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.connectedServer.length > 0) {
          this.pillButton('刷新', false, () => {
            this.refreshFromServer();
          })
          // 标签写死：@Builder 按值传参不随 @State 刷新
          this.pillButton('换电脑', false, () => {
            this.showServers = !this.showServers;
          })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 10 })

      if (this.connectedServer.length === 0 || this.showServers) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.wifi_router'))
            .fontSize(16)
            .fontColor([this.servers.length > 0 ? ACCENT : DIM])
          Text('发现的服务器').fontSize(13).fontColor(SUB)
        }.width('100%')
        if (this.servers.length === 0) {
          Text('未发现服务器，可在下方手动输入电脑 IP').fontSize(12).fontColor(DIM).width('100%')
        }
        ForEach(this.servers, (s: ServerEntry) => {
          Row({ space: 10 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.local'))
                .fontSize(16)
                .fontColor([SUB])
            }
            .width(36)
            .height(36)
            .borderRadius(10)
            .backgroundColor('#22222B')
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
      .padding(16)
      .backgroundColor(CARD)
      .borderRadius(16)
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
      }

      // 模糊查找：歌名/歌手/拼音首字母都能命中，列表实时过滤
      if (this.remoteFiles.length > 0) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(18)
            .fontColor([SUB])
          TextInput({ placeholder: '模糊查找：歌名 / 歌手 / 拼音（如 qt）', text: this.importQuery })
            .fontSize(15)
            .height(42)
            .backgroundColor(CARD)
            .borderRadius(10)
            .placeholderColor(DIM)
            .fontColor(TXT)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.importQuery = v;
            })
          if (this.importQuery.length > 0) {
            Text('清除')
              .fontSize(12)
              .fontColor(ACCENT)
              .padding(6)
              .onClick(() => {
                this.importQuery = '';
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

        // 一行搞定：先看（全部 / 只看影视 / 只看未下载 / 只看已删除）｜再排（年份 / 歌手 / 影视 / 已删除）
        Scroll() {
          Row({ space: 8 }) {
            ForEach(FILTER_LABELS, (label: string, idx: number) => {
              Text(label)
                .fontSize(14)
                .fontColor(this.filterMode === idx ? '#111114' : SUB)
                .backgroundColor(this.filterMode === idx ? '#4C9AFF' : '#15151B')
                .borderRadius(15)
                .border({ width: 1, color: this.filterMode === idx ? '#4C9AFF' : LINE })
                .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                .onClick(() => {
                  this.filterMode = idx;
                })
            }, (label: string, idx: number) => `${idx}-${this.filterMode}`)
            Divider()
              .vertical(true)
              .strokeWidth(1)
              .color(LINE)
              .height(18)
            ForEach(SORT_LABELS, (label: string, idx: number) => {
              Text(label)
                .fontSize(14)
                .fontColor(this.sortMode === idx ? '#111114' : SUB)
                .backgroundColor(this.sortMode === idx ? ACCENT : '#15151B')
                .borderRadius(15)
                .border({ width: 1, color: this.sortMode === idx ? ACCENT : LINE })
                .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                .onClick(() => {
                  this.setSortMode(idx);
                })
            }, (label: string, idx: number) => `${idx}-${this.sortMode}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

        Row({ space: 8 }) {
          Text(this.importQuery.length > 0
            ? `匹配 ${this.visibleSongs().length} / 共 ${this.songs.length} 首 · 已选 ${this.selected.length} 首`
            : `共 ${this.songs.length} 首 · 已下载 ${this.dlCount} 首 · 已删除 ${this.delCount} 首 · 已选 ${this.selected.length} 首`)
            .fontSize(13)
            .fontColor(SUB)
            .layoutWeight(1)
          this.pillButton('清空', false, () => {
            this.selected = [];
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })
      }

      if (this.remoteFiles.length > 0) {
        List({ space: 4 }) {
          ForEach(this.visibleSongs(), (s: SongEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                SymbolGlyph(this.selected.includes(s.key)
                  ? $r('sys.symbol.checkmark_square_fill')
                  : $r('sys.symbol.square'))
                  .fontSize(24)
                  .fontColor([this.selected.includes(s.key) ? ACCENT : DIM])
                  .onClick(() => {
                    this.toggleSelect(s.key, !this.selected.includes(s.key));
                  })
                // 主行歌名，副行歌手 · 年份（影视金曲带标记）
                Column({ space: 3 }) {
                  Text(s.title)
                    .fontSize(16)
                    .fontColor(TXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Row({ space: 6 }) {
                    Text(s.artist.length > 0 ? s.artist : '未知歌手')
                      .fontSize(13)
                      .fontColor(SUB)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (s.year > 0) {
                      Text(`${s.year}`).fontSize(13).fontColor(DIM)
                    }
                    if (s.movie) {
                      // 有剧名就显示剧名（服务器 movie-meta.json），没有就只显示「影视」
                      Text(s.movieName.length > 0 ? s.movieName : '影视')
                        .fontSize(11)
                        .fontColor('#FFD7A0')
                        .backgroundColor('#3A2E18')
                        .borderRadius(6)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: 170 })
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    }
                  }
                  .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick(() => {
                  this.toggleSelect(s.key, !this.selected.includes(s.key));
                })
                Column({ space: 3 }) {
                  Text(s.stale ? '需更新' : (s.downloaded ? '已下载' : (s.deleted ? '已删除' : '未下载')))
                    .fontSize(12)
                    .fontColor(s.stale ? '#FF9F0A' : (s.downloaded ? '#30D158' : (s.deleted ? '#FF9F0A' : DIM)))
                  Text(`${(s.size / 1048576).toFixed(1)}MB`)
                    .fontSize(12)
                    .fontColor(DIM)
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 10, bottom: 10 })
              .backgroundColor(CARD)
              .borderRadius(10)
            }
          }, (s: SongEntry) => `${s.key}|${s.stale ? 1 : 0}|${s.downloaded ? 1 : 0}|${s.deleted ? 1 : 0}|${s.size}`)
        }
        .padding({ left: 12, right: 12, top: 6 })
        .layoutWeight(1)
      } else {
        Blank()
      }

      // 底部固定操作条：拇指够得着，下载状态也在这里看
      if (this.remoteFiles.length > 0) {
        Row({ space: 10 }) {
          Text(this.dlActive
            ? (this.dlProgress.length > 0 ? this.dlProgress : '正在下载…')
            : (this.selected.length > 0
              ? `已选 ${this.selected.length} 首 · mp3 与歌词一起下载`
              : '点一行选一首 · 没歌词的自动跳过'))
            .fontSize(13)
            .fontColor(this.dlActive ? ACCENT : DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.dlActive ? '停止' : `下载 ${this.selected.length} 首`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111114')
            .backgroundColor(this.dlActive || this.selected.length > 0 ? ACCENT : '#3A3A44')
            .borderRadius(22)
            .padding({ left: 18, right: 18, top: 11, bottom: 11 })
            .onClick(() => {
              if (this.dlActive) {
                this.downloader.cancelRequested = true;
              } else {
                this.startDownload();
              }
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
        .backgroundColor('#14141A')
      }
    }.width('100%').height('100%')
  }

  // 按模糊查找过滤后的可见歌曲（匹配度高的排前面）
  private visibleSongs(): SongEntry[] {
    let base: SongEntry[] = this.songs;
    if (this.filterMode === FILTER_MOVIE) {
      base = this.songs.filter((s: SongEntry) => s.movie);
    } else if (this.filterMode === FILTER_DELETED) {
      base = this.songs.filter((s: SongEntry) => s.deleted);
    } else if (this.filterMode === FILTER_UNDOWNLOADED) {
      base = this.songs.filter((s: SongEntry) => !s.downloaded);
    }
    return fuzzyFilter(base, (s: SongEntry) => (s.movieName.length === 0 ? s.key : s.key + ' ' + s.movieName), this.importQuery);
  }

  // 文件列表 -> 歌曲列表（一行一首，歌词并入），状态取音频+歌词合并结果
  private refreshSongs(): void {
    this.songs = groupSongs(this.remoteFiles, this.downloader.localNames,
      this.downloader.staleNames, this.downloader.deletedNames);
    sortSongs(this.songs, this.sortMode);
    let n = 0;
    let d = 0;
    for (const s of this.songs) {
      if (s.downloaded) {
        n++;
      }
      if (s.deleted) {
        d++;
      }
    }
    this.dlCount = n;
    this.delCount = d;
  }

  // 换排序方式：排完重新赋值，@State 才会驱动列表重建
  private setSortMode(mode: number): void {
    this.sortMode = mode;
    sortSongs(this.songs, mode);
    this.songs = this.songs.slice();
  }

  private async refreshFromServer(): Promise<void> {
    if (this.connectedEntry !== null) {
      await this.connectServer(this.connectedEntry);
    }
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
      this.syncFileStates();
      this.refreshSongs();
      this.connectedServer = `${s.host}:${s.port}`;
      this.connectedEntry = s;
      this.showServers = false;   // 连上就把服务器卡片收起，把位置留给歌曲列表
      this.dlProgress = '';
      this.selected = [];   // 连上后一首一首自己点，不再一次选中几千首
    } catch (e) {
      this.dlProgress = '连接失败：检查 IP、防火墙与同步服务器窗口';
    }
  }

  private syncFileStates(): void {
    const s: string[] = [];
    this.downloader.staleNames.forEach((v: string) => {
      s.push(v);
    });
    this.staleArr = s;
    const l: string[] = [];
    this.downloader.localNames.forEach((v: string) => {
      l.push(v);
    });
    this.localArr = l;
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
    // 选中一首 = 音频 + 它的歌词；电脑上没歌词就只有音频，不另外提示
    const chosen: RemoteFile[] = [];
    for (const s of this.songs) {
      if (!this.selected.includes(s.key)) {
        continue;
      }
      if (s.audio !== null) {
        chosen.push(s.audio);
      }
      if (s.lyric !== null) {
        chosen.push(s.lyric);
      }
    }
    if (chosen.length === 0) {
      return;
    }
    const dir = this.library.musicDir(this.ctx);
    await this.downloader.downloadAll(chosen, dir);
    this.downloader.scanLocal(dir);
    this.downloader.markStale(this.remoteFiles, dir);
    this.syncFileStates();
    this.refreshSongs();
    this.dlActive = this.downloader.downloading;
    await this.library.refresh(this.ctx);
  }
}
