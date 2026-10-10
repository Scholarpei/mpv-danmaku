<div align="center">

# mpv-danmaku

**刷屏弹幕自动合并 ×N · 弹幕密度自动控制 · B站合集一次配置全季生效**

基于 [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) v2.2.0 的个人增强分支

[![License](https://img.shields.io/badge/license-MIT-informational?style=flat-square)](LICENSE)
[![Base](https://img.shields.io/badge/base-uosc__danmaku%20v2.2.0-blueviolet?style=flat-square)](https://github.com/Tony15246/uosc_danmaku)
[![Algorithm](https://img.shields.io/badge/%E7%AE%97%E6%B3%95%E5%8F%82%E8%80%83-pakku.js-orange?style=flat-square)](https://github.com/xmcp/pakku.js)
[![UI](https://img.shields.io/badge/UI-uosc-2ea043?style=flat-square)](https://github.com/tomasklaen/uosc)
[![Danmaku](https://img.shields.io/badge/%E5%BC%B9%E5%B9%95-%E5%BC%B9%E5%BC%B9play-00ADD8?style=flat-square)](https://www.dandanplay.com/)

</div>

---

原版 uosc_danmaku 解决了「**在 mpv 里加载弹幕**」；本分支在此基础上继续解决两个问题：

- **弹幕太多太重复怎么办** → 移植 [pakku.js](https://github.com/xmcp/pakku.js) 的相似度合并引擎与智能密度控制
- **B站多分P合集每集都要贴一遍链接** → 文件夹级合集记忆，粘贴一次，全季自动匹配分P

所有增强**默认开启、开箱即用**，同时提供 uosc「弹幕过滤」菜单在播放中随时调整。

> [!NOTE]
> 插件默认通过项目维护的 API 代理 `https://danmaku-api.152468.xyz` 访问弹弹play开放弹幕网络，普通用户无需注册账号、无需配置 AppId/AppSecret。代理包含缓存和访问频率限制，请勿用于批量抓取。

## 目录

| | |
|---|---|
| [特色功能](#特色功能) · [与上游的关系](#与上游的关系) | [快速上手](#快速上手) · [新增配置项速查](#新增配置项速查) |
| [运行时菜单与脚本消息](#运行时菜单与脚本消息) | [测试](#测试) · [致谢](#致谢) |

---

## 特色功能

| 🔀 [pakku 式弹幕合并](#pakku-式弹幕合并) | 📉 [智能密度控制](#智能密度控制) |
|---|---|
| 四通道相似度合并，重复刷屏收拢为一条 **×N** | 弹幕过密先自动缩小字号，仍超限才按权重丢弃 |
| 📺 [B站合集弹幕记忆](#b站合集弹幕记忆) | 🎛️ [弹幕过滤菜单](#弹幕过滤菜单) |
| 文件夹内粘贴一次B站链接，全季自动匹配分P | 合并 / 密度 / 简繁 / 黑名单播放中实时调节 |
| 🔍 [更多弹幕源搜索](#更多弹幕源搜索) | 🖥️ [自建弹幕服务器](#自建弹幕服务器danmu-api-兼容) |
| 直接搜索并发全部来源、结果按源分组，`\|tx`/`\|yk`/`\|mg` 等后缀只搜单源 | danmu-api 兼容服务一行配置接入 |

### pakku 式弹幕合并

时间窗口内语义重复的弹幕合并为一条，以 **×N** 显示数量，字号随合并数对数放大——弹幕墙变成一条醒目的大字，而不是 20 条一模一样的小字：

```text
合并前    哈哈哈哈      哈哈哈哈      哈哈哈哈      哈哈哈哈哈
合并后    哈哈哈哈 ×5
```

四条相似度通道，命中任一即合并：

| 通道 | 捕捉场景 | 示例 |
| --- | --- | --- |
| 归一化后完全相同 | 忽略末尾标点、多余空格、全半角差异 | 「太好看了」vs「太好看了！！」 |
| 字符多重集距离 | 重复字符长短不一 | 「哈哈哈哈」vs「哈哈哈哈哈」 |
| 拼音谐音距离 | 同音错别字刷屏 | 「泪目」vs「累目」 |
| 环形二元组余弦 | 同一句话的长短变体 | 任意长度的「2333…」刷屏 |

- 相似度强度四档（[`merge_similarity`](#merge_similarity)）：`off` / `light` / `medium`（默认，对齐 pakku 官方阈值）/ `strong`
- 「2333」「6666」类刷屏可由 [`merge_forcelist`](#merge_forcelist) 规则归一后再合并
- 简繁转换发生在合并**之前**：繁简互为变体的弹幕（「淚目」vs「泪目」）转换后同文，走精确通道稳定合并，不依赖拼音字典恰好覆盖两种字形
- 合并发生在黑名单与密度控制**之前**，×N 计数基于原始弹幕量，屏蔽词不缩水计数
- 加载完成 OSD 提示合并统计：「已合并 N 条相似弹幕（A→B）」
- 拼音谐音通道依赖 `dicts/pinyin_chars.lua`（GB2312 共 6763 字）与补充表 `dicts/pinyin_chars_ext.lua`（GBK 扩展共 14131 字，覆盖咲、凪、雫等日式汉字与繁体字），均由 [pinyin-data](https://github.com/mozillazg/pinyin-data) 生成（`tools/gen_pinyin_dict.py`）；主字典缺失时该通道自动禁用，补充表删除仅收窄覆盖面，其余通道不受影响

### 智能密度控制

弹幕太密时不直接删除，而是 pakku 的两段式策略——**先变小，再消失**：

```text
视觉密度 dispval 超过软阈值 ──→ 等比缩小当条字号（最多缩到 1/√3）
        │
        ▼ 仍超过硬阈值（恒为软阈值的 2 倍）
按概率丢弃：未合并弹幕没有任何保护（先死）
           ×N 合并弹幕受双重保护：合并数 (√N−1)/5 + 全片权重排名（最多再减 0.25）
```

- 视觉密度值综合文本长度与字号，按每条弹幕**真实显示区间**（滚动 `scrolltime` 秒、固定 `fixtime` 秒）滑动窗口累计
- 强度三档（[`density_level`](#density_level)）：`loose`（80/160）/ `medium`（默认，50/100）/ `strict`（30/60）
- 上游原有的「同屏上限 + 随机丢弃」（B站播放器行为）保留为 `simple` 简单模式，`off` 完全关闭
- 加载完成 OSD 提示干预统计：「智能密度：缩小 N 条，丢弃 M 条」

### B站合集弹幕记忆

追B站多分P合集（多季混排、剧场版夹杂的投稿）不用每集贴一次链接：

```text
第 1 集播放时粘贴一次 https://www.bilibili.com/video/BVxxxx
        │
        ▼ 记入文件夹级记忆（每文件夹最多 3 个视频，按最近使用淘汰）
        │
播放同文件夹任意一集 ──→ 自动匹配对应分P并加载弹幕
```

匹配链按优先级仲裁，任一环节失败都不影响其他弹幕源加载：

| 环节 | 规则 |
| --- | --- |
| ① 分P标题打分 | 解析分P标题中的季/集（`【S3】09`、`第9话`、`24（OVA）`…）与本地文件名比对；显式季与本地季矛盾直接排除；特殊篇（OVA/PV/番外…）降权 |
| ② 时长校验 | 分P时长与本地时长差 ≤120s 加分、>300s 减分，平局时时长裁定；锚点差值落点有 600s 硬门（容纳 BD/WEB 剪辑差异） |
| ③ 集数差锚点 | 以最近一次匹配到的（分P页号, 当时集数）为锚，按集数差推算页号仲裁歧义——应对本地文件名解析不出季数、或合集投稿把多季混排的情况；落点编号按「锚点处分P编号 ↔ 本地集数」的相对偏移校验，两季合并合集（分P按合集内序号、本地文件按全局集数，或反之）亦能对上 |

- 三种模式（[`bilibili_series_memory`](#bilibili_series_memory)）：`off` 关闭 / `add`（默认，与弹弹play弹幕叠加）/ `first`（B站优先，匹配失败自动回退弹弹play）
- 各B站源的延迟与屏蔽状态写入记忆，跨集自动继承
- 在「从源获取弹幕」菜单中删除B站源时自动清除对应记忆；也可绑定快捷键一键清除（[`clear-bilibili-record`](#运行时菜单与脚本消息)）
- 仅支持普通投稿（BV/av 链接）；番剧 `ep`、课程 `cheese` 链接与 `b23.tv` 短链仍按单集添加，不进入记忆
- 与上游 `auto_load` 同理，要求一个文件夹内只有同一部番剧

### 弹幕过滤菜单

新增的 uosc 子菜单（也可从弹幕设置总菜单进入），播放中随时调整、立即生效，无需改配置重启：

| 菜单项 | 可调值 | 对应配置 |
| --- | --- | --- |
| 弹幕合并 | 开 / 关 | `merge_enabled` |
| 合并时间窗口 | 5 / 10 / 20 / 30 / 60 / 120 秒 | `merge_tolerance` |
| 拼音谐音合并 | 开 / 关 | `merge_pinyin` |
| 相似度强度 | 禁用 / 轻微 / 中等 / 强力 | `merge_similarity` |
| 简繁转换 | 不转换 / 简体 / 繁体 | `chConvert` |
| 顶部弹幕转滚动 | 关 / 全部 / 自动按宽度 | `convert_top_to_scroll` |
| 底部弹幕转滚动 | 关 / 全部 / 自动按宽度 | `convert_bottom_to_scroll` |
| 转换宽度阈值 | 800 ~ 2400 px | `scroll_threshold` |
| 密度控制 | 关闭 / 简单 / 智能 | `density_control` |
| 智能密度强度 | 宽松 / 中等 / 严格 | `density_level` |
| 同屏弹幕上限 | 不限 / 20 ~ 100 | `max_screen_danmaku` |
| 黑名单过滤 | 开 / 关 | `blacklist_enabled` |
| 重载黑名单 / 打开文件位置 | 动作 | `blacklist_path` |

> [!TIP]
> 菜单中的调整仅本次播放生效（与样式菜单一致），长期方案请写入 `uosc_danmaku.conf`。

### 更多弹幕源搜索

弹幕搜索菜单（默认 `Ctrl+d`）**直接输入关键词即聚合搜索全部来源**（弹弹play 全部 `api_server` + 腾讯 + 优酷 + 芒果 + B站 + 巴哈姆特 + animeko + 埋堆堆 + 360kan，配置了 `maccms_servers` 再加采集站），结果按来源分组展示、一眼区分不同站；追加 `|` 后缀则只搜单一来源（复刻自 [danmaku-anywhere](https://github.com/Mr-Quin/danmaku-anywhere) 的源实现）：

| 后缀 | 搜索源 | 说明 |
| --- | --- | --- |
| （无） | 全源聚合 | 并发搜上述全部来源，按源分组显示；空结果的组隐藏、失败的组显示错误行，整体 10s 到点齐展示 |
| `\|ds` / `\|dy` / `\|dm` | 360kan 聚合 | 电视剧 / 电影 / 国漫，覆盖爱腾优芒B站源 |
| `\|tx` 🆕 | 腾讯视频 | 腾讯公开搜索接口直连，搜剧 → 选集一步到位 |
| `\|yk` 🆕 | 优酷 | 优酷版权内容直连（站外版权条目自动过滤），分集带原生正片判定（花絮/预告剔除） |
| `\|mg` 🆕 | 芒果TV | 芒果直连，综艺按月分页并发、预告与衍生内容（花絮/彩蛋/纯享等）剔除 |
| `\|bili` 🆕 | B站 番剧 | WBI 签名搜索（番剧 + 影视两路），PGC 分集仅列正片；弹幕密度高的首选补充源 |
| `\|baha` 🆕 | 巴哈姆特动画疯 | 台湾繁体番剧弹幕（关键词自动简→繁，分集按巴哈原始话数编号）；**分集接口对大陆直连按时段性开窗**——失败自动重试 3 次，撞上关闭窗口时菜单提示稍后重试（过几分钟通常可进），稳定使用需在 `proxy` 配置台湾/香港节点 |
| `\|ako` 🆕 | animeko | [open-ani](https://github.com/open-ani/animeko) 社区番剧弹幕（Bangumi 元数据），与弹弹play弹幕池互补；多节点自动降级 |
| `\|mdd` 🆕 | 埋堆堆 | TVB 港剧粤语弹幕（固定私钥签名直连），粤语/国语版本分列 |
| `\|mac` 🆕 | MacCMS 采集站 | 搜索采集站收录内容（需配置 [`maccms_servers`](#弹幕源搜索)） |

- 聚合与非 dandanplay 源的条目选中后，弹幕获取自动走现有管线：先尝试各 `api_server` 的 extcomment，失败回退域名直连（腾讯条目即直连腾讯弹幕接口），最后由 `fallback_server`（dmku / danmu.icu 协议）兜底；animeko / 埋堆堆这类弹弹play 不支持的域名会跳过 extcomment 直接直连，不浪费等待；加载后的源在「弹幕源管理」里显示真实提供方（腾讯视频 / 优酷 / maccms·某站 / 360kan·B站 等）而非笼统的「用户添加」
- **换集自动续载（多源并行）**：选过的剧记入文件夹历史——各直连源各记一条（`extras` 表，同源覆盖）、dandanplay 的集数记录独立保留，互不挤占；同文件夹播放下一集时**全部源一起按集数差自动定位续载**（如 dandanplay + 腾讯 + animeko 同时恢复），旧格式单 `extra` 记录自动迁移
- `|tx` 顺手修复了腾讯弹幕颜色恒为白色的问题：接口的 `content_style` 实为字符串化 JSON，渐变弹幕取首色呈现
- `|yk` 顺带给 `sites/youku.lua` 补了 cna 本地生成兜底：优酷弹幕接口不校验 cna 来源，`log.mmstat.com` 被广告 DNS 拦截时不再整源失败
- `|mac` 的采集站地址需自备：在资源站导航 / 站点首页找到形如 `https://caiji.example.com` 的站点根地址填入 `maccms_servers`，脚本自动请求其 `/api.php/provide/vod/` 标准采集接口（MacCMS10 格式）；多站逗号分隔，并发搜索、结果按站点标注；多播放来源组会先出「播放来源」菜单再列集
- **采集站选站注意**：本源的弹幕取自剧集链接对应的平台播放页，公开采集站大多只提供自托管 m3u8 链接（选集后会提示「未获取到任何弹幕」，兜底服务明确不支持 m3u8），因此适合 `vod_play_url` 中带平台播放页链接（`v.qq.com` 等）的站点——常见于自建影视站。验证方法：浏览器打开 `{站根}/api.php/provide/vod/?ac=detail&wd=测试词`，查看返回 JSON 里 `vod_play_url` 是否含平台域名

### 自建弹幕服务器（danmu-api 兼容）

[danmu-api](https://github.com/huangxd-/danmu_api) 聚合爱腾优芒B站等平台弹幕、兼容弹弹play API 规范，本脚本可将其直接作为 `api_server` 使用，零额外代码配置：

```ini
# 先部署服务（Docker 示例，默认端口 9321、默认 token 87654321）：
#   docker run -d -p 9321:9321 logvar/danmu-api:latest
# 再把地址填进 api_server 即可：
api_server=http://192.168.1.5:9321
```

- 端点兼容 `/api/v2/search/anime`、`/api/v2/match`、`/api/v2/bangumi`、`/api/v2/comment/{id}`、`/api/v2/extcomment`——本脚本的哈希匹配 / 搜索匹配 / URL 取弹幕全流程可用
- **token 是 URL 路径前缀**：服务端自定义 token 后填 `api_server=http://host:9321/你的token`（默认 token 可省略），URL 拼接方式天然兼容
- 对 `api.dandanplay.net` 的 AppId/Signature 签名头只按域名自动附加，第三方服务器自动免签
- 可与其它服务器逗号分隔混排、`|` / `#` 追加备注，多服务器并发先到先用
- 其 XML 输出为B站格式（本脚本默认请求 JSON，不受影响）

### 其它增强

- **黑名单 2.0**：在合并**之后**按簇过滤——只有簇的显示文本命中规则才整簇丢弃，个别成员含屏蔽词但显示文本干净的簇保留完整 ×N 计数；实际过滤时 OSD 提示「黑名单：过滤 N 条」；支持菜单热重载与一键打开文件位置；`blacklist_path` 相对路径解析失败时自动回退到脚本目录（把 `black.txt` 放脚本目录、从任意位置启动 mpv 都能找到），conf 中带引号的路径值亦兼容
- **屏蔽此文本**：「弹幕内容」菜单逐条动作——把选中弹幕（含合并簇显示文本，剥离引擎 ×N 后缀）按整行字面匹配自动转义写入黑名单并热重载，重复屏蔽会提示且不重复写入；内容菜单同时显示合并簇的 ×N 数量，菜单动作按弹幕原始位置精确索引（过滤后不漂移）
- **固定弹幕转滚动**：顶部/底部弹幕可转换为滚动弹幕并加 `↑`/`↓` 前缀（pakku 惯例）；`auto` 模式只转宽度超过阈值的，短弹幕保留原样
- **×N 字号对数增长**：合并数量越多字号越大，但增量递减，并受上限约束——`min(merge_fontsize_max, fontsize + round(merge_fontsize_growth × ln N))`
- **简繁转换运行时切换**：弹幕文本默认转简体显示，可在过滤菜单三态切换；转换在收集阶段进行（合并与黑名单均作用于转换后文本，黑名单规则按屏幕显示的文字书写即可命中）；导出 XML 仍保留原文（源数据不参与转换）
- **弹幕磁盘缓存**：网络弹幕按 episodeId/cid 落盘（[`danmaku_cache_*`](#danmaku_cache)），TTL 内二刷不发网络包秒加载、断网自动用过期缓存兜底；容量超限按最旧淘汰，总菜单可一键清空

---

## 与上游的关系

本分支基于 [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) v2.2.0（MIT），上游是一个成熟维护的 mpv 弹幕插件：基于 uosc UI 框架与弹弹play API，提供弹幕搜索加载、全自动弹幕填装、文件哈希匹配、网络播放自动加载、弹幕源管理与样式实时调节等完整功能，并自带免密钥的 API 代理。**这些功能本分支全部继承**，上游的安装教程、常见问题与完整配置文档也请移步[上游 README](https://github.com/Tony15246/uosc_danmaku#readme)。

| 能力 | 上游 uosc_danmaku | 本分支 |
| --- | :---: | :---: |
| 弹幕搜索 / 加载 / 记忆 / 哈希匹配 / URL 自动加载 | ✅ | ✅ 全部继承 |
| 搜索来源 | 仅弹弹play | 🔍 多源并发聚合（腾讯/优酷/芒果/B站/巴哈/animeko/埋堆堆/360kan/采集站），结果按源分组、加载后源管理标注真实提供方 |
| 重复弹幕 | 仅同文本精确合并 | 🔀 pakku 四通道相似度合并 ×N |
| 弹幕过密 | 同屏上限 + 随机丢弃 | 📉 先缩字号再按权重丢弃，×N 双重保护 |
| B站多分P合集 | 每集手动粘贴链接 | 📺 文件夹记忆自动匹配分P |
| 黑名单 | 配置文件开关 | 🧩 按簇过滤 + 热重载 + 打开位置 + 路径回退 |
| 固定弹幕遮挡 | — | ↕️ 顶/底转滚动（可按宽度自动） |
| 弹幕磁盘缓存 | — | 💾 按 episodeId/cid 带 TTL 落盘，二刷秒加载、断网可看 |
| 运行时调节 | 样式 / 延迟菜单 | ➕ 弹幕过滤菜单（合并/密度/简繁/黑名单） |
| 测试 | — | 🧪 单测 + 端到端 + 菜单 handler + 压测 |

<details>
<summary><b>继承自上游的功能一览（点击展开）</b></summary>

- 弹幕搜索与选集加载：搜索弹弹play 剧库并按集数加载弹幕，uosc 菜单交互
- 全自动弹幕填装（`auto_load`）：文件夹内加载过一集，其余集数自动匹配
- 文件哈希匹配：本地/网络文件按哈希自动关联弹幕（需 mpv 基于 LuaJIT 或 Lua 5.2 构建）
- URL 播放自动加载（`autoload_for_url`）：bilibili / 巴哈姆特在线播放自动加载弹幕，兼容 embyToLocalPlayer、tsukimi 等场景
- 弹幕源管理：从网络 URL（B站/巴哈等）或本地文件（xml/ass）添加弹幕，可视化增删、屏蔽、独立延迟
- 弹幕样式实时修改、弹幕保存为本地 XML、简繁转换、脚本自动更新检查
- uosc 不可用时回退 mpv 内置 `mp.input` 渲染菜单（需 mpv ≥ 0.39.0）

</details>

> [!WARNING]
> 从上游旧版本迁移的用户：本分支移除了旧的精确合并与 `merge_without_style` 选项（其 `yes` 行为已成为 `merge_cross_mode` 的默认值），conf 中残留的该键会被自动忽略，直接使用即可。

---

## 快速上手

### 1. 安装

将本仓库完整克隆或下载到 mpv 配置目录的 `scripts` 文件夹下：

```bash
# Linux / macOS
git clone https://github.com/Scholarpei/mpv-danmaku.git ~/.config/mpv/scripts/uosc_danmaku
```

```powershell
# Windows（全局配置）；便携配置为 mpv.exe 同目录 portable_config/scripts/uosc_danmaku
git clone https://github.com/Scholarpei/mpv-danmaku.git "$env:APPDATA/mpv/scripts/uosc_danmaku"
```

> [!IMPORTANT]
> 1. `scripts` 下放置本插件的文件夹名称必须为 `uosc_danmaku`，否则需按[上游文档](https://github.com/Tony15246/uosc_danmaku#readme)修改 uosc 控件中的脚本名
> 2. 本分支依赖 [uosc](https://github.com/tomasklaen/uosc) UI 框架，推荐随 [MPV_lazy](https://github.com/hooke007/MPV_lazy) 懒人包一起使用

### 2. 添加 uosc 控件（推荐）

编辑 `script-opts/uosc.conf` 的 `controls`，插入 `button:` 控件：

```
controls=menu,gap,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,button:danmaku,button:danmaku_source,button:danmaku_styles,button:danmaku_delay,button:danmaku_menu,cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

| 控件 | 功能 |
| --- | --- |
| `button:danmaku` | 弹幕搜索 |
| `button:danmaku_source` | 从源添加弹幕（网络 URL / 本地文件） |
| `button:danmaku_styles` | 弹幕样式实时修改 |
| `button:danmaku_delay` | 弹幕源延迟设置 |
| `button:danmaku_menu` | 弹幕设置总菜单（内含弹幕过滤菜单） |
| `cycle:toggle_on:show_danmaku@…?弹幕开关` | 弹幕开关 |

<details>
<summary>旧版 uosc 的控件写法</summary>

旧版 uosc 不支持 `button:` 控件，请改用 `command:` 形式：

```
command:search:script-message open_search_danmaku_menu?搜索弹幕
command:add_box:script-message open_add_source_menu?从源添加弹幕
command:palette:script-message open_danmaku_style_menu?弹幕样式
command:more_time:script-message open_source_delay_menu?弹幕源延迟设置
command:grid_view:script-message open_add_total_menu?弹幕设置
```

</details>

### 3. 完事，直接播放

合并与密度控制默认开启，无需任何配置即可体验。以下是可选的推荐配置，写入 `script-opts/uosc_danmaku.conf`：

```ini
# —— 本分支增强（均已有合理默认值，按口味调整）——
merge_similarity=medium        # 相似度强度：off / light / medium / strong
density_level=medium           # 智能密度强度：loose / medium / strict
bilibili_series_memory=add     # B站合集记忆：off / add / first
chConvert=1                    # 弹幕统一转简体：0 不转 / 1 简体 / 2 繁体
danmaku_cache_ttl_days=7       # 弹幕磁盘缓存有效期（天），0 永不过期

# —— 常用上游功能 ——
auto_load=yes                  # 全自动弹幕填装（文件夹内加载一集，其余自动匹配）
```

---

## 新增配置项速查

在 `script-opts/uosc_danmaku.conf` 中配置。**加粗项为本分支新增**，其余为上游既有选项；上游全部选项（API 服务器、代理、样式、保存路径等）见[上游 README](https://github.com/Tony15246/uosc_danmaku#readme)。

### pakku 合并

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`merge_enabled`** | `yes` | 合并总开关 |
| **`merge_tolerance`** | `30` | 合并时间窗口（秒），`0` 禁用 |
| **`merge_similarity`** | `medium` | 相似度强度四档，见下表 |
| **`merge_pinyin`** | `yes` | 拼音谐音通道（依赖 `dicts/` 字典） |
| **`merge_cross_mode`** | `yes` | 跨位置类型合并，合并后按「底 > 顶 > 滚」提升显示模式 |
| **`merge_forcelist`** | `^2333+=>23333\|^666+=>66666` | 合并前套路规则重写，`|` 分隔多条 |
| **`merge_fontsize_growth`** | `8` | ×N 字号对数增长速率（正整数） |
| **`merge_fontsize_max`** | `100` | ×N 字号上限 |

### 密度控制

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`density_control`** | `smart` | `off` / `simple`（同屏上限随机丢弃）/ `smart`（pakku 式） |
| **`density_level`** | `medium` | 智能模式强度三档，见下表 |
| `max_screen_danmaku` | `0` | 同屏弹幕上限，**仅 `simple` 模式生效** |

### B站合集记忆

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`bilibili_series_memory`** | `add` | `off` / `add` / `first`，详见下方说明 |

### 弹幕磁盘缓存

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`danmaku_cache_enabled`** | `yes` | 缓存总开关，详见下方说明 |
| **`danmaku_cache_path`** | `~~/danmaku-cache` | 缓存目录（`~~/` 为 mpv 配置目录），不存在时自动创建 |
| **`danmaku_cache_ttl_days`** | `7` | 有效期（天），`0` 永不过期；过期正常走网络刷新 |
| **`danmaku_cache_max_mb`** | `300` | 容量上限（MB），超出按最旧优先淘汰，`0` 不限制 |

### 显示与过滤

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`convert_top_to_scroll`** | `no` | 顶部弹幕转滚动：`no` / `yes`（全部）/ `auto`（按宽度） |
| **`convert_bottom_to_scroll`** | `no` | 底部弹幕转滚动，同上，与顶部独立 |
| **`scroll_threshold`** | `1200` | `auto` 模式宽度阈值（px），按一个汉字≈一个字号估算 |
| **`blacklist_enabled`** | `yes` | 黑名单开关 |
| `blacklist_path` | 空 | 屏蔽词文件路径，每行一条 Lua 正则；相对路径解析失败自动回退脚本目录 |
| `chConvert` | `1` | 简繁转换：`0` 不转 / `1` 转简体 / `2` 转繁体 |

### 弹幕源搜索

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| **`maccms_servers`** | 空 | MacCMS 采集站根地址（`|mac` 搜索源），多个逗号分隔、支持 `\|` / `#` 备注；仅需填站点根地址（如 `https://caiji.example.com`），脚本自动拼接标准采集接口，详见[更多弹幕源搜索](#更多弹幕源搜索) |

<a id="merge_similarity"></a><a id="density_level"></a>
<details>
<summary><b>选项详解：merge_similarity / density_level 档位表</b></summary>

**`merge_similarity`** —— 映射合并引擎内部的字符多重集距离阈值（max_dist）与二元组余弦阈值（max_cosine）：

| 档位 | max_dist | max_cosine | 效果 |
| --- | --- | --- | --- |
| `off` | — | — | 禁用相似通道（完全相同的也不再合并） |
| `light` | 2 | 60 | 只合并几乎相同的弹幕 |
| `medium` | 5 | 45 | 默认档，等于 pakku 官方默认阈值 |
| `strong` | 10 | 35 | 激进合并，弹幕总量明显减少，可能误伤 |

**`density_level`** —— 映射智能模式的（收缩阈值, 丢弃阈值）两个 dispval 值：

| 档位 | 收缩阈值 | 丢弃阈值 | 效果 |
| --- | --- | --- | --- |
| `loose` | 80 | 160 | 仅极端弹幕墙干预 |
| `medium` | 50 | 100 | 默认档，舒适满屏即开始收缩 |
| `strict` | 30 | 60 | 约 2/3 满屏即干预，弹幕显著减少 |

标定基准：1080p、`displayarea=0.85` 下约 18 行 50px 弹幕带，一条 10 字弹幕 dispval≈√10≈3.2，舒适满屏 ≈58，故 `medium=50` 恰在舒适满屏触发收缩。档位对 `fontsize` 修改不敏感（基准同步缩放）。

</details>

<a id="merge_forcelist"></a>
<details>
<summary><b>选项详解：merge_forcelist 套路规则语法</b></summary>

在参与合并比较之前，先把匹配规则的弹幕文本统一改写，解决同一刷屏文本长短不一难以合并的问题。多条规则用 `|` 分隔，每条为 `pattern=>replacement`，pattern 使用 **Lua pattern** 语法（不是正则），顺序应用、命中后继续套用后续规则：

```ini
merge_forcelist=^2333+=>23333|^666+=>66666
```

改写只影响合并比较与合并后的显示文本，未被合并的单条弹幕仍显示原文。

</details>

<a id="bilibili_series_memory"></a>
<details>
<summary><b>选项详解：bilibili_series_memory 三种模式与限制</b></summary>

| 模式 | 行为 |
| --- | --- |
| `off` | 关闭文件夹记忆（手动添加的B站源仍按原逻辑只作用于当前集） |
| `add`（默认） | B站弹幕与自动填装 / 哈希匹配的弹幕**叠加加载**，与逐集手动粘贴行为一致 |
| `first` | B站匹配成功时本次不再进行弹弹play自动匹配（失败自动回退） |

补充行为：

- 匹配失败时 OSD 提示「B站分P未匹配」并跳过该层，不影响其他弹幕源加载
- 分P编号体系与本地集数体系允许差常量偏移（合并多季合集：分P按合集内序号、本地按全局集数，或反之），偏移由锚点推算，切换各集自动跟随
- 合并多季合集建议粘贴带 `?p=` 的链接建立锚点：裸链接若恰好匹配到另一季的同号分P，会记下错位锚点（重贴带 `?p=` 的链接或清除记忆即可纠正）
- 裸链接（不带 `?p=` 参数）匹配失败时按B站惯例记「p1 ↔ 第1集」锚点，不会把锚点带偏到粘贴时的当前集
- 番剧 `ep` 链接、课程 `cheese` 链接、`b23.tv` 短链不支持文件夹记忆（仍可为当前集添加）
- 要求一个文件夹下只有同一部番剧，与 `auto_load` 同理

</details>

<a id="danmaku_cache"></a>
<details>
<summary><b>选项详解：弹幕磁盘缓存</b></summary>

网络拉取的弹幕按 **episodeId**（弹弹play 库）/ **cid**（B站）落盘缓存（`~~/danmaku-cache/` 下 `ep_*.dcache` / `cid_*.dcache`，单文件 = 首行 JSON 元信息 + 原始载荷）：

- **二刷秒加载**：TTL 内再次播放同一集直接读盘，不发任何网络请求（OSD 标注「弹幕加载成功（缓存）」）
- **断网可看**：网络请求失败时自动回退使用过期缓存（OSD 标注「（离线缓存）」）
- 过期条目不删除，正常走网络刷新，成功后覆盖并重置时间戳；空弹幕（count==0）不缓存
- **离线覆盖范围**：弹弹play 路径下，只要 `danmaku-history.json` 有该文件夹的 episodeId 记录（加载过一次即有），即可完全离线秒载；B站 URL 在线播放时 **cid 解析本身仍需一次网络**（pagelist/season API 无缓存），断网命中仅覆盖外挂弹幕轨（文件名 `数字-.xml`）、`--cid=传参` 与 URL 内嵌 cid 三种情形
- episodeId 是 dandanplay 全局库 ID，多个兼容服务器共享同一缓存（缓存不区分来源服务器）
- 多个 mpv 实例并发写同一缓存目录时与 history JSON 同为非原子直写，最坏情况单条缓存损坏 → 自动视为未命中走网络
- 缓存目录创建/写入失败时静默退化为不缓存，不影响正常播放；菜单「清空弹幕缓存」（或脚本消息 [`clear-danmaku-cache`](#运行时菜单与脚本消息)）一键清空

</details>

---

## 运行时菜单与脚本消息

除 uosc 控件外，所有功能都可通过 `input.conf` 绑定脚本消息调用。默认键位：<kbd>Ctrl</kbd>+<kbd>d</kbd> 弹幕搜索，<kbd>j</kbd> 弹幕开关（可在 conf 中用 `open_search_danmaku_menu_key` / `show_danmaku_keyboard_key` 修改）。

| 脚本消息 | 功能 |
| --- | --- |
| `open_search_danmaku_menu` | 弹幕搜索 |
| `show_danmaku_keyboard` | 弹幕开关 |
| `open_add_source_menu` | 从源添加弹幕（网络 URL / 本地 xml·ass 文件） |
| `open_filter_danmaku_menu` | 🆕 弹幕过滤菜单 |
| `open_danmaku_style_menu` | 弹幕样式菜单 |
| `open_source_delay_menu` | 弹幕源延迟菜单 |
| `open_add_total_menu` | 弹幕设置总菜单 |
| `clear-bilibili-record` | 🆕 清除当前文件夹的B站弹幕记忆 |
| `clear-danmaku-cache` | 🆕 清空弹幕磁盘缓存（总菜单亦有入口） |
| `clear-source` | 清空当前视频手动添加的弹幕源 |
| `immediately_save_danmaku` | 保存当前弹幕为 XML |
| `check-update` | 检查脚本更新 |
| `danmaku-delay <秒> [时间点]` | 叠加调整弹幕延迟，`0` 重置 |

> [!TIP]
> 可读写 `user-data/uosc_danmaku/` 下的属性与其他脚本联动：`danmaku-delay`（当前延迟）、`has-danmaku`（是否有弹幕显示）、`danmaku-switch-on`（开关状态）、`danmaku-count`（弹幕池总数）。

---

## 测试

本分支为全部新增模块配备了自断言测试，在仓库根目录用 mpv 运行即可（输出含 `FAIL` 或退出码非 0 即失败）：

| 测试 | 覆盖内容 | 运行 |
| --- | --- | --- |
| `tests/pakku_merge_test.lua` | 合并引擎四通道、归一化、×N、forcelist | `mpv.com --idle=once --no-config --script=tests/pakku_merge_test.lua` |
| `tests/pakku_density_test.lua` | dispval、先缩后丢、×N 保护 | `mpv.com --idle=once --no-config --script=tests/pakku_density_test.lua` |
| `tests/bilibili_match_test.lua` | 分P标题解析、匹配打分、锚点仲裁 | `mpv.com --idle=once --no-config --script=tests/bilibili_match_test.lua` |
| `tests/e2e_pipeline_test.lua` | 模式转换→合并→黑名单→密度→布局全管线 | `mpv.com --idle=once --no-config --script=tests/e2e_pipeline_test.lua --script-opts=e2e_pipeline_test-blacklist_path=tests/black_e2e.txt` |
| `tests/menu_handler_test.lua` | 过滤菜单各项回调 | `mpv.com --idle=once --no-config --script=tests/menu_handler_test.lua` |
| `tests/danmaku_cache_test.lua` | 缓存读写/TTL/断网兜底/容量淘汰（B站路径的缓存读写由本测试覆盖） | `mpv.com --idle=once --no-config --script=tests/danmaku_cache_test.lua` |
| `tests/danmaku_cache_fetch_test.lua` | 弹弹play 拉取链路缓存命中不发网络（B站下载函数为模块内局部，由单测+手动场景覆盖） | `mpv.com --idle=once --no-config --script=tests/danmaku_cache_fetch_test.lua` |
| `tests/tencent_parse_test.lua` | 🆕 腾讯搜索/剧集/弹幕条目解析（MainNeed 优先、预告过滤、content_style 字符串化 JSON 与渐变首色） | `mpv.com --idle=once --no-config --script=tests/tencent_parse_test.lua` |
| `tests/maccms_parse_test.lua` | 🆕 MacCMS 采集接口解析（`$$$` 分组、`#` 分集、`标题$链接` 切分、字段类型容错） | `mpv.com --idle=once --no-config --script=tests/maccms_parse_test.lua` |
| `tests/youku_items_test.lua` | 🆕 优酷搜索/分集解析（版权过滤、黑名单词、`seq==stage` 正片判定、电影/综艺/剧标题格式化；fixture 为实抓响应） | `mpv.com --idle=once --no-config --script=tests/youku_items_test.lua` |
| `tests/mgtv_items_test.lua` | 🆕 芒果搜索/分集解析（站外过滤、综艺黑名单、按月合并与期数编号） | `mpv.com --idle=once --no-config --script=tests/mgtv_items_test.lua` |
| `tests/bilibili_items_test.lua` | 🆕 B站 WBI 签名（确定性参考值）与搜索/PGC 分集解析（`section_type==0` 正片、season_id 去重） | `mpv.com --idle=once --no-config --script=tests/bilibili_items_test.lua` |
| `tests/bahamut_items_test.lua` | 🆕 巴哈搜索解析（info 年份）、分集双深度形态/各层断层受限识别、真实窗口期样本、sn 条目形状 | `mpv.com --idle=once --no-config --script=tests/bahamut_items_test.lua` |
| `tests/animeko_items_test.lua` | 🆕 animeko 搜索/MAIN 过滤/弹幕解析（顶层 `danmakuList`、location→mode 映射） | `mpv.com --idle=once --no-config --script=tests/animeko_items_test.lua` |
| `tests/maiduidui_items_test.lua` | 🆕 埋堆堆签名确定性、分组搜索/分集/弹幕解析（颜色兜底） | `mpv.com --idle=once --no-config --script=tests/maiduidui_items_test.lua` |
| `tests/history_merge_test.lua` | 🆕 文件夹记忆多源合并（旧 extra 迁移、同 kind 替换、dandanplay/直连源互不挤占、残留防护） | `mpv.com --idle=once --no-config --script=tests/history_merge_test.lua` |
| `tests/pakku_bench.lua` | 万条弹幕合并性能压测 | `mpv.com --idle=once --no-config --script=tests/pakku_bench.lua` |

---

## 致谢

- **[Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku)** —— 上游本体，本分支基于其 v2.2.0，安装与使用的绝大部分基础设施来自它
- **[pakku.js](https://github.com/xmcp/pakku.js)**（by xmcp, GPLv3）—— 弹幕合并与密度控制算法的行为复刻参考（独立 Lua 实现，未复制其源码或数据）
- **[pinyin-data](https://github.com/mozillazg/pinyin-data)**（MIT）—— 拼音谐音合并字典的数据源
- 以及上游依赖的 [弹弹play](https://www.dandanplay.com/) API、[uosc](https://github.com/tomasklaen/uosc)、[OpenCC](https://github.com/BYVoid/OpenCC)、[DanmakuConvert](https://github.com/timerring/DanmakuConvert)、[lua-inflate](https://github.com/TohruMKDM/lua-inflate) 等

---

<div align="center">

**MIT License** · 基于 [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) · 算法参考 [pakku.js](https://github.com/xmcp/pakku.js)

</div>
