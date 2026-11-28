# iOS 已修复问题

| IOS-022 | 搜索结果补封面可能被串行上游请求拖住；暂态播放网络/5xx错误可能被误判为永久不可播 | 固定360行搜索回放并触发慢上游；注入网络错误与5xx后检查availability状态 | 封面补查未共享整体deadline；暂态错误分类漏掉网络异常和重试耗尽的5xx | Worker Node固定生产逻辑：定向17/17、全量96/96；固定回放缺图100→20、92唯一查询、74本地空cover更新、远端D1写入0。Swift队列修复由固定审核逐行通过；未运行Swift/XCTest | build9（源码审核通过，IPA待打包） |

本版本为 0.1.0 (8)。保留 XCTest/XCUITest 工作流；这次交付只走打包流程，不跑模拟器、不跑云测试，真机由 Ken 自测。

> **IOS-007 目标变更（0.1.0 (4)）**：按 Ken 的规则，本版固定使用歌单里已匹配的那一行音源，**不再跨来源换源**。启动慢由直连流式播放 + 下一首预解析解决；某个来源失败时按网站语义标记不可播并跳过，而不是静默换到另一个平台。所以 IOS-007 中「没有跨来源静默重试」不再是缺陷。

| 编号 | 现象 | 复现步骤 | 根因 | 测试名 | 修复版本 |
| --- | --- | --- | --- | --- | --- |
| IOS-001 | 点歌后没有声音 | 搜索一首腾讯歌曲并开始播放 | selected_id 错传 source_id；播放器忽略真实 API 返回包装；FLAC 没有等待完成和格式转换，失败时不报告 | `testPlaybackSelectionKeepsThePlatformTrackIDInsteadOfSourceID`, `testCompletedPlaybackAudioURLsAllowBackendRedirectSources`, `testStreamingLosslessWithoutNativeCodecWaitsForCompletedAudio`；真机声音验收 | 0.1.0 (2) |
| IOS-002 | 列表封面加载影响滑动顺畅度 | 首页、搜索结果和歌单列表快速滚动 | 同步反复取整图且没有共用解码与网络缓存 | `ArtworkCache` 源码检查；真机列表滚动验收 | 0.1.0 (2) |
| IOS-003 | 播放进度更新会刷新整个界面 | 播放音乐并观察播放页和列表 | 0.5 秒进度与播放器状态在同一个 ObservableObject 发布 | `PlaybackProgressControls` 源码检查；真机播放时滚动验收 | 0.1.0 (2) |
| IOS-004 | 播放器下滑难以收起 | 打开全屏播放器后从顶部向下划 | 滚动视图覆盖整个播放器并抢掉系统 sheet 手势 | 全屏拖动收起回归尚未验证；真机向下滑动验收 | 0.1.0 (2) |
| IOS-005 | App 图标与品牌显示不一致 | 安装后查看桌面、启动页和首页 | 原图标未统一替换 | App Icon 与启动页资源配置检查；真机查看验收 | 0.1.0 (2) |
| IOS-006 | 搜索暴露来源且重复歌曲多次出现 | 搜索跨平台热门歌曲 | 搜索行按平台歌曲 id 区分，且结果直接逐条展示 | `testSearchResultsMergeSourcesButKeepDistinctSongsDistinct`；真机搜索验收 | 0.1.0 (3) |
| IOS-007 | 启动后播放慢或某个来源失败就不能继续播放 | 搜索歌曲并立即播放，或选择失效来源 | 播放等待时间过长且没有跨来源静默重试 | `testSearchResultsMergeSourcesButKeepDistinctSongsDistinct`（来源候选）；真机网络/播放验收 | 0.1.0 (3) |
| IOS-008 | iPhone 画面被按旧小屏设备缩放 | 全新安装后查看首页和底栏 | App plist 缺启动屏，且 target 声明了 iPad | 打包后 plist 检查与静音模拟器首页截图；真机显示验收 | 0.1.0 (3) |
| IOS-009 | 桌面图标仍是旧图或资源未编入包 | 安装 IPA 查看主屏图标 | XcodeGen 未把 Assets.xcassets 作为资源编译 | 包内 AppIcon、Assets.car 和图标清单检查；真机查看验收 | 0.1.0 (3) |
| IOS-010 | 点歌后很久才出声 | 搜索一首腾讯歌曲并立即播放 | 后端 `format` 恒为空，旧代码据此每首都先整段下载再转码 | `PlaybackResolver.prepare` 源码检查；对齐脚本实测首字节；真机出声验收 | 0.1.0 (4) |
| IOS-011 | 播放页显示的“音质”其实是请求档位 | 播放任意歌曲看播放页音质行 | 界面直接显示请求的档位，后端又没有 bitrate 元数据 | `AudioProbe.facts` 源码检查（206 + Content-Range）；真机查看 | 0.1.0 (4) |
| IOS-012 | 某平台失败时 App 自己换到另一个平台 | 播放一个失效的已匹配音源 | 旧代码按 `candidates` 跨平台重试，与网站只认已匹配音源不一致 | `scripts/align_report.py`（1022 首两侧请求/音源/歌曲ID/实际音质比对） | 0.1.0 (4) |
| IOS-013 | 点爱心没有即时反馈、失败也不提示 | 在列表或播放页点爱心 | 先写存储再刷新，写失败静默 | `FavoriteLibrary.commit` 源码检查；真机点按验收 | 0.1.0 (4) |
| IOS-014 | 下载失败没有任何提示 | 断网或失败音源点下载 | 只有进度没有错误出口 | `DownloadManager` 源码检查（alertMessage/errors）；真机断网下载验收 | 0.1.0 (4) |
| IOS-015 | 下载过早开始读取、FLAC 转码且 Ogg 不可下载 | 搜索不同平台音源，选择下载并观察原文件与下载状态 | 下载复用了允许 streaming 的播放就绪条件，URLSession data 聚合读取，FLAC 被转码，Ogg 魔数未识别，缺少完成长度校验 | 源码检查 + `reports/search_download_report.csv` 30 首真实 API；背景下载恢复和完整/断点验收待真机 | 0.1.0 (8) |
| IOS-018 | build8 Release 编译失败 | 运行 ios-package-only 的 Build Release for device | Player.swift:244 的 Logger.error 插值自动闭包访问 current、activePlaybackTaskID 缺少显式 self | 原 run 44887781118 编译器报错；仅补 self，不改播放/下载行为；按要求不跑测试，待新 package-only 验证 | 0.1.0 (8) |
| IOS-017 | 系统恢复下载成功后遗留整份临时音频 | 下载中结束 App，等待 iOS 恢复后台下载并保存 | DownloadStore.add 复制临时文件到 Documents，恢复分支只在失败时清理临时文件 | 静态路径核查：恢复分支 defer 在成功及失败时均清理临时文件；依 Ken 要求不跑测试，待真机 | 0.1.0 (8) |
| IOS-016 | 打包检查自我命中、并发下载可能丢失记录、后台恢复校验失败不重试、启动超时不重试 | 静态检查打包 workflow；并行下载与普通保存/删除；在后台下载完成前结束进程并制造校验错误；启动播放器后不返回数据 | workflow grep 把检查命令本身当违规命令；DownloadStore records 读改写未串行；恢复任务校验错误没有 job 时被丢弃且完成回调无重试；启动超时包装成 unavailable 未纳入网络重试条件 | 静态 diff 与流程检查；依 Ken 要求不跑测试/模拟器，后台恢复及播放器行为待真机 | 0.1.0 (8) |
| IOS-019 | 播放时发现确定不可播后，搜索列表仍显示可播且可再次请求 | 在列表点播一首后端明确标为不可播的歌，返回搜索结果查看该行 | 不可播状态只留在播放队列副本，没有跨视图共享 | Swift 固定审核逐行检查；未编译/XCTest，待 build9 真机验收 | build9（未打包） |
| IOS-020 | 连续多首不可播会提前停止、已知不可播歌曲再次入队，列表缓存小图无法供播放页先显 | 固定队列前8首连续失败、第9首可播；重建队列时传入已知不可播ID；验证@2x/@3x列表实际缓存像素均可被同URL播放页预览读取；签名URL测试逐项生成四种真实query键 | 失败时反复重建过滤队列导致长度门限收缩；共享不可播集合未用于队列创建；缓存只按126像素盲查；签名回归字符串插值写错 | 新增 `testQueueSkipsEightConsecutiveFailuresWithoutLosingPlayableTail`、`testAllUnavailableQueueTerminatesWithoutWrappingOrReattempting`、`testSharedUnavailableIDsAreExcludedWhenRebuildingQueue`、`testTransientFailuresAdvanceWithoutPermanentlyDisablingTracks`、`testArtworkPreviewReusesActualCachedListPixelsAtEveryScale`；签名插值已纠正。按本次裁决未运行Swift/XCTest，固定审核逐行检查与build9真机验收待完成 | build9（未打包） |
| IOS-021 | 运行时标为不可播的歌曲可能在下一首、随机、循环、上一首或预取时再次播放请求；上一首重建队列时队列数组和索引不一致 | 将队列中间项标为不可播，再分别推进普通下一首、随机/列表循环、上一首及预取；当前曲失败后追加续曲并确认仍能选到尾部可播项 | 队列推进不统一过滤运行时`canPlay=false`；上一首重建过滤队列后没有同步游标/数组；续曲独立改写展示数组，遗漏稳定队列索引 | 新增 `testNormalAdvanceSkipsRuntimeUnavailableTracksWithoutShrinkingQueue`、`testRepeatAdvanceSkipsUnavailableHeadAndStopsWhenAllUnavailable`、`testShuffleAdvanceSkipsUnavailableTargetAndIsBounded`、`testPreviousSkipsRuntimeUnavailableAndKeepsArrayAndIndexAligned`、`testPrefetchSelectionUsesSameUnavailableSkipWithoutMovingActualQueue`、`testContinuationAfterUnavailableCurrentKeepsCursorBeforeNewTail`；另修复既有 `excluding:` XCTest 参数标签。按本次裁决未运行Swift/XCTest；固定审核逐行检查与build9真机验收待完成 | build9（未打包） |
