# 阿噗音乐下载与播放修复（build 8）

## 真实 API 取证

数据来自 2026-11-21 对线上只读 API 的一次全新采样；每首均按 App 请求形状 POST `/api/v1/playbacks`，`quality=high`、`streaming_mode=null`、`include_cover=false`、`selected_id=搜索行 id`。逐曲结果见 `reports/search_download_report.csv`。

- 共 30 首：tencent 21、netease 7、kugou 1、youtubemusic 1；该固定关键词样本没有 Apple Music 返回，未从别处补造。
- 30/30 后端任务在首次状态观察时已经 `completed`；没有后端 failed、等待超时或 streaming 状态样本。因此 streaming 阶段字节数标记“首次观察已 completed，未观测”，不与完整文件字节混淆。
- 30/30 音频请求完成，最终 200；30/30 实际落盘字节数等于 `Content-Length`，总计 474,415,794 字节（约 452.5 MiB）。30/30 有 302 跳转后到音频域名的记录。
- 格式魔数：MP3 21、M4A/MP4 3、Ogg 3、FLAC 3。响应头 `Content-Type` 与魔数同时记录；签名查询参数不写入报告。
- 先前探查中的大 FLAC 流在本轮一次传输中途断开；这证明连接中断可发生，不代表 30 首新样本中下载失败。真实 streaming 阶段对比及真实后端 failed 统计在本次样本中不可得。

## 根因与修复

- 搜索行须保持 `selected_id=item.id`、`source_id=item.source_id || item.id`；App 搜索解码现显式归一化这两个字段，避免把 source id 错作播放选择。
- 旧下载路径先使用播放就绪标准，FLAC 还经过转码且不识别 Ogg；改为下载专用 resolver 必须等任务 `completed`，URLSession 后台 `downloadTask` 直接写临时文件，保留 FLAC/MP3/AAC/M4A/Ogg/WAV 原始字节。
- 下载校验要求识别的容器魔数和非空文件；200 响应校验完整 `Content-Length`，206 按 `Content-Range` 的完整总长语义校验；无可信长度或长度不匹配则失败，不保存。
- 后台下载重用固定 session identifier，资源超时 3600 秒、请求超时 120 秒；下载失败尝试 resume data 一次，iOS 重启后的完成事件以 task metadata 恢复并保存。并发连接限制为 2。
- 播放 API 的网络错误/超时以原请求重试一次；后台明确 failed 一律转不可播并按队列规则跳过，既有连续失败上限保留。AVPlayerItem 失败写 `selected_id`、taskID、错误 domain/code 至 `ApuMusic.playback`，标识和任务 ID为私密日志字段。
- 下载就绪阶段显示不确定进度与“准备中” spinner；下载失败使用通用中文文案，不显示音源或音质信息。

## 审核问题修正（fe4c67e 静态复审通过）

- 修复 package-only workflow 自身 grep 扫描命中；规则只检查 workflow 中的命令内容。
- `DownloadStore` 对 records 的读写加串行锁，并清理同一曲目替换后的旧文件，防止后台保存与主线程保存/删除覆盖记录。
- iOS 恢复的后台任务遇到校验/保存失败会最多重试一次；最终失败写入持久化队列，由下载管理器恢复后显示通用错误提示。
- 播放启动 30 秒超时与其他网络失败一样，使用相同选曲重试一次。
- 复审发现恢复下载成功时遗留临时音频：恢复分支改为 `defer` 清理，Documents 复制保存成功与失败两条路径都会移除临时文件；有内存 job 的普通下载仍将临时文件交给调用者处理。
- 审核开发对 `de3a811..fe4c67e` 的结论原文：「通过。问题清单：无新增阻塞项。」确认恢复分支 defer 覆盖成功与失败，Documents 副本不受清理影响，普通下载路径未改变；未删改测试。
- 上述为代码静态修正，未执行测试或真机验证。审核通过后合并 main，仅启动 `ios-package-only.yml`；推送提交使用 `[skip ci]`，避免旧 push 工作流自动运行模拟器测试。构建和包校验结果另记交付记录。

## build8 编译修正与安装包交付（已完成）

- 原仅打包 run `44887781118` 于 2026-11-21 17:04:46 北京时间结束为 failure，不是仍在执行。失败日志指向 `Player.swift:244:63` 与 `:128`：Logger.error 的插值自动闭包引用实例属性须明确写 `self`。
- 最小修复仅将 `current`、`activePlaybackTaskID` 改为 `self.current`、`self.activePlaybackTaskID`；保留日志隐私级别及下载/播放行为。其余同文件 Logger 调用未发现同类实例属性捕获。
- 修复提交 `db9e5dc`。固定审核开发结论原文：「通过。`b908a0e..db9e5dc` 增量无阻塞问题，可合入 main。」本地复核源码差异仅两个 self.，测试、工作流、project.yml 两端无差异，git diff --check 通过。
- 已合入并推送 main：420e5bb3e7ba02ee60b06d835185bfb434a27f1d，含修复 db9e5dc。package-only run 44891936200 已 completed/success，于 2026-11-21 17:57:24 北京时间完成；本轮核对 run 与 artifact 的 headSha 均精确匹配该提交，未重新构建。
- 2026-11-21 18:04 北京时间完成桌面交付：`C:/Users/kenzh/Desktop/ApuMusic-0.1.0-build8-unsigned.ipa`，实际大小 **2,815,445 字节**，包内 `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=8`、`CFBundleIdentifier=fr.kdns.kenmusic.apu`，ZIP 完整性通过。目标原先不存在，未覆盖任何旧包。
- IPA SHA256：`afaf32774af1fe73d37d7cca688d43bbba2cae8bacb5b3fb320cd2338f2424da`。桌面副本与成功 run 提取的 IPA 大小、SHA256 和包内版本一致。
- 来源 artifact：`14702596685` / `ApuMusic-0.1.0-build8-unsigned-package-only`；下载归档 2,810,859 字节，SHA256=`b6bbf3cf4badc82f0bc1aee22c421e8d9b3ab96d37f0a38f25d47bea6dc74690`，与 GitHub artifact digest 一致。
- 机器可读证据：`C:/Users/kenzh/.openmausbot/task-workspaces/aa861c3b-a7cc-430a-bf1c-38249cd022bd/8f7e3f9a-cb17-453a-b958-f7d00ef6bf94/build8-delivery/delivery-evidence.json`。逐曲 CSV：`D:/Projects/apu-music-ios/reports/search_download_report.csv`。
- 已读回确认本对话没有未结束等待、本 bot 没有自动化，无需取消临时监控。本轮只下载、核验并更新交付记录；未改业务代码，未新增/运行测试、模拟器、截图或手机操作。新包须 Ken 安装确认后再安排真机验收。

## 边界与未验证

没有改动线上 Worker、D1、后端或网站。按要求未运行测试、模拟器、截图、真机或云端测试。当前环境是 Windows，无法本地运行 Xcode；只能由 `ios-package-only` macOS 工作流做 Release 编译并出 unsigned IPA。后台 URLSession 下载恢复、真实断点续传、AVPlayer 播放重试及 UI 行为均待真机验收。
