import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Track } from '../model/Track';

export enum RepeatMode {
  Off = 0, All = 1, One = 2
}

export class PlayerEngine {
  private static inst: PlayerEngine | null = null;

  static shared(): PlayerEngine {
    if (PlayerEngine.inst === null) {
      PlayerEngine.inst = new PlayerEngine();
    }
    return PlayerEngine.inst;
  }

  context: common.UIAbilityContext | null = null;
  current: Track | null = null;
  isPlaying: boolean = false;
  currentTimeMs: number = 0;
  durationMs: number = 0;
  shuffle: boolean = false;
  repeatMode: RepeatMode = RepeatMode.Off;

  private player: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  private queue: Track[] = [];
  private order: number[] = [];
  private orderPos: number = -1;
  private listeners: Array<() => void> = [];
  private curFile: fs.File | null = null;
  private pendingPlay: boolean = false;
  private bgActive: boolean = false;
  private resumePositions: Map<string, number> = new Map();
  private prefs: preferences.Preferences | null = null;
  private advancing: boolean = false;
  // AVPlayer 的 timeUpdate 只有 0.5~1s 一次，用墙钟插值出连续进度
  private baseMs: number = 0;
  private baseWall: number = 0;
  lyricOffsetMs: number = 0;
  // 输出通路延迟（ms）：蓝牙 A2DP 实测可达 150~250ms，歌词要按这个往后推
  outputLatencyMs: number = 0;

  refreshOutputLatency(): void {
    try {
      const rm = audio.getAudioManager().getRoutingManager();
      const devs = rm.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
      let ms = 0;
      for (const d of devs) {
        if (d.deviceType === audio.DeviceType.BLUETOOTH_A2DP) {
          ms = 180;
          break;
        }
        if (d.deviceType === audio.DeviceType.BLUETOOTH_SCO) {
          ms = 120;
        } else if (d.deviceType === audio.DeviceType.WIRED_HEADPHONES
          || d.deviceType === audio.DeviceType.WIRED_HEADSET) {
          ms = 25;
        }
      }
      this.outputLatencyMs = ms;
    } catch (e) {
      this.outputLatencyMs = 0;
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

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    try {
      this.prefs = await preferences.getPreferences(context, 'shiyin');
      const raw = this.prefs.getSync('resumePositions', '') as string;
      if (raw.length > 0) {
        const obj = JSON.parse(raw) as Record<string, number>;
        for (const k of Object.keys(obj)) {
          this.resumePositions.set(k, obj[k]);
        }
      }
      const adjRaw = this.prefs.getSync('lyricAdj', '') as string;
      if (adjRaw.length > 0) {
        const ao = JSON.parse(adjRaw) as Record<string, number>;
        for (const k of Object.keys(ao)) {
          this.adjByPath.set(k, ao[k]);
        }
      }
      // 手动歌词偏移已移除：清掉旧存档，避免残留值继续影响对齐
      this.prefs.putSync('lyricOffset', 0);
      // 播放模式：随机与循环在重启后保持上次的选择
      this.shuffle = this.prefs.getSync('play.shuffle', false) as boolean;
      const rm = this.prefs.getSync('play.repeatMode', 0) as number;
      this.repeatMode = (rm === 1 || rm === 2) ? rm : RepeatMode.Off;
      this.prefs.flush();
    } catch (e) {
      this.prefs = null;
    }
    await this.ensurePlayer();
    await this.ensureSession();
  }

  private async ensurePlayer(): Promise<void> {
    if (this.player !== null) {
      return;
    }
    try {
      const p = await media.createAVPlayer();
      p.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          p.prepare().catch((e: BusinessError) => hilog.error(0x0000, 'Shiyin', 'prepare %{public}d', e.code));
        } else if (state === 'prepared') {
          const resume = this.current !== null ? (this.resumePositions.get(this.current.path) ?? 0) : 0;
          if (resume > 1500 && resume + 5000 < p.duration) {
            p.seek(resume, media.SeekMode.SEEK_CLOSEST);
          }
          if (this.pendingPlay) {
            p.play().catch((e: BusinessError) => hilog.error(0x0000, 'Shiyin', 'play %{public}d', e.code));
          }
        } else if (state === 'playing') {
          this.isPlaying = true;
          this.refreshOutputLatency();
          this.baseWall = Date.now();
          this.startBg();
          this.pushSessionState();
          this.notify();
        } else if (state === 'paused') {
          this.isPlaying = false;
          this.baseMs = this.positionMs();
          this.pushSessionState();
          this.notify();
        } else if (state === 'completed') {
          this.onTrackEnded();
        }
      });
      p.on('error', (e: BusinessError) => {
        hilog.error(0x0000, 'Shiyin', 'player error %{public}d %{public}s', e.code, e.message);
        this.saveResume();
        this.advance(1);
      });
      p.on('endOfStream', () => {
        this.onTrackEnded();
      });
      p.on('durationUpdate', (d: number) => {
        this.durationMs = d;
        this.pushSessionMeta();
        this.notify();
      });
      p.on('timeUpdate', (t: number) => {
        this.baseMs = t;
        this.baseWall = Date.now();
        this.currentTimeMs = t;
        this.notify();
      });
      this.player = p;
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'createAVPlayer failed');
    }
  }

  private async ensureSession(): Promise<void> {
    if (this.session !== null || this.context === null) {
      return;
    }
    try {
      const s = await avSession.createAVSession(this.context, 'shiyin', 'audio');
      s.on('play', () => {
        this.play();
      });
      s.on('pause', () => {
        this.pause();
      });
      s.on('playNext', () => {
        this.advance(1);
      });
      s.on('playPrevious', () => {
        this.advance(-1);
      });
      s.on('stop', () => {
        this.stop();
      });
      s.on('seek', (time: number) => {
        this.seekTo(time);
      });
      await s.activate();
      this.session = s;
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'createAVSession failed');
    }
  }

  playQueue(tracks: Track[], startAt: Track | null): void {
    this.queue = tracks.slice();
    this.buildOrder();
    let pos = 0;
    if (startAt !== null) {
      // 不能用对象身份定位：曲库重扫后 Track 会换成新实例，
      // indexOf 失配就会退化成「从队列第一首开始播」
      const qi = this.queueIndexOf(startAt);
      const oi = this.order.indexOf(qi);
      if (oi >= 0) {
        pos = oi;
      }
    }
    this.orderPos = pos;
    this.loadTrack(this.queue[this.order[pos]], true);
  }

  // 按 path 定位队列下标（-1 表示不在队列里）
  private queueIndexOf(track: Track): number {
    for (let i = 0; i < this.queue.length; i++) {
      if (this.queue[i].path === track.path) {
        return i;
      }
    }
    return -1;
  }

  private buildOrder(): void {
    this.order = [];
    for (let i = 0; i < this.queue.length; i++) {
      this.order.push(i);
    }
    if (this.shuffle) {
      for (let i = this.order.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const t = this.order[i];
        this.order[i] = this.order[j];
        this.order[j] = t;
      }
    }
  }

  private closeFile(): void {
    if (this.curFile !== null) {
      try {
        fs.closeSync(this.curFile);
      } catch (e) {
        // ignore
      }
      this.curFile = null;
    }
  }

  private async loadTrack(track: Track, autoplay: boolean): Promise<void> {
    await this.ensurePlayer();
    const p = this.player;
    if (p === null) {
      return;
    }
    this.saveResume();
    this.current = track;
    this.currentTimeMs = 0;
    this.baseMs = 0;
    this.baseWall = Date.now();
    this.durationMs = track.durationMs;
    this.pendingPlay = autoplay;
    this.notify();
    this.pushSessionMeta();
    try {
      if (p.state !== 'idle') {
        await p.reset();
      }
      this.closeFile();
      this.curFile = fs.openSync(track.path, fs.OpenMode.READ_ONLY);
      p.url = `fd://${this.curFile.fd}`;
    } catch (e) {
      hilog.error(0x0000, 'Shiyin', 'loadTrack failed');
      this.advance(1);
    }
  }

  play(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    if (this.current === null && this.queue.length > 0) {
      this.playQueue(this.queue, null);
      return;
    }
    this.pendingPlay = true;
    if (p.state === 'paused' || p.state === 'completed') {
      p.play().catch((e: BusinessError) => hilog.error(0x0000, 'Shiyin', 'play %{public}d', e.code));
    } else if (p.state === 'stopped' || p.state === 'idle') {
      if (this.current !== null) {
        this.loadTrack(this.current, true);
      }
    }
  }

  pause(): void {
    const p = this.player;
    if (p !== null && p.state === 'playing') {
      this.saveResume();
      p.pause().catch((e: BusinessError) => hilog.error(0x0000, 'Shiyin', 'pause %{public}d', e.code));
    }
    this.stopBg();
  }

  togglePlay(): void {
    if (this.isPlaying) {
      this.pause();
    } else {
      this.play();
    }
  }

  stop(): void {
    const p = this.player;
    if (p !== null && (p.state === 'playing' || p.state === 'paused')) {
      this.saveResume();
      p.stop().catch((e: BusinessError) => undefined);
    }
    this.isPlaying = false;
    this.stopBg();
    this.pushSessionState();
    this.notify();
  }

  seekTo(ms: number): void {
    const p = this.player;
    if (p === null || (p.state !== 'playing' && p.state !== 'paused' && p.state !== 'prepared')) {
      return;
    }
    this.currentTimeMs = ms;
    this.baseMs = ms;
    this.baseWall = Date.now();
    p.seek(Math.max(0, ms), media.SeekMode.SEEK_CLOSEST);
    this.notify();
  }

  /** 连续进度：timeUpdate 之间用墙钟插值，歌词/进度条不再跳秒 */
  positionMs(): number {
    if (!this.isPlaying) {
      return this.baseMs;
    }
    const est = this.baseMs + (Date.now() - this.baseWall);
    const dur = this.durationMs > 0 ? this.durationMs : 0;
    return dur > 0 ? Math.min(est, dur) : est;
  }

  advance(by: number): void {
    if (this.queue.length === 0 || this.advancing) {
      return;
    }
    this.advancing = true;
    try {
      if (this.order.length !== this.queue.length) {
        this.buildOrder();
      }
      let next = this.orderPos + by;
      if (next >= this.order.length) {
        if (this.repeatMode === RepeatMode.All) {
          next = 0;
        } else {
          this.stop();
          return;
        }
      }
      if (next < 0) {
        next = this.repeatMode === RepeatMode.All ? this.order.length - 1 : 0;
      }
      this.orderPos = next;
      this.loadTrack(this.queue[this.order[next]], true);
    } finally {
      this.advancing = false;
    }
  }

  private onTrackEnded(): void {
    if (this.repeatMode === RepeatMode.One) {
      const p = this.player;
      if (p !== null) {
        p.seek(0, media.SeekMode.SEEK_CLOSEST);
        p.play().catch((e: BusinessError) => undefined);
      }
      return;
    }
    this.advance(1);
  }

  setShuffle(on: boolean): void {
    this.shuffle = on;
    const cur = this.current;
    this.buildOrder();
    if (cur !== null) {
      const oi = this.order.indexOf(this.queueIndexOf(cur));
      if (oi >= 0) {
        this.orderPos = oi;
      }
    }
    this.savePlayModes();
    this.notify();
  }

  cycleRepeat(): void {
    this.repeatMode = (this.repeatMode + 1) % 3;
    this.savePlayModes();
    this.notify();
  }

  private savePlayModes(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync('play.shuffle', this.shuffle);
      this.prefs.putSync('play.repeatMode', Number(this.repeatMode));
      this.prefs.flush();
    } catch (e) {
      // 存档失败不影响本次播放，下次启动回到默认
    }
  }

  private adjByPath: Map<string, number> = new Map();

  // 每首歌各自的歌词偏移（毫秒）：源文件时间轴本身不准时唯一的补救
  lyricAdjFor(path: string): number {
    const v = this.adjByPath.get(path);
    return v === undefined ? 0 : v;
  }

  setLyricAdj(path: string, ms: number): void {
    this.adjByPath.set(path, ms);
    if (this.prefs === null) {
      return;
    }
    try {
      const obj: Record<string, number> = {};
      this.adjByPath.forEach((v: number, k: string) => {
        obj[k] = v;
      });
      this.prefs.putSync('lyricAdj', JSON.stringify(obj));
      this.prefs.flush();
    } catch (e) {
      // 存不上就只在本次生效
    }
  }

  private saveResume(): void {
    if (this.current === null || this.prefs === null) {
      return;
    }
    if (this.currentTimeMs > 1500) {
      this.resumePositions.set(this.current.path, this.currentTimeMs);
    } else {
      this.resumePositions.delete(this.current.path);
    }
    const obj: Record<string, number> = {};
    for (const k of Array.from(this.resumePositions.keys())) {
      obj[k] = this.resumePositions.get(k) ?? 0;
    }
    try {
      this.prefs.putSync('resumePositions', JSON.stringify(obj));
      this.prefs.flush();
    } catch (e) {
      // ignore
    }
  }

  private async startBg(): Promise<void> {
    if (this.bgActive || this.context === null) {
      return;
    }
    try {
      const w: Want = { bundleName: 'com.shiyin.player', abilityName: 'EntryAbility' };
      const info: wantAgent.WantAgentInfo = {
        wants: [w],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wa);
      this.bgActive = true;
    } catch (e) {
      hilog.warn(0x0000, 'Shiyin', 'startBg failed');
    }
  }

  private stopBg(): void {
    if (!this.bgActive || this.context === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(this.context).catch((e: BusinessError) => undefined);
    this.bgActive = false;
  }

  private pushSessionMeta(): void {
    const s = this.session;
    if (s === null || this.current === null) {
      return;
    }
    const meta: avSession.AVMetadata = {
      assetId: this.current.path,
      title: this.current.title,
      artist: this.current.artist,
      duration: this.durationMs > 0 ? this.durationMs : this.current.durationMs
    };
    s.setAVMetadata(meta).catch((e: BusinessError) => undefined);
  }

  private pushSessionState(): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    const st: avSession.AVPlaybackState = {
      state: this.isPlaying ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: { elapsedTime: this.currentTimeMs, updateTime: Date.now() }
    };
    s.setAVPlaybackState(st).catch((e: BusinessError) => undefined);
  }
}
