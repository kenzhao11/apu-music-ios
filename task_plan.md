# 阿噗音乐 iOS build 9 — 阶段计划（2026-11-28）

## 最新续接裁决与返修设计（2026-11-28 第五轮审核返修）
- 核对唯一brief及审核派单050f6bda：仅余Swift三项阻断，本轮不重跑无变更的Worker、不部署、不写线上D1、不打包。固定审核仍在原线程9a662953-27fc-4542-98eb-dc527c5c262e，不开新审。
- 根因：XCTest调用外部标签错误；previous重建后未同步数组/游标；普通advance不排除运行时标记不可播项。
- 最小设计：保持失败后队列长度与游标稳定；普通/随机/循环advance与retreat统一以canPlay为选择条件，扫描最多tracks.count次；Player只从PlaybackQueue同步queue/index后准备；预取用值类型副本沿同一路径选择；续曲在原队列尾部安全追加，排除共享不可播且去重，不重建丢失游标。
- 已先补6个XCTest场景（普通下一首、循环/全不可播、随机、上一首、预取副本、续曲游标），修正两处标签为excluding，旧断言未改。按最新裁决不运行Swift/XCTest、不安装工具链；本轮仅本地源码一致性检查与diff检查，不声称Swift编译/运行通过。
- 非阻断预览缓存索引容量建议本轮不扩大修改；保留后续优化项。
- 下一步：提交限定文件与本地静态证据，原审单rework复审通过前不打包；仅打包时再将版本号和产物名调整为build9，一并供审核核对。不合并main，不触发旧push测试workflow。
- 下方历史阶段条款与最新brief冲突时，以brief开头为准：92首限定补空cover已获准，不需重新批准；部署前只等待Lead完成实际接口/写路径转告。Swift红绿与云测试已明确豁免/禁止。

## 上轮续接裁决与返修设计（2026-11-28 12:43）
- 唯一主需求仍为 Lead 指定 brief 开头最新裁决。92行先备份仅补空 cover 已授权；部署前须先由 Lead 转告接口/写库条件，不是重新申请功能授权。本轮不部署、不执行线上补图。
- 已提交基线：iOS f8bd801、MHub d4d6fc6；原审核线程「审查：阿噗音乐 build9 本地实现」完整ID `9a662953-27fc-4542-98eb-dc527c5c262e`，只在此续审。
- 最新审核四项根因已核实：签名用例把插值写成字面量；缓存精确尺寸查询仅补126不能覆盖@2x；失败后缩队列再用长度作门限会提前停止；新队列未排除共享不可播集合。
- 最小修法：修正用例插值（不删/弱化断言）；缓存按URL索引实际已缓存尺寸，预览不发网络且仍保留精确高清键；队列失败按未尝试ID单向推进、不重建缩队列、不按固定5次截断；所有新建队列排除共享不可播ID，并在点击/预取/续曲入口守卫。
- 先补 XCTest 覆盖连续8首失败后仍到可播尾曲、全失败有界结束、共享集合不重新入队、84/126及其他列表尺寸缓存复用。依本次豁免不运行Swift/XCTest、不装Swift、不跑云测试；固定审核逐行检查，审核通过后才仅打包。
- Node已有最终定向17/17、全量96/96日志（`build9-review-green-targeted-final.log` / `build9-review-green-final.log`），不把旧95/95或人工样本日志作为最终证据。后端本轮无变化，不重跑已完成测试。

## 当前任务唯一主交付
基于build8，仅修封面缺失、播放失败、清晰度，交付build9。2026-11-28 07:50续派已允许本地实施：Node直接测试真实生产Worker/D1逻辑先红后绿；Swift豁免红绿但须审核逐行走查，禁止安装Swift、云端任何测试、模拟器/手机操作。允许新增封面provider详情补查、两源备用匹配、D1空cover安全回写与92首一次性补图脚本（先备份/干跑）。**后端部署与线上补图执行仍待Ken单独批准，不得提前执行。** 所有原始证据保留，不重采搜索混样本。历史build8计划保留于后半。

## 阶段1设计与实施门（本次新授权覆盖下文历史阻塞）
1. 建独立fix/build9分支；保留两仓已有脏文件，限定源码/测试/脚本文件。
2. 先定位真实provider歌曲/专辑详情路径与返回schema，用source_id实测，URL档位下载解码验证，严禁猜接口。缺cover：同源详情 -> 名称/歌手精确匹配其他两源一次 -> 无图负缓存/统一占位。
3. 对生产Worker逻辑加Node用例并先跑红，记录原输出；实现后同用例及旧测试全部绿，不改旧断言。
4. D1写入只限`cover`，按id+source/source_id身份与cover仍为空限制；不覆盖非空/不碰Spotify artwork。92首脚本需固定ID白名单、执行前导出备份、干跑统计及WHERE验证；此轮只准备不执行。
5. 输出层64/300/640（不支持640选已实测最近更大）与fallback源URL，不批量改D1。iOS按场景、分档缓存、小图先显/高清替换，详情一次补查，统一占位；错误类别/精确提示/队列有界跳过，取消防串状态。
6. 播放聚焦原22个API失败：重试 -> 降音质 -> 同歌两备用源；暂态和确定不可播分开，本地注入测试，不能冒充AVPlayer验证。
7. 同原360行快照/92首回放与各源像素报告；本地API回放与实际线上/真机分开。
8. 完成本地实施/红绿后先报Lead接口/写路径/部署范围，并暂停等部署授权；开发自行直送审核开发在固定审核线程逐条审（Swift逐行）。未经审结/后续授权不打包、不合并。

## 范围与固定采样口径
- 允许按上文07:50新授权修改相关后端源码，线上部署/写入另等授权；其余线上D1只读，不改整体布局/无关页面，不操作Ken手机。
- 禁止云端模拟器、XCTest、真机；Windows 无 Xcode；CI 仅可在后续授权时作编译打包，不代表真机验收。
- 每词独立调用一次 `GET https://kenmusic.kdns.fr/api/v1/search?q=<关键词>&limit=50`，保留原数组顺序和每个逐词完整原始 JSON，不跨词去重；缺封面指 cover 缺失/null/空串；明确不可播仅严格 `playable == false`；null 不推断。响应/HTTP 错误单独计数。
- 初始阶段另对本机 MHub SQLite mirror 抽样10图，结果保留但明确非正式D1。后续补证已只读查询线上 D1 (mhub-db)：对原344 unique search catalog IDs、92 distinct empty-cover IDs 执行 SELECT；读回 metadata `changed_db=false`、`rows_written=0`。另固定抽 Spotify-liked playlist positions 0–9 的真实D1封面。
- API可取音频/HTTP206、图片下载、静态代码检查均不能冒充 iOS AVPlayer/SwiftUI/Spotify iOS真机表现；完整签名音频URL不落盘/不共享。

## 阶段门
1. [x] 读 `ios/REGRESSIONS.md`、项目任务/交付记录、相关生产代码；保留 build8 原计划和工作树既有脏文件。
2. [x] 确认基线：仓库 `D:/Projects/apu-music-ios`，`main` HEAD/origin/main = `6700764bf20af1445080083716a83d60b27200bb`；build8 package run `44891936200`、artifact `14702596685` 均对应 SHA `420e5bb3e7ba02ee60b06d835185bfb434a27f1d`，success。
3. [x] 对10个关键词实际 GET；按原数组次序逐词计数。原API空封面100行、明确`playable=false` 0行、同词重复(platform,id)0；100行CSV和逐词脱敏JSON保存。
4. [x] 对原快照344 unique ID只读join线上D1：360行全匹配且platform/source_id一致；origin=search 331、rematch 13。92 unique空封面行来源全部 origin=search，netease74/tencent16/kugou2。对92行逐一查现有D1 detail endpoint，92次HTTP200但cover仍空。
5. [x] 对真正线上Spotify曲库固定前10个D1行下载并解码：`supplement/d1-library-artwork-private.json`，全部300x300。旧本机mirror十图保留为分开样本。
6. [x] 对92 unique空封面行按build8请求参数实时查播放API，低并发2；61完成且Range 206、31后端failed（23 deadline timeout、4 QQ cookie风险、4无audio_url）；此非AVPlayer验证。基线/来源/层级/失败明细及平台能力见 `supplement/PHASE0-SUPPLEMENT.md`。
7. [x] 确认真实生产Swift XCTest本地执行阻塞：Windows及WSL无Swift/Xcode、云XCTest被禁。须Ken批准在本地Mac/Xcode跑，或授权本机安装standalone Swift toolchain测可移植生产逻辑；默认不安装、不跑CI，不改业务实现。
8. [ ] 等Lead转报并等待获准Swift测试环境/续派后，先直接执行生产Swift逻辑测试真红，再修复真绿；不得以脚本替代、删旧测试/跳测试/改断言。
9. [ ] 审核开发只读审核通过后按授权发布流程打包；精确记录CI SHA/IPA/来源与逐项对照。Ken真机验收与AVPlayer行为分开标注。

## build9 阶段进展（2026-11-28 07:50续派）
- Ken选项：无Mac/不安装Swift/不跑云端测试；Swift红绿豁免，审核开发逐行走查；允许Worker相关实现，以Node真实Worker/D1逻辑先红后绿。本机只跑该Worker Node测试；后端部署与线上补92空封面操作仍单独等Ken批准。
- 新分支 `fix/build9-artwork-playback` 已在两仓创建，开始新增Worker provider cover查找、D1空cover guarded update、尺寸URL helper与质量low retry。后端detail路径由live API与本地 provider源码证实：Netease `/api/v3/song/detail`、QQ `/cgi-bin/musicu.fcg` 的 `get_song_detail_yqq`、Kugou已用`getSongInfo.php?cmd=playInfo&hash`（该样本image字段仍空）。provider尺寸像素实测证据保存在MHub仓`implementation-evidence/provider-reference/`。尚未核实完整三来源640的可取像素，不能让helper把不可用url误报640。
- 新测试 `tests/build9-artwork.test.mjs`：先在真实Worker逻辑运行，provider详情/限定SQL/low-quality/retry-fallback用例原始失败，修复后更新响应schema与夹具。当前7/7新增测试通过；生产逻辑及既有测试 `npm test` 84/84全绿（完整日志见`C:/Users/kenzh/hark_tasks/mhub-cloud/implementation-evidence/build9-npm-test-final.log`）。此仅为MHub Worker Node测试；Swift改动因Ken豁免红绿，等审核逐行走查；无Xcode/IPA。
- 线上D1 `origin='search' AND cover空` 92行已READ-ONLY导出：`implementation-evidence/build9-original-92-backup.json` 92 unique ID，SHA256 `f078642fe769976598e5063a0ea8565d064ebc2c06d98d53c4c7654160890ea6`，wrangler meta `rows_written=0`。执行过本地provider detail只读，候选清单`build9-92-provider-cover-candidates.json`，92行中75实际有图(网易74/Kugou1)、17空(酷狗1/QQ16)。像素实际检查75张结果`build9-92-candidate-pixels.json`。脚本`build9-backfill-covers.mjs`强制匹配备份hash，拒绝任何备份外/非search/Spotify/nonempty row，产物`build9-backfill-dryrun-final.json`仅SQL计划、75 distinct updates only cover、source/id/source_id/origin/Spotify/cover-empty guard；`d1_write_performed=false`。计划尚不保证Ken批量补图批准，绝不执行。
- 已有两仓本地分支：`fix/build9-artwork-playback`；MHub仅改`src/index.js`,`src/search.js`,`src/sources.js`,`src/library.js`及`tests/build9-artwork.test.mjs`,`scripts/build9-backfill-covers.mjs`；未碰已脏`_work/`。iOS只改Models/ArtworkCache/ApuMusicApp/Player，共4源文件；构建号仍8，未编译。
- 2026-11-28 10:04续接最终本地阶段：Worker回归89/89通过（日志`C:/Users/kenzh/hark_tasks/mhub-cloud/implementation-evidence/build9-npm-test-final.log`），其中固定原始snapshot的同生产helper回放安全测试5/5通过（safety log），新封面/quality/source/fallback定向测试7/7通过。红灯原始历史`build9-feature-tests-red.log`需确认存在；未以当前红日志覆盖。测试验证包括signed URL原样保留、拒绝Kugou placeholder与javascript URL、row identity/非cover不变、并发cover更新空值guard。92行备份与执行SQL计划已双向sha/WHERE校验，计划75写仅改cover、17跳过，绝无执行。
- Pixel实际样本：网易source picture请求param64/300/640解码均分别64/300/640；QQ path120/300/800解码分别一致，640格式未图；Kugou单源模板变更目录参数仍解码480。Spotify CDN图片token替换同id实测300默认与0000b273=640/00004851=64。不能将URL请求Tier误报为每首供应源都达标。IPA受限于hosting、尚未build。
- Swift本次豁免测试，无Swift compiler；文件`Models.swift/ArtworkCache.swift/ApuMusicApp.swift/Player.swift/PlaybackResolver.swift`只纳入审核逐行走查/获准package-only编译，未声称iOS通过。build号仍8。
- **部署闸：**目前Worker候选源码包括`src/search.js`（网易/QQ/Kugou详情reader、负缓存、strict title/artist两源封面匹配、搜索层输出、固定快照helper与仅cover受guard回写）、`src/index.js`（`GET /api/v1/tracks/{platform}/{id}?refresh_cover=1&artwork_size=<small|medium|large>`、playback URL错误分类），`src/sources.js`（上游高->低质量重试）、`src/library.js`（非playable状态标志）；新增`tests/build9-artwork.test.mjs`,`tests/build9-safety.test.mjs`,`scripts/build9-backfill-covers.mjs`。D1唯一预期写路径是SQL `UPDATE tracks SET cover=? WHERE id=? AND source=? AND source_id=? AND origin='search' AND spotify_id='' AND (cover IS NULL OR cover='')`；搜索页与GET detail会在请求内通过这个守卫惰性回填cover。一次性92备份计划75行同guard，仍未运行。以上部署会带入实时外部provider详情/搜索读及D1空cover写入，即使不一次性刷库也会写少量空封面行；需Lead先请Ken就上述部署及惰性写路径明确许可。未授权前不部署/更新Workers，未授权的一次性92回填也不执行。
- 代码审阅必须针对最终变更/branch；审核开发线程尚未创建，开发须到获部署许可并review-ready时按原审核ID直送。本地package-only与IPA还未请求/运行。
- 下一步：已具备本地Node生产Worker绿灯及全套回归、D1写计划干跑及实像素候选；阶段阶段实现未commit。现在将精确接口和写路径回报Lead等部署审批；另复核90?（当前92ID唯一）覆盖数据固定样本输出同快照比较。获准后完成部署分支本地审查清理、只执行用户授权的D1脚本、对同快照验收，最终再送审核，package-only构建build9。严格不要启动测试CI。

---

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
