# 拾音 · HarmonyOS NEXT 版（Mate 70 Pro+）

纯血鸿蒙（HarmonyOS 5.x）原生 ArkTS 应用，功能对齐 iOS 版：

- 本地 MP3 播放（AVPlayer，fd:// 沙盒文件）
- 滚动 LRC 歌词（sidecar `.lrc` 优先，其次 ID3v2 USLT 内嵌；点击歌词跳转，手动滚动 4 秒内不抢滚动）
- 锁屏/控制中心播放控制（AVSession + AUDIO_PLAYBACK 连续任务）
- 局域网导入：mDNS 浏览 `_shiyin._tcp`（与 iOS 版共用 `SyncServer\启动同步服务器.bat`），HTTP Range 断点续传下载到应用沙盒 `files/Music`
- 上次播放位置记忆（preferences）、随机/循环、损坏文件自动跳过

## 工程结构

```
AppScope/                 应用级配置（bundleName: com.shiyin.player）
entry/src/main/
  module.json5            权限：INTERNET / GET_NETWORK_INFO / KEEP_BACKGROUND_RUNNING；backgroundModes: audioPlayback
  ets/
    entryability/         Ability 入口
    model/Track.ets       模型 + 文件名解析「歌手 - 标题」
    library/              曲库扫描、时长探测（AVMetadataExtractor）、ID3 内嵌歌词
    lyrics/LRCParser.ets  LRC 解析
    playback/PlayerEngine.ets  播放引擎（队列/随机/循环/后台/AVSession）
    sync/                 mDNS 发现 + HTTP 下载器
    pages/Index.ets       三标签 UI：曲库 / 播放 / 导入
```

## 构建与安装（Windows，无 Mac）

1. 安装 DevEco Studio（需华为账号登录下载）：https://developer.huawei.com/consumer/cn/deveco-studio/
2. 打开本工程（File → Open → 选择 `shiyin-harmony` 目录），等待 hvigor 同步
3. 手机开启开发者模式 + USB 调试（已开启），USB 连接
4. File → Project Structure → Signing Configs → 勾选 **Automatically generate signature** → 登录华为账号（个人开发者需实名认证）→ 自动生成调试证书 + Profile（自动包含已连接设备）
5. 设备选择 Mate 70 Pro+ → Run 'entry'
6. 命令行等价物（DevEco 自带 hdc）：`hdc list targets`、`hdc install entry/build/default/outputs/default/entry-default-signed.hap`

## 使用

1. 电脑运行 `..\shiyin-player\SyncServer\启动同步服务器.bat`（同一 WiFi，防火墙放行）
2. App「导入」标签：自动发现服务器 → 连接 → 全选未下载 → 下载选中；发现不了就手动输电脑 IP
3. 「曲库」点歌即播；「播放」标签看滚动歌词
