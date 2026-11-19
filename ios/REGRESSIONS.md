# iOS 已修复问题

本版本为 0.1.0 (3)。保留 XCTest/XCUITest 工作流；这次交付只走打包流程，并在静音的 iPhone 15 Pro 模拟器截首页，不运行 XCTest/XCUITest。

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
