# 阿噗音乐 下载/播放修复 任务计划（任务 owner：开发一）

## 目标（唯一主交付物）
1. `reports/search_download_report.csv`：约 30 首逐首真实取证（App 真实参数 POST /playbacks，quality=high），记录状态流转、耗时、失败原因、302 链、content-type、总大小、streaming/completed 实际下载字节对比，并定位 DownloadManager / CompatibleAudio.localFile / PlaybackResolver.waitUntilReady 卡点。
2. 代码修复：
   - 下载必须 `completed` 后取完整文件；下载与播放就绪标准分开。
   - 后台 URLSession downloadTask 直接落盘，放宽大 FLAC 超时，断点续传 + 失败自动重试 1 次。
   - FLAC/MP3/AAC 原样保存不转码；扩展名依据 content-type 与文件头（含 Ogg 等真实返回）。
   - 完整大小校验：Content-Length / Content-Range 语义，302/206 处理，缺长度显式处理；不符删除半成品并失败。
   - 失败提示人话，不展示音源名/音质。
   - 播放：网络类/超时同请求同参数重试 1 次；后端 failed 按不可播自动下一首，跳曲/重试有界。
   - AVPlayerItem 失败写 selected_id/taskID/错误码到 os_log category `ApuMusic.playback`。
3. `DONE.md`：后端问题、真实失败统计、修法、限制。
4. build8 提交推送 main，仅 `ios-package-only` 打包，IPA 落桌面并校验包内版本。

## 约束
- 只读参考线上后端，不改后端/Worker/D1/网站。
- 不做任何测试、不跑模拟器、不截图、不跑云测试。
- 所有脚本/构建套 `python C:\Users\kenzh\hark_tasks\memcap.py 2048 <命令>`；限并发、流式落盘、不把大音频读入内存。
- 签名 URL / 凭据脱敏，不提交私密曲库数据。

## 阶段
- [x] 阶段 0：仓库与线上接口现状核对（HEAD 25ad1ff，403 偶发需退避）
- [x] 阶段 1：30 首真实取证已落盘 → reports/search_download_report.csv（全部首次观察 completed，streaming 未观察）
- [x] 阶段 2：修复 CompatibleAudio / DownloadManager / PlaybackResolver / Player；审核意见已完成代码修正并经固定审核开发复审通过
- [x] 阶段 3：DONE.md 汇总真实失败统计与修法（含本轮审核修正与未验证边界）
- [x] 阶段 4：审核通过后合并 main；ios-package-only run 44891936200 completed/success，IPA 已于 2026-11-21 18:04 北京时间落桌面并完成来源、版本、大小及 SHA256 核验
- [x] 阶段 5：初审四项阻塞已在 de3a811 修正；复审临时音频遗留已在 fe4c67e 修正，审核开发静态复审通过，无新增阻塞项

## 当前续接状态
- 本轮增量分支 fix/music-build8-log-capture 已审核并合入 main；交付版本 0.1.0/build8。
- 仅修恢复下载的临时文件生命周期，未触碰另一开发分支及未跟踪探查文件。
- 审核结论：fe4c67e 已通过固定审核开发只读复审。
- 已合并并推送 main：b908a0e79a686754e27c002be01a499b15581144（[skip ci]，未启动旧 push 测试工作流）。
- 旧仅打包 run：44887781118 已于 2026-11-21 17:04:46 北京时间 completed/failure，不能再当作正在打包。已读取失败日志：Player.swift:244 的 Logger.error 插值自动闭包访问 current 与 activePlaybackTaskID 缺少显式 self。
- 本轮最小修复：仅对这两个实例属性补 self.；同文件其余 Logger 调用为局部变量/参数，无同类实例属性捕获。未改变下载、播放或重试行为，未运行测试。
- 本轮修复提交：db9e5dc；固定审核开发只读复核原文：「通过。`b908a0e..db9e5dc` 增量无阻塞问题，可合入 main。」本地已核对源码仅两个 self.、测试/工作流/版本对象无变化，git diff --check 通过。
- 已快进合入并推送 main：420e5bb3e7ba02ee60b06d835185bfb434a27f1d，含修复 db9e5dc。仅打包 run 44891936200 已 completed/success，结束时间 2026-11-21 17:57:24 北京时间；run headSha 与 artifact workflow_run.head_sha 均精确匹配该提交。本轮未重跑构建、未改业务代码。
- 桌面交付：C:/Users/kenzh/Desktop/ApuMusic-0.1.0-build8-unsigned.ipa；实际 2,815,445 字节；包内 CFBundleShortVersionString=0.1.0、CFBundleVersion=8、CFBundleIdentifier=fr.kdns.kenmusic.apu；IPA ZIP 完整性核验通过。目标原先不存在，未覆盖旧包。
- IPA SHA256：afaf32774af1fe73d37d7cca688d43bbba2cae8bacb5b3fb320cd2338f2424da。
- 来源 artifact：14702596685，ApuMusic-0.1.0-build8-unsigned-package-only，归档 2,810,859 字节；归档 SHA256=b6bbf3cf4badc82f0bc1aee22c421e8d9b3ab96d37f0a38f25d47bea6dc74690，与 GitHub artifact digest 一致。桌面副本与提取的 IPA 大小、SHA256、包内版本一致。
- 交付证据：C:/Users/kenzh/.openmausbot/task-workspaces/aa861c3b-a7cc-430a-bf1c-38249cd022bd/8f7e3f9a-cb17-453a-b958-f7d00ef6bf94/build8-delivery/delivery-evidence.json。
- 临时等待/监控：已读回确认本对话无未结束等待，本 bot 无自动化；未改常设任务。
- 已完成安装包交付；未跑测试、模拟器、截图或手机测试。真机行为仍未验证，须 Ken 安装并确认新 build8 后方可安排。

## 已确认的真实接口事实（2026-11-21）
- `POST /api/v1/playbacks` 参数：`platform, query=歌名, selected_id=行id, quality=high, streaming_mode=null, include_cover=false`；403 为偶发，需退避重试。
- `audio_url` = `/api/v1/playbacks/{id}/audio` → 302 到 `music.zr.wiki` / `music.op.wiki`；不带 Range 时 200 + `Content-Length` + `Accept-Ranges: bytes`；带 Range 时 206 + `Content-Range: bytes a-b/total`。
- 真实容器不止 flac/mp3/m4a：tencent Style(2582) 返回 **audio/ogg + `OggS`**，当前 `transcodeIfNeeded` 会直接抛“音频格式不受支持”，下载必失败（本次修复点）。
- 任务对象 `format`/`content_type`/`byte_size` 常为空字符串/null，不能依赖，需从下载响应头+文件头判定。
