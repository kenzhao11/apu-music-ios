# iOS 已修复问题

本版本为 0.1.0 (2)。保留 XCTest/XCUITest 工作流；这次交付按要求只走打包流程，不运行模拟器或测试。

| 编号 | 现象 | 复现步骤 | 根因 | 测试名 | 修复版本 |
| --- | --- | --- | --- | --- | --- |
| IOS-001 | 点歌后没有声音 | 搜索一首腾讯歌曲并开始播放 | selected_id 错传 source_id；播放器忽略真实 API 返回包装；FLAC 没有等待完成和格式转换，失败时不报告 | `testPlaybackSelectionKeepsThePlatformTrackIDInsteadOfSourceID`, `testCompletedPlaybackAudioURLsAllowBackendRedirectSources`, `testStreamingLosslessWithoutNativeCodecWaitsForCompletedAudio`；真机声音验收 | 0.1.0 (2) |
| IOS-002 | 列表封面加载影响滑动顺畅度 | 首页、搜索结果和歌单列表快速滚动 | 同步反复取整图且没有共用解码与网络缓存 | `ArtworkCache` 源码检查；真机列表滚动验收 | 0.1.0 (2) |
| IOS-003 | 播放进度更新会刷新整个界面 | 播放音乐并观察播放页和列表 | 0.5 秒进度与播放器状态在同一个 ObservableObject 发布 | `PlaybackProgressControls` 源码检查；真机播放时滚动验收 | 0.1.0 (2) |
| IOS-004 | 播放器下滑难以收起 | 打开全屏播放器后从顶部向下划 | 滚动视图覆盖整个播放器并抢掉系统 sheet 手势 | 全屏拖动收起回归尚未验证；真机向下滑动验收 | 0.1.0 (2) |
| IOS-005 | App 图标与品牌显示不一致 | 安装后查看桌面、启动页和首页 | 原图标未统一替换 | App Icon 与启动页资源配置检查；真机查看验收 | 0.1.0 (2) |
