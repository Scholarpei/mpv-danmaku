# uosc_danmaku

在MPV播放器中加载弹弹play弹幕，基于 uosc UI框架和弹弹play API的mpv弹幕扩展插件

> [!WARNING]
> Release1.2.0及Release1.2.0之前的发行版，都由于弹弹play接口使用政策改版，部分功能无法使用。如果发现插件功能异常，比如搜索弹幕总是显示无结果，请拉取或下载主分支最新源代码；或下载[最新发行版](https://github.com/Tony15246/uosc_danmaku/releases/latest)

> [!NOTE]
> 插件默认通过项目维护的 API 代理 `https://danmaku-api.152468.xyz` 访问弹弹play开放弹幕网络。普通用户无需注册账号，也无需配置或持有弹弹play的 AppId/AppSecret。代理包含缓存和访问频率限制，请勿用于批量抓取。

> [!NOTE]
> 已添加对mpv内部 `mp.input`的支持，在uosc不可用时通过键绑定调用此方式渲染菜单
> 
> 欲启用此支持mpv最低版本要求：0.39.0

## 项目简介

插件具体效果见演示视频：

<video width="902" src="https://github.com/user-attachments/assets/86717e75-9176-4f1a-88cd-71fa94da0c0e">
</video>

在未安装uosc框架时，调用mpv内部的 `mp.input`进行菜单渲染，具体效果见[此pr](https://github.com/Tony15246/uosc_danmaku/pull/24)

### 主要功能

<details open>

1. 从弹弹play或自定义服务的API获取剧集及弹幕数据，并根据用户选择的集数加载弹幕

2. 通过点击uosc control bar中的弹幕搜索按钮可以显示搜索菜单供用户选择需要的弹幕

3. 通过点击加入uosc control bar中的弹幕开关控件可以控制弹幕的开关

4. 通过点击加入uosc control bar中的[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)按钮可以通过受支持的网络源或本地文件添加弹幕

5. 通过点击加入uosc control bar中的[弹幕样式](#实时修改弹幕样式可选)按钮可以打开uosc弹幕样式菜单供用户在视频播放时实时修改弹幕样式（注意⚠️：未安装uosc框架时该功能不可用）

6. 通过点击加入uosc control bar中的[弹幕设置](#弹幕设置总菜单可选)按钮可以打开多级功能复合菜单，包含了插件目前所有的图形化功能。

7. 通过点击加入uosc control bar中的[弹幕源延迟设置](#弹幕源延迟设置可选)按钮可以打开弹幕源延迟控制菜单，可以独立控制每个弹幕源的延迟（注意⚠️：未安装uosc框架时该功能不可用）

8. 记忆型全自动弹幕填装，在为某个文件夹下的某一集番剧加载过一次弹幕后，加载过的弹幕会自动关联到该集；之后每次重新播放该文件就会自动加载弹幕，同时该文件对应的文件夹下的所有其他集数的文件都会在播放时自动加载弹幕，无需再重复手动输入番剧名进行搜索（注意⚠️：全自动弹幕填装默认关闭，如需开启请阅读[auto_load配置项说明](#auto_load)）

9. 在没有手动加载过弹幕，没有填装自动弹幕记忆之前，通过文件哈希匹配的方式自动添加弹幕（~仅限本地文件~，现已支持网络视频），对于能够哈希匹配关联的文件不再需要手动搜索关联，实现全自动加载弹幕并添加记忆。该功能随记忆型全自动弹幕填装功能一起开启（哈希匹配自动加载准确率较低，如关联到错误的剧集请手动加载正确的剧集）
   
   > 哈希匹配功能需要 mpv 基于 LuaJIT 或 Lua 5.2 构建，不支持 Lua 5.1

10. 自动记忆弹幕开关情况，播放视频时保持上次关闭时的弹幕开关状态

11. 自定义默认播放弹幕样式（具体设置方法详见[自定义弹幕样式](#自定义弹幕样式相关配置)）

12. 在使用如[Play-With-MPV](https://github.com/LuckyPuppy514/Play-With-MPV)或[ff2mpv](https://github.com/woodruffw/ff2mpv)等网络播放手段时，自动加载弹幕（注意⚠️：目前支持自动加载bilibili和巴哈姆特这两个网站的弹幕，具体说明查看[autoload_for_url配置项说明](#autoload_for_url)）

13. 保存当前弹幕到本地（详细功能说明见[save_danmaku配置项说明](#save_danmaku)）

14. pakku 式弹幕相似度合并：默认开启，通过「完全相同 / 字符多重集距离 / 拼音谐音 / 二元组余弦」四通道把时间窗口内的大量重复、近似、谐音弹幕合并为一条并以 ×N 显示数量（算法参考 [pakku.js](https://github.com/xmcp/pakku.js)，详见[merge_tolerance配置项说明](#merge_tolerance)）；相似度强度分「禁用/轻微/中等/强力」四档可调（[merge_similarity](#merge_similarity)），加载完成时 OSD 提示合并统计「已合并 N 条相似弹幕（A→B）」；配套「弹幕过滤」菜单提供合并、模式转换、同屏上限、黑名单的运行时开关

15. 弹幕简体字繁体字转换，解决弹幕简繁混杂问题（具体设置方法详见[chConvert配置项说明](#chConvert)）

16. 自定义插件相关提示的显示位置，可以自由调节距离画面左上角的两个维度的距离（具体设置方法详见[message_x配置项说明](#message_x)和[message_y配置项说明](#message_y)）

17. pakku 式智能密度控制：**默认开启**。按视觉密度值（dispval，综合文本长度与字号）统计同屏弹幕密度，超过软阈值先等比缩小字号（上限 √3 倍），超过更硬的阈值再按权重概率丢弃——未合并的弹幕先死，`xN` 合并弹幕受 √N 与权重排名双重保护（算法参考 [pakku.js](https://github.com/xmcp/pakku.js) 的 SHRINK/DROP_THRESHOLD，详见[density_control配置项说明](#density_control)）；强度分「宽松/中等/严格」三档（[density_level](#density_level)），加载完成时 OSD 提示「智能密度：缩小 N 条，丢弃 M 条」；原同屏上限随机丢弃保留为「简单模式」

18. 记忆型B站合集弹幕匹配：**默认开启**。在文件夹内播放任一集时通过[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)手动添加过B站视频（含多分P合集投稿）的弹幕后，同文件夹所有剧集播放时会自动按「分P标题 → 季度过滤 → 时长校验 → 集数差锚点」匹配对应分P并加载弹幕，支持每文件夹叠加最多 3 个B站视频，弹幕源的延迟/屏蔽状态跨集继承（详见[bilibili_series_memory配置项说明](#bilibili_series_memory)）

无需亲自下载整合弹幕文件资源，无需亲自处理文件格式转换，在mpv播放器中一键加载包含了哔哩哔哩、巴哈姆特等弹幕网站弹幕的弹弹play的动画弹幕。

插件本身支持Linux和Windows平台。项目依赖于[uosc UI框架](https://github.com/tomasklaen/uosc)。欲使用本插件强烈建议为mpv播放器中安装uosc。uosc的安装步骤可以参考其[官方安装教程](https://github.com/tomasklaen/uosc?tab=readme-ov-file#install)。当然，如果使用[MPV_lazy](https://github.com/hooke007/MPV_lazy)等内置了uosc的懒人包则只需安装本插件即可。

</details>

## 目录

- [项目简介](#项目简介)
  - [主要功能](#主要功能)
- [安装](#安装)
  - [下载](#下载)
- [基本配置](#基本配置)
  - [uosc控件配置](#uosc控件配置)
  - [绑定快捷键（可选）](#绑定快捷键可选)
- [拓展功能（可选）](#拓展功能可选)
  - [从弹幕源向当前弹幕添加新弹幕内容（从网络url或本地添加弹幕）](#从弹幕源向当前弹幕添加新弹幕内容可选)
  - [弹幕源延迟设置](#弹幕源延迟设置可选)
  - [实时修改弹幕样式](#实时修改弹幕样式可选)
  - [弹幕过滤菜单](#弹幕过滤菜单可选)
  - [弹幕设置总菜单](#弹幕设置总菜单可选)
  - [设置弹幕延迟（可选）](#设置弹幕延迟可选)
  - [保存当前视频弹幕（可选）](#保存当前视频弹幕可选)
  - [清空当前视频关联的弹幕源（可选）](#清空当前视频关联的弹幕源可选)
  - [清除文件夹的B站弹幕记忆（可选）](#清除文件夹的b站弹幕记忆可选)
  - [检查脚本更新（可选）](#检查脚本更新可选)
- [可配置选项（可选）](#可配置选项可选)
  - [弹幕加载相关](#弹幕加载相关)
  - [弹幕显示相关](#弹幕显示相关)
  - [弹幕解析服务相关](#弹幕解析服务相关)
  - [插件配置相关](#插件配置相关)
  - [自定义弹幕样式相关配置](#自定义弹幕样式相关配置)
- [插件自定义属性](#插件自定义属性)
- [常见问题](#常见问题)
- [特别感谢](#特别感谢)
- [相关项目](#相关项目)

## 安装

### 下载

一般的mpv配置目录结构大致如下

> [!NOTE]
> Windows 系统上等价全局配置路径`%APPDATA%/mpv/`，也可使用 mpv.exe 所在目录的 portable_config 文件夹（便携配置路径）

```
~/.config/mpv
├── fonts
├── input.conf
├── mplayer-input.conf
├── mpv.conf
├── script-opts
└── scripts
```

想要使用本插件，请将本插件完整地[下载](https://github.com/Tony15246/uosc_danmaku/releases)或者克隆到 `scripts`目录下即可使用，文件结构参阅下方

> [!IMPORTANT]
> 
> 1. scripts目录下放置本插件的文件夹名称必须为uosc_danmaku，否则必须参照uosc控件配置部分[修改uosc控件](#修改uosc控件可选)
> 2. 记得给bin文件夹下的文件赋予可执行权限

<details>
<summary>文件结构</summary>

```
~/.config/mpv/scripts
└── uosc_danmaku
    ├── apis
    │   ├── dandanplay.lua
    │   └── extra.lua
    ├── LICENSE
    ├── main.lua
    ├── modules
    │   ├── base64.lua
    │   ├── guess.lua
    │   ├── md5.lua
    │   ├── menu.lua
    │   ├── options.lua
    │   ├── render.lua
    │   └── utils.lua
    └── README.md
```

</details>

## 基本配置

#### uosc控件配置

这一步非常重要，不添加控件，弹幕搜索按钮和弹幕开关就不会显示在进度条上方的控件条中。若没有控件，则只能通过[绑定快捷键](#绑定快捷键可选)调用弹幕搜索和弹幕开关功能

想要添加uosc控件，需要修改mpv配置文件夹下的 `script-opts`中的 `uosc.conf`文件。如果已经安装了uosc，但是 `script-opts`文件夹下没有 `uosc.conf`文件，可以去[uosc项目地址](https://github.com/tomasklaen/uosc)下载官方的 `uosc.conf`文件，并按照后面的配置步骤进行配置。

由于uosc最近才更新了部分接口和控件代码，导致老旧版本的uosc和新版的uosc配置有所不同。如果是下载的最新git版uosc或者一直保持更新的用户按照 `最新版uosc的控件配置步骤` 配置即可。如果不确定自己的uosc版本，或者在使用诸如[MPV_lazy](https://github.com/hooke007/MPV_lazy)等由第三方管理uosc版本的用户，可以按照兼容新版和旧版uosc的 `旧版uosc控件配置步骤` 配置。

<details>
<summary>最新版uosc的控件配置步骤</summary>

找到 `uosc.conf`文件中的 `controls`配置项，uosc官方默认的配置可能如下：

```
controls=menu,gap,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

在 `controls`控件配置项中添加 `button:danmaku`的弹幕搜索按钮和 `cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关`的弹幕开关。放置的位置就是实际会在在进度条上方的控件条中显示的位置，可以放在自己喜欢的位置。我个人把这两个控件放在了 `<stream>stream-quality`画质选择控件后边。添加完控件的配置大概如下：

```
controls=menu,gap,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,button:danmaku,cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

</details>

<details>
<summary>旧版uosc控件配置步骤</summary>

找到 `uosc.conf`文件中的 `controls`配置项，uosc官方默认的配置可能如下：

```
controls=menu,gap,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

在 `controls`控件配置项中添加 `command:search:script-message open_search_danmaku_menu?搜索弹幕`的弹幕搜索按钮和 `cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关`的弹幕开关。放置的位置就是实际会在在进度条上方的控件条中显示的位置，可以放在自己喜欢的位置。我个人把这两个控件放在了 `<stream>stream-quality`画质选择控件后边。添加完控件的配置大概如下：

```
controls=menu,gap,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,command:search:script-message open_search_danmaku_menu?搜索弹幕,cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

</details>

<details>
<summary>修改uosc控件（可选）</summary>

如果出于重名等各种原因，无法将本插件所放置的文件夹命名为 `uosc_danmaku`的话，需要修改 `cycle:toggle_on:show_danmaku@uosc_danmaku:on=toggle_on/off=toggle_off?弹幕开关`的弹幕开关配置中的 `uosc_danmaku`为放置本插件的文件夹的名称。假如将本插件放置在 `my_folder`文件夹下，那么弹幕开关配置就要修改为 `cycle:toggle_on:show_danmaku@my_folder:on=toggle_on/off=toggle_off?弹幕开关`

</details>

#### 绑定快捷键（可选）

对于坚定的键盘爱好者和不使用鼠标主义者，可以选择通过快捷键调用弹幕搜索和弹幕开关功能

快捷键已经进行了默认绑定。默认情况下弹幕搜索功能绑定“Ctrl+d”；弹幕开关功能绑定“j”

弹幕搜索功能绑定的脚本消息为 `open_search_danmaku_menu`，弹幕开关功能绑定的脚本消息为 `show_danmaku_keyboard`

如需配置快捷键，只需在 `input.conf`中添加如下行即可，快捷键可以改为自己喜欢的按键组合。

```
Ctrl+d script-message open_search_danmaku_menu
j script-message show_danmaku_keyboard
```

> 根据[此issue中的需求](https://github.com/Tony15246/uosc_danmaku/issues/6)，添加了通过uosc_danmaku.conf绑定快捷键的功能。（请注意，最高优先级仍然是input.conf中设置的快捷键）
> 想要在uosc_danmaku.conf中自定义快捷键，可以像下面这样更改默认快捷键。

```
open_search_danmaku_menu_key=Ctrl+i
show_danmaku_keyboard_key=i
```

## 拓展功能（可选）

本插件针对弹幕有全方面的拓展功能

---

**带控件的功能**

<details>
<summary>从弹幕源向当前弹幕添加新弹幕内容（从网络url或本地添加弹幕）</summary>

> #### 从弹幕源向当前弹幕添加新弹幕内容（可选）

从弹幕源添加弹幕。在已经在播放弹幕的情况下会将添加的弹幕追加到现有弹幕中。

可添加的弹幕源如哔哩哔哩上任意视频通过video路径加BV号，或者巴哈姆特上的视频地址等。比如说以下地址均可作为有效弹幕源被添加：

```
https://www.bilibili.com/video/BV1kx411o7Yo
https://ani.gamer.com.tw/animeVideo.php?sn=36843
```

此功能通过调用弹弹Play的extcomment接口实现获取第三方弹幕站（如A/B/C站）上指定网址对应的弹幕。想要启用此功能，需要参照[uosc控件配置](#uosc控件配置)，根据uosc版本添加 `button:danmaku_source`或 `command:add_box:script-message open_add_source_menu?从源添加弹幕`到 `uosc.conf`的controls配置项中。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。从源添加弹幕功能对应的脚本消息为 `open_add_source_menu`。

```
key script-message open_add_source_menu
```

现已添加了对加载本地弹幕文件的支持，输入本地弹幕文件的绝对路径即可使用本插件加载弹幕。加载出来的弹幕样式同在本插件中设置的弹幕样式。支持的文件格式有ass文件和xml文件。具体可参见[此issue](https://github.com/Tony15246/uosc_danmaku/issues/26)

```
#Linux下示例
/home/tony/Downloads/example.xml
#Windows下示例
C:\Users\Tony\Downloads\example.xml
```

现已更新增强了此菜单。现在在该菜单内可以可视化地控制所有弹幕源，删除或者屏蔽任何不想要的弹幕源。对于自己手动添加的弹幕源，可以进行移除。对于来自弹弹play的弹幕源，无法进行移除，但是可以进行屏蔽，将不会再从屏蔽过的弹幕源获取弹幕。当然，也可以解除对来自弹弹play的弹幕源的屏蔽。另外需要注意在菜单内对于弹幕源的可视化操作都需要下次打开视频，或者重新用弹幕搜索功能加载一次弹幕才会生效。

</details>

<details>
<summary>弹幕源延迟设置</summary>

> #### 弹幕源延迟设置（可选）

可以独立控制每个弹幕源的延迟，延迟支持两种输入模式。第一种模式为输入数字（最高可精确到小数点后两位），单位为秒；第二种输入模式为输入形如 `14m15s`格式的字符串，代表延迟的分钟数和秒数。

想要启用此功能，需要参照[uosc控件配置](#uosc控件配置)，根据uosc版本添加 `button:danmaku_delay`或 `command:more_time:script-message open_source_delay_menu?弹幕源延迟设置`到 `uosc.conf`的controls配置项中。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。弹幕源延迟设置功能对应的脚本消息为 `open_source_delay_menu`。

```
key script-message open_source_delay_menu
```

</details>

<details>
<summary> 实时修改弹幕样式</summary>

> #### 实时修改弹幕样式（可选）

依赖于[uosc UI框架](https://github.com/tomasklaen/uosc)实现**弹幕样式实时修改**，将打开弹幕样式修改图形化菜单供用户手动修改（默认使用[自定义弹幕样式](#自定义弹幕样式相关配置)里的样式配置）。想要启用此功能，需要参照[uosc控件配置](#uosc控件配置)，根据uosc版本添加 `button:danmaku_styles`或 `command:palette:script-message open_danmaku_style_menu?弹幕样式`到 `uosc.conf`的controls配置项中。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。实时修改弹幕样式功能对应的脚本消息为 `open_danmaku_style_menu`。

```
key script-message open_danmaku_style_menu
```

</details>

<details>
<summary> 弹幕过滤菜单</summary>

> #### 弹幕过滤菜单（可选）

依赖[uosc UI框架](https://github.com/tomasklaen/uosc)实现弹幕过滤设置的**运行时图形化调整**，包含以下项目（也可从[弹幕设置总菜单](#弹幕设置总菜单可选)进入）：

| 菜单项 | 类型 | 说明 |
| --- | --- | --- |
| 弹幕合并 | 开关 | 对应 `merge_enabled` |
| 合并时间窗口 | 档位 | 对应 `merge_tolerance`（5/10/20/30/60/120 秒） |
| 拼音谐音合并 | 开关 | 对应 `merge_pinyin` |
| 相似度强度 | 档位 | 对应 `merge_similarity`（禁用/轻微/中等/强力） |
| 顶部弹幕转滚动 | 三态 | 对应 `convert_top_to_scroll`（关/全部/自动按宽度） |
| 底部弹幕转滚动 | 三态 | 对应 `convert_bottom_to_scroll`（关/全部/自动按宽度） |
| 转换宽度阈值 | 档位 | 对应 `scroll_threshold`（800/1200/1600/2000/2400 px，仅「自动」模式生效） |
| 同屏弹幕上限 | 档位 | 对应 `max_screen_danmaku`（不限/20/40/60/80/100，仅「简单」密度模式生效） |
| 密度控制 | 档位 | 对应 `density_control`（关闭/简单/智能） |
| 智能密度强度 | 档位 | 对应 `density_level`（宽松/中等/严格，仅「智能」模式生效） |
| 黑名单过滤 | 开关 | 对应 `blacklist_enabled` |
| 重载黑名单文件 | 动作 | 重新读取 `blacklist_path` 指向的规则文件并立即生效 |
| 打开黑名单文件位置 | 动作 | 在系统文件管理器中定位黑名单文件 |

菜单中的设置更改仅在本次播放生效（同样式菜单），持久化请写入配置文件。想要通过快捷键使用此功能，对应脚本消息为 `open_filter_danmaku_menu`：

```
key script-message open_filter_danmaku_menu
```

</details>

<details>
<summary> 弹幕设置总菜单</summary>

> #### 弹幕设置总菜单（可选）

打开多级功能复合菜单，包含了插件目前所有的图形化功能。想要启用此功能，需要参照[uosc控件配置](#uosc控件配置)，根据uosc版本添加 `button:danmaku_menu`或 `command:grid_view:script-message open_add_total_menu?弹幕设置`到 `uosc.conf`的controls配置项中。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。从源添加弹幕功能对应的脚本消息为 `open_add_total_menu`。

```
key script-message open_add_total_menu
```

</details>

---

**仅快捷键的功能**

<details>
<summary>设置弹幕延迟</summary>

> #### 设置弹幕延迟（可选）

可以通过快捷键绑定以下命令来调整弹幕延迟，单位：秒。秒数的含义为在当前弹幕延迟的基础上叠加新设置的延迟秒数进行调整，可以设置为负数。另外，设置为0时为特殊情况，会将弹幕延迟重置为0，回到初始状态。

```
# 设置整体弹幕延迟
key script-message danmaku-delay <seconds>
# 设置当前播放时间点的弹幕延迟
key script-message danmaku-delay <seconds> ${=time-pos}
```

> 当前弹幕延迟的值可以从 `user-data/uosc_danmaku/danmaku-delay`属性中获取到，具体用法可以参考[此issue](https://github.com/Tony15246/uosc_danmaku/issues/77)

</details>

<details>
<summary>保存当前视频弹幕</summary>

> #### 保存当前视频弹幕（可选）

在视频播放时手动保存弹幕，保存格式为 `xml`（注：此功能将保存为视频同名弹幕，若目标文件夹下存在同名文件将不会执行该功能）。默认保存至视频所在文件夹，也可以通过 `save_danmaku_path` 和 `save_danmaku_path_mode` 保存到指定文件夹。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。从源添加弹幕功能对应的脚本消息为 `immediately_save_danmaku`。

```
key script-message immediately_save_danmaku
```

</details>

<details>
<summary>清空当前视频关联的弹幕源</summary>

> #### 清空当前视频关联的弹幕源（可选）

可以清空当前视频中，用户通过[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)菜单手动添加的所有弹幕源（注意该功能不会删除来源于弹幕服务器的弹幕，此类弹幕只能屏蔽或者手动重新匹配新弹幕库）。清空过弹幕源之后，下次播放该视频，就不会再加载之前手动添加过的弹幕源，可以重新添加弹幕源。

注意⚠️：该功能**不会**清除[B站合集弹幕记忆](#bilibili_series_memory)（文件夹级记忆与单集弹幕源是两个独立概念），需要清除请使用[清除文件夹的B站弹幕记忆](#清除文件夹的b站弹幕记忆可选)。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。从源添加弹幕功能对应的脚本消息为 `clear-source`。

```
key script-message clear-source
```

</details>

<details>
<summary>清除文件夹的B站弹幕记忆</summary>

> #### 清除文件夹的B站弹幕记忆（可选）

清除当前播放文件所在文件夹的[B站合集弹幕记忆](#bilibili_series_memory)，之后播放该文件夹的剧集时不再自动加载B站弹幕，直到再次手动添加B站源。

也可以不绑定快捷键：在[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)菜单中对某个B站源执行「删除」动作时，会自动一并清除该视频对应的文件夹记忆。

想要通过快捷键使用此功能，请添加类似下面的配置到 `input.conf`中。该功能对应的脚本消息为 `clear-bilibili-record`。

```
key script-message clear-bilibili-record
```

</details>

<details>
<summary>检查脚本更新</summary>

> #### 检查脚本更新（可选）

可以通过绑定以下脚本命令来实现检查并自动更新脚本

> 只会检查 `Releases`中发布的更新

```
key script-message check-update
```

</details>

---

## 可配置选项（可选）

本插件可以在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件自定义下例配置开启额外功能或自定义功能细节

### 弹幕加载相关

<!--  下列是弹幕加载相关  -->

<details>
<summary>
auto_load

> 开关全自动弹幕填装

</summary>

### auto_load

#### 功能说明

该选项控制是否开启全自动弹幕填装功能。该功能会在为某个文件夹下的某一集番剧加载过一次弹幕后，把加载过的弹幕会自动关联到该集。之后每次重新播放该文件就会自动加载对应的弹幕，同时该文件对应的文件夹下的所有其他集数的文件都会在播放时自动加载弹幕。

举个例子，比如说有一个文件夹结构如下

```
败犬女主太多了
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_01WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_02WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_03WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_04WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_05WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_06WebRipHEVC_AACCHS_JP.mp4
├── KitaujiSub_Make_Heroine_ga_Oosugiru!_07v2WebRipHEVC_AACCHS_JP.mp4
└── KitaujiSub_Make_Heroine_ga_Oosugiru!_08WebRipHEVC_AACCHS_JP.mp4
```

只要在播放第一集 `KitaujiSub_Make_Heroine_ga_Oosugiru!_01WebRipHEVC_AACCHS_JP.mp4`的时候手动搜索并且加载过一次弹幕，那么打开第二集时就会直接自动加载第二集的弹幕，打开第三集时就会直接加载第三集的弹幕，以此类推，不用再手动搜索

#### 使用方法

想要开启此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加如下内容：

```
auto_load=yes
```

注意⚠️： 一个文件夹下有且仅有一同部番剧的若干视频文件才会生效。下面这种情况下，如果手动搜索并且加载过一次《少女歌剧》第一集的弹幕，《哭泣少女乐队》第二集必须重新手动识别，但这样会破坏《少女歌剧》的弹幕记录

```
少女歌剧
├── 少女歌剧1.mp4
├── 少女歌剧2.mp4
├── 少女歌剧3.mp4
├── 少女歌剧4.mp4
└── 哭泣少女乐队2.mp4
```

</details>

---

<details>
<summary>
autoload_for_url

> 开关url播放场景自动加载弹幕与关联继承

</summary>

### autoload_for_url

#### 功能说明

开启此选项后，会为可能支持的 url 视频文件实现弹幕关联记忆和继承，配合播放列表食用效果最佳。目前兼容在使用[embyToLocalPlayer](https://github.com/kjtsune/embyToLocalPlayer)、[mpv-torrserver](https://github.com/dyphire/mpv-config/blob/master/scripts/mpv-torrserver.lua)、[tsukimi](https://github.com/tsukinaha/tsukimi)等场景时进行弹幕关联记忆和继承。

目前的具体支持情况和实现效果可以参考[此pr](https://github.com/Tony15246/uosc_danmaku/pull/16)

另外，开启此选项后还会在网络播放bilibili以及巴哈姆特的视频时自动加载对应视频的弹幕，可配合[Play-With-MPV](https://github.com/LuckyPuppy514/Play-With-MPV)或[ff2mpv](https://github.com/woodruffw/ff2mpv)等网络播放手段使用。（播放巴哈姆特的视频时弹幕自动加载如果失败，请检查[proxy](#proxy)选项配置是否正确）

#### 使用方法

想要开启此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加如下内容：

```
autoload_for_url=yes
```

</details>

---

<details>
<summary>
auto_fallback_search

> 开关全自动弹幕填装失败后弹出搜索框

</summary>

### auto_fallback_search

#### 功能说明

开启此选项后，当全自动弹幕填装选项 `auto_load=yes` 使用时，弹幕自动加载匹配全部失败后，弹出搜索框让用户手动搜索，默认关闭不使用

#### 使用方法

想要开启此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加如下内容：

```
auto_fallback_search=yes
```

</details>

---

<details>
<summary>
autoload_local_danmaku

> 开关自动加载同目录下的xml格式弹幕文件

</summary>

### autoload_local_danmaku

#### 功能说明

自动加载播放文件同目录下同名的 xml 格式的弹幕文件

#### 使用方法

想要开启此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加如下内容：

```
autoload_local_danmaku=yes
```

</details>

---

<details>
<summary>
bilibili_series_memory

> B站合集弹幕记忆：文件夹内手动添加过B站弹幕源后，同文件夹其他剧集自动匹配分P加载

</summary>

### bilibili_series_memory

#### 功能说明

开启后，在某个文件夹内播放任一集时通过[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)菜单手动添加过B站视频（如 `https://www.bilibili.com/video/BVxxxx/?p=58`）的弹幕，插件会把该B站视频记入文件夹级记忆（每文件夹最多记忆 3 个视频，按最近使用淘汰）。之后播放同文件夹的其他剧集时，会自动为当前集匹配对应分P并加载弹幕，无需每集重新粘贴链接。

匹配策略（按优先级）：

1. **分P标题匹配**：解析分P标题中的季/集（如 `【S3】09`、`09`、`第9话`、`24（OVA）`）与当前文件名解析出的季/集比对，分P显式标注的季与本地季矛盾时直接排除
2. **时长校验**：分P时长与本地视频时长差 ≤120s 加分、>300s 减分，平局时时长裁定
3. **集数差锚点**：以最近一次匹配到的 (分P页号, 当时集数) 为锚点，按集数差推算页号仲裁歧义（应对本地文件名解析不出季数、或合集投稿把多季混排的情况）
4. 匹配失败时 OSD 提示「B站分P未匹配」并跳过该层，不影响其他弹幕源加载

三个可选值：

- `off`：关闭该功能（手动添加的B站源仍按原逻辑只作用于当前集）
- `add`（默认）：B站弹幕与[自动填装](#auto_load)/哈希匹配的弹幕**叠加加载**，与手动在每集粘贴链接的行为一致
- `first`：B站匹配成功时本次不再进行弹弹play自动匹配（失败则自动回退）

弹幕源延迟设置与屏蔽状态会同步进文件夹记忆，跨集自动继承。通过[从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选)菜单「删除」某个B站源时会自动清除对应的文件夹记忆，也可绑定快捷键一键清除（见[清除文件夹的B站弹幕记忆](#清除文件夹的b站弹幕记忆可选)）。

注意⚠️：
- 仅支持普通投稿视频（BV/av 链接）；番剧 `ep` 链接、课程 `cheese` 链接与 `b23.tv` 短链不支持文件夹记忆（仍可按原逻辑为当前集添加）
- 与[auto_load](#auto_load)同理，要求一个文件夹下只有同一部番剧

#### 使用方法

请在mpv配置文件夹下的 `script-opts`中的 `uosc_danmaku.conf`文件中添加如下内容：

```
bilibili_series_memory=add
```

</details>

---

<details>
<summary>
save_danmaku

> 开关自动保存弹幕文件（xml格式）至视频同目录

</summary>

### save_danmaku

#### 功能说明

当文件关闭时自动保存弹幕文件（xml格式），保存的弹幕文件名与对应的视频文件名相同。默认保存至视频同目录，配合[autoload_local_danmaku选项](#autoload_local_danmaku)可以实现弹幕自动保存到本地并且下次播放时自动加载本地保存的弹幕。此功能默认禁用。

> **⚠️NOTE！**
> 
> 当开启[autoload_local_danmaku选项](#autoload_local_danmaku)时，会自动加载播放文件同目录下同名的 xml 格式的弹幕文件，优先级高于一切其他自动加载弹幕功能。如果不希望每次播放都加载之前保存的本地弹幕，则请关闭[autoload_local_danmaku选项](#autoload_local_danmaku)；或者在保存完弹幕之后转移弹幕文件至其他路径并关闭 `save_danmaku`选项。
> 
> `save_danmaku`选项的打开和关闭可以运行时实时更新。在 `input.conf`中添加如下内容，可通过快捷键实时控制 `save_danmaku`选项的打开和关闭
> 
> ```
> key cycle-values script-opts uosc_danmaku-save_danmaku=yes uosc_danmaku-save_danmaku=no
> ```

#### 使用方法

想要启用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并指定如下内容：

```
save_danmaku=yes
```

如需保存到指定文件夹，请提前创建目标文件夹，然后配置 `save_danmaku_path` 和 `save_danmaku_path_mode`。插件不会自动创建目录。

保存本地媒体到指定文件夹时，文件名会包含视频父目录名，用于减少不同目录下同名视频的弹幕文件冲突。例如 `动画/01.mkv` 会保存为类似 `动画_01.xml`。网络媒体保存到指定文件夹时仍使用媒体标题作为文件名。

`save_danmaku_path_mode` 可选值如下：

- `local`：默认值，仅本地媒体保存到 `save_danmaku_path`，网络媒体仍不保存
- `url`：仅网络媒体保存到 `save_danmaku_path`，本地媒体仍保存到视频同目录
- `all`：本地媒体和网络媒体都保存到 `save_danmaku_path`

例如，仅将网络媒体的弹幕保存到 `~~/danmaku`：

```
save_danmaku=yes
save_danmaku_path=~~/danmaku
save_danmaku_path_mode=url
```

例如，将所有媒体的弹幕都保存到 `~~/danmaku`：

```
save_danmaku=yes
save_danmaku_path=~~/danmaku
save_danmaku_path_mode=all
```

</details>

---

### 弹幕显示相关

(如果需要更细节的弹幕样式修改请看[自定义弹幕样式](#自定义弹幕样式相关配置))

<!--  下列是弹幕显示相关  -->

<details>
<summary>
opacity

> 自定义弹幕的透明度

</summary>

### opacity

#### 功能说明

自定义弹幕的透明度，0（完全透明）到1（不透明）。默认值：0.7

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
opacity=0.7
```

</details>

---

<details>
<summary>
chConvert

> 开关中文简繁转换

</summary>

### chConvert

#### 功能说明

中文简繁转换。0-不转换，1-转换为简体，2-转换为繁体。默认值: 0，不转换简繁字体，按照弹幕源原本字体显示

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
chConvert=0
```

</details>

---

<details>
<summary>
merge_enabled

> pakku 式弹幕相似度合并总开关

</summary>

### merge_enabled

#### 功能说明

控制弹幕相似度合并功能的总开关。默认值: `yes`（开启）

开启后，时间窗口（`merge_tolerance`）内满足以下任一相似条件的弹幕会被合并成一条，并在文本后附加 `xN` 数量标记：

1. 归一化后文本完全相同（忽略末尾标点、多余空格、全半角差异）
2. 字符多重集距离足够近（「哈哈哈哈」与「哈哈哈哈哈」）
3. 拼音读音多重集距离足够近（谐音弹幕，如「泪目」与「累目」，需 `merge_pinyin`）
4. 环形二元组余弦相似度足够高（同一句子的长短变体，如不同长度的「2333…」刷屏）

合并算法参考并行为复刻自 [pakku.js](https://github.com/xmcp/pakku.js)（GPLv3, by xmcp），本项目为独立 Lua 实现，未复制其源码或数据。

加载完成后会以 OSD 提示合并统计「已合并 N 条相似弹幕（A→B）」（仅实际发生合并时显示；B 为合并后条数，「共计」显示的条数还经过密度控制，故两者可能不同）。`xN` 标记的加粗斜体样式只作用于由合并引擎附加的后缀，用户原文天然以 x数字 结尾（如「666x3」）不受影响。

#### 使用方法

```
merge_enabled=yes
```

</details>

---

<details>
<summary>
merge_tolerance

> 弹幕合并的时间窗口

</summary>

### merge_tolerance

#### 功能说明

指定弹幕合并的时间窗口，单位为秒。默认值: `30`（pakku 默认）

从每簇弹幕的首条起算，时间差超过该窗口的相似弹幕不再合并；窗口越大去重效果越强，但耗时也越长。设为 `0` 或负数时禁用合并（`merge_enabled` 仍需开启）。

#### 使用方法

```
merge_tolerance=30
```

</details>

---

<details>
<summary>
merge_cross_mode

> 是否跨位置类型合并弹幕

</summary>

### merge_cross_mode

#### 功能说明

默认值: `yes`（开启）

开启时，滚动、顶部、底部弹幕可以互相合并，合并后的弹幕按「底部 > 顶部 > 滚动」提升显示模式；关闭时只在相同位置类型内合并。

> [!NOTE]
> 本选项取代了旧版的 `merge_without_style`（旧版 `merge_without_style=yes` 等价于现在的默认行为）。conf 中残留的 `merge_without_style` 键会被自动忽略。

#### 使用方法

```
merge_cross_mode=yes
```

</details>

---

<details>
<summary>
merge_pinyin

> 拼音谐音合并

</summary>

### merge_pinyin

#### 功能说明

默认值: `yes`（开启）

开启后，读音相同或相近的弹幕（如「泪目」与「累目」）也会参与合并。依赖 `dicts/pinyin_chars.lua` 拼音字典（GB2312 常用字集，由 `tools/gen_pinyin_dict.py` 生成，数据源 [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data)，MIT）；字典文件缺失时该通道自动禁用，其余合并通道不受影响。

#### 使用方法

```
merge_pinyin=yes
```

</details>

---

<details>
<summary>
merge_similarity

> 相似度合并强度四档

</summary>

### merge_similarity

#### 功能说明

指定相似度判定的激进程度，映射合并引擎内部的字符多重集距离阈值（`max_dist`）与二元组余弦阈值（`max_cosine`）。默认值: `medium`

| 档位 | max_dist | max_cosine | 效果 |
| --- | --- | --- | --- |
| `off` | — | — | 禁用相似通道（完全相同的弹幕也不再合并，等同关闭合并） |
| `light` | 2 | 60 | 轻微：只合并几乎相同的弹幕 |
| `medium` | 5 | 45 | 中等：默认档，等于 pakku 官方默认阈值 |
| `strong` | 10 | 35 | 强力：激进合并，弹幕总量明显减少，可能误伤内容不同的弹幕 |

> [!NOTE]
> 档位端点数值为自拟插值（弹弹play 式四档 UI 惯例；pakku 官方选项页为数字输入框），其中 `medium` 对齐 pakku 默认 `MAX_DIST=5` / `MAX_COSINE=45`。conf 中写入未知值时回落 `medium`。

#### 使用方法

```
merge_similarity=medium
```

</details>

---

<details>
<summary>
merge_forcelist

> 套路规则重写（合并前文本规范化）

</summary>

### merge_forcelist

#### 功能说明

在参与合并比较之前，先把匹配规则的弹幕文本统一改写，解决同一刷屏文本长短不一难以合并的问题（如任意长度的「2333…」「6666…」）。默认值：

```
^2333+=>23333|^666+=>66666
```

多条规则用 `|` 分隔，每条规则格式为 `pattern=>replacement`，pattern 使用 **Lua pattern** 语法（不是正则表达式），顺序应用、命中后继续套用后续规则。注意：改写只影响合并比较与合并后的显示文本，未被合并的单条弹幕仍显示原文。

#### 使用方法

```
merge_forcelist=^2333+=>23333|^666+=>66666
```

</details>

---

<details>
<summary>
convert_top_to_scroll / convert_bottom_to_scroll

> 顶部/底部弹幕转换为滚动弹幕

</summary>

### convert_top_to_scroll / convert_bottom_to_scroll

#### 功能说明

默认值: `no`（关闭），两个选项相互独立

三态选项，控制顶部（`convert_top_to_scroll`）或底部（`convert_bottom_to_scroll`）固定弹幕转换为滚动弹幕并加 `↑` / `↓` 前缀标记（pakku 惯例）的行为：

| 取值 | 行为 |
| --- | --- |
| `no` | 不转换 |
| `yes` | 全部强制转换为滚动，避免固定弹幕长时间遮挡画面 |
| `auto` | 仅文本宽度超过 `scroll_threshold` 的才转换（pakku `SCROLL_THRESHOLD` 语义），短固定弹幕保留原样 |

> [!NOTE]
> 转换发生在合并之前：转换后的弹幕以滚动模式参与后续合并，pakku 的「底部 > 顶部 > 滚动」模式提升对其不再生效（`yes`/`auto` 下均为既有行为）。

#### 使用方法

```
convert_top_to_scroll=auto
convert_bottom_to_scroll=no
```

</details>

---

<details>
<summary>
scroll_threshold

> 「自动」转换模式的宽度阈值

</summary>

### scroll_threshold

#### 功能说明

默认值: `1200`（pakku 默认），仅当 `convert_top_to_scroll` / `convert_bottom_to_scroll` 为 `auto` 时生效。

按当前 `fontsize` 估算弹幕文本宽度（一个汉字约等于一个字号像素），超过该阈值的顶部/底部弹幕被转换为滚动弹幕，短的保留原样。设为 `0` 或负数时禁用「自动」模式（等同 `no`）。

#### 使用方法

```
scroll_threshold=1200
```

</details>

---

<details>
<summary>
blacklist_enabled

> 黑名单过滤开关

</summary>

### blacklist_enabled

#### 功能说明

默认值: `yes`（开启）

控制 `blacklist_path` 指向的黑名单规则文件是否生效。规则文件的格式说明见[自定义弹幕样式相关配置](#自定义弹幕样式相关配置)中的 `blacklist_path` 注释；可在「弹幕过滤」菜单中运行时开关、热重载规则文件或直接打开文件位置编辑。

#### 使用方法

```
blacklist_enabled=yes
```

</details>

---

<details>
<summary>
merge_fontsize_growth

> 设置合并弹幕字号随合并数量增长的速度

</summary>

### merge_fontsize_growth

#### 功能说明

配合 `merge_tolerance` 使用，默认值为 `8`，必须为正整数。设基础字号为 `fontsize`、合并数量为 `n`，实际字号为：

```
min(merge_fontsize_max, fontsize + round(merge_fontsize_growth * ln(n)))
```

取整前的对数函数严格递增且严格凹，因此合并数量较小时放大明显，随后每多合并一条弹幕带来的字号增量逐渐减小。取整后的整数字号单调不减，并受 `merge_fontsize_max` 限制。字号较大的弹幕会按实际高度占用连续的 y 轴区间；屏幕可显示区域内找不到无碰撞位置时，该条弹幕会被丢弃。

#### 使用方法

```
merge_fontsize_growth=8
```

</details>

---

<details>
<summary>
merge_fontsize_max

> 限制合并弹幕的最大字号

</summary>

### merge_fontsize_max

#### 功能说明

配合 `merge_fontsize_growth` 使用，默认值为 `100`。无论合并数量多大，最终字号都不会超过该值；如果该值小于基础字号 `fontsize`，则使用基础字号。

#### 使用方法

```
merge_fontsize_max=100
```

</details>

---

<details>
<summary>
max_screen_danmaku

> 限制屏幕中同时显示的弹幕数量（仅简单密度模式生效）

</summary>

### max_screen_danmaku

#### 功能说明

当该值大于0时，脚本会在解析弹幕时丢弃部分弹幕，确保任意时刻屏幕中显示的弹幕不超过设定值。超出上限时采用**随机丢弃**策略（哔哩哔哩官方播放器行为）。该设置也可在「弹幕过滤」菜单中切换档位（不限/20/40/60/80/100）。

> [!NOTE]
> 自 `density_control` 引入后，本项**仅在 `density_control=simple`（简单模式）下生效**——简单模式即本项原本的随机丢弃行为，被降级为智能密度控制的备选方案。若你此前配置了该值并希望保持原随机丢弃行为，请同时设置 `density_control=simple`。

#### 使用方法

在 `script-opts` 目录下创建 `uosc_danmaku.conf` 并添加如下内容：

```
density_control=simple
max_screen_danmaku=60
```

</details>

---

<details>
<summary>
density_control

> 弹幕密度控制模式（关闭/简单/智能）

</summary>

### density_control

#### 功能说明

指定密度控制策略。默认值: `smart`

| 模式 | 效果 |
| --- | --- |
| `off` | 不做任何密度控制 |
| `simple` | 简单模式：同屏条数上限 + **随机丢弃**（B 站播放器行为，读取 `max_screen_danmaku`） |
| `smart` | 智能模式（默认）：pakku 式先等比缩小字号、超更硬阈值再按权重概率丢弃 |

智能模式为 [pakku.js](https://github.com/xmcp/pakku.js) SHRINK/DROP_THRESHOLD 的行为复刻（独立 Lua 实现）：

1. **视觉密度值 dispval** = √有效长度 × clamp(字号/基准字号, 0.7, 2.5)^1.5（半角字符记 0.5 个长度；基准字号为 `fontsize`）。滑动窗口按每条弹幕的**真实显示区间**累计同屏密度（滚动 `scrolltime` 秒、固定 `fixtime` 秒，比 pakku 固定 5 秒窗口更贴合本脚本的实际渲染时长）。
2. **先缩小**：密度超过软阈值（`density_level` 的第一个值）时，按 `min((密度/阈值)^0.35, √3)` 等比缩小当条字号——弹幕越密字号越小，但最多缩到 1/√3；窗口中累计的密度值按缩小前字号计算（pakku 语义）。
3. **再丢弃**：密度仍超过硬阈值（第二值，恒为软阈值的 2 倍）时按概率丢弃，死亡概率 = 超限比例 + 0.25 − 保护项。**未合并弹幕没有任何保护（先死）**；`xN` 合并弹幕受双重保护：`(√N−1)/5`（合并数保护）与「权重排名保护」——合并数在全片弹幕中排名越靠前，最多再减 0.25。

pakku 原版还有 √点赞/8 保护项，因现有弹幕源（XML / dandanplay JSON）均不提供点赞数据而暂缺，代码中留有钩子。收缩作用于合并放大之后，因此高合并弹幕的字号也可能被压回基准以下（约束的是视觉面积，属预期行为）。

加载完成时 OSD 提示「智能密度：缩小 N 条，丢弃 M 条」（仅实际发生干预时显示）。强度档位见 [density_level](#density_level)。conf 中写入未知值时回落 `smart`。

#### 使用方法

在 `script-opts` 目录下创建 `uosc_danmaku.conf` 并添加如下内容：

```
density_control=smart
```

</details>

---

<details>
<summary>
density_level

> 智能密度强度三档

</summary>

### density_level

#### 功能说明

指定智能模式的密度档位，映射（收缩阈值, 丢弃阈值）两个 dispval 值。默认值: `medium`。仅 `density_control=smart` 时生效。

| 档位 | 收缩阈值 | 丢弃阈值 | 效果 |
| --- | --- | --- | --- |
| `loose` | 80 | 160 | 宽松：仅极端弹幕墙干预 |
| `medium` | 50 | 100 | 中等：默认档，舒适满屏即开始收缩 |
| `strict` | 30 | 60 | 严格：约 2/3 满屏即干预，弹幕显著减少 |

> [!NOTE]
> 标定基准：1080p、`displayarea=0.85` 下约 18 行 50px 弹幕带，一条 10 字弹幕 dispval≈√10≈3.2，舒适满屏 ≈ 58 → `medium=50` 恰在舒适满屏触发收缩。档位对 `fontsize` 的修改不敏感（基准同步缩放、clamp 以基准为锚）。conf 中写入未知值时回落 `medium`。

#### 使用方法

```
density_level=medium
```

</details>

---

<details>
<summary>
vf_fps

> 开关使用fps视频滤镜提升弹幕平滑度（帧数）

</summary>

### vf_fps

#### 功能说明

指定是否使用 fps 视频滤镜 `@danmaku:fps=fps=60/1.001`，可大幅提升弹幕平滑度。默认禁用

注意该视频滤镜的性能开销较大，需在确保设备性能足够的前提下开启

启用选项后仅在视频帧率小于 60 及显示器刷新率大于等于 60 时生效

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并指定如下内容：

```
vf_fps=yes
```

</details>

---

<details>
<summary>
fps

> 自定义fps滤镜参数适配不同显示器刷新率

</summary>

### fps

#### 功能说明

指定要使用的 fps 滤镜参数，例如如果设置fps为 `60/1.001`，则实际生效的视频滤镜参数为 `@danmaku:fps=fps=60/1.001`

使用这个选项，可以根据自己显示器的刷新率调整要使用的视频滤镜参数

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并指定如下内容：

```
fps=60/1.001
```

</details>

---

### 弹幕解析服务相关

<!--  下列是弹幕解析服务相关  -->

<details>
<summary>
api_server

> 自定义弹幕API

</summary>

### api_server

#### 功能说明

允许自定义弹幕 API 的服务地址。默认使用项目维护的 `https://danmaku-api.152468.xyz`，由代理完成弹弹play API 鉴权，插件用户无需配置密钥。

可指定多个用逗号分隔的有序 api_server 列表（`有序`是指搜索结果将依据相同剧集 ID，在 api_server 中的顺序向前合并成一项）。

支持每项使用 '|' 或 '#' 分隔备注，例如: "https://a.example.com|备用A" 或 "https://b.example.com#备用B"

多 api_server 时搜索剧集，可以使用 ”剧集名称@server备注“ 的形式指定备注匹配 api_server 单一检索

> **⚠️NOTE！**
> 
> 请确保自定义服务的 API 与弹弹play 的兼容，已知兼容：[misaka_danmu_server](https://github.com/l429609201/misaka_danmu_server)，[danmu_api](https://github.com/huangxd-/danmu_api)
>
> 通过默认 API 代理访问弹弹play时，无需配置弹弹play的 AppId/AppSecret；如需使用个人申请的弹弹play AppId/AppSecret 凭据，可以自行部署服务端代理，并将 `api_server` 指向该代理。

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
api_server=https://danmaku-api.152468.xyz
```

</details>

---

<details>
<summary>
fallback_server

> 自定义b站和爱腾优的弹幕获取的兜底服务器地址

</summary>

### fallback_server

#### 功能说明

自定义 b 站和爱腾优的弹幕获取的兜底服务器地址，主要用于获取非动画弹幕，只有在配置的所有 **`api_server`** 以及插件内置的 `站点专用解析器` 都无法解析视频源对应弹幕的情况下，才会使用此处设置的服务器进行解析。可用：https://dmku.hls.one

> **⚠️NOTE！**
>
> 插件已在 `sites` 目录下内置了各大常规视频网站的弹幕站点专用解析器（[#377](https://github.com/Tony15246/uosc_danmaku/pull/377) [#380](https://github.com/Tony15246/uosc_danmaku/pull/380)），仅当专用解析器都无法解析获取站点弹幕时才会使用兜底服务器
>
> 不设置此选项的情况下默认使用 ` https://dmku.hls.one`作为兜底服务器

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
fallback_server=https://dmku.hls.one
```

</details>

---

<details>
<summary>
tmdb_api_key

> 自定义 tmdb 的 API Key获取非动画条目的中文信息

</summary>

### tmdb_api_key

#### 功能说明

设置 tmdb 的 API Key，用于获取非动画条目的中文信息(当搜索内容非中文时)。可以在 https://www.themoviedb.org 注册后去个人账号设置界面获取个人的tmdb 的 API Key。

> **⚠️NOTE！**
> 
> 不设置此选项的情况下默认使用专为本项目申请的API Key。另外，自定义此选项时还需要对获取到的 API Key 进行 base64 编码。

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
tmdb_api_key=NmJmYjIxOTZkNzIyN2UyMTIzMGM3Y2YzZjQ4MDNkZGM=
```

</details>

---

### 插件配置相关

<details>
<summary>
user_agent

> 自定义请求时的User Agent

</summary>

### user_agent

#### 功能说明

自定义 `curl`发送网络请求时使用的 User Agent，默认值是 `mpv_danmaku/1.0`

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容（不可为空）：

> **⚠️NOTE！**
> 
> 使用默认 API 代理时无需为弹弹play鉴权而修改 User-Agent。直接接入弹弹play官方 API 或其他自定义服务时，请遵循对应服务的 User-Agent 要求。
> 
> 若想提高URL播放的哈希匹配成功率，可以将此项设为 `mpv`或浏览器的User-Agent

```
user_agent=mpv_danmaku/1.0
```

</details>

---

<details>
<summary>
proxy

> 自定义请求时的代理

</summary>

### proxy

#### 功能说明

自定义 `curl`发送网络请求时使用的代理，默认禁用

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
proxy=127.0.0.1:7890
```

</details>

---

<details>
<summary>
message_x

> 自定义插件相关提示的显示位置（x轴）

</summary>

### message_x

#### 功能说明

自定义插件相关提示的显示位置，距离屏幕左上角的x轴的距离

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
message_x=30
```

</details>

---

<details>
<summary>
message_y

> 自定义插件相关提示的显示位置（y轴）

</summary>

### message_y

#### 功能说明

自定义插件相关提示的显示位置，距离屏幕左上角的y轴的距离

#### 使用方法

想要使用此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并自定义如下内容：

```
message_y=30
```

</details>

---

<details>
<summary>
title_replace

> 自定义文件标题解析中的额外替换规则

</summary>

### title_replace

自定义标题解析中的额外替换规则，内容格式为 JSON 字符串，替换模式为 lua 的 string.gsub 函数

注意⚠️：由于 mpv 的 lua 版本限制，自定义规则只支持形如 %n 的捕获组写法，即示例用法，不支持直接替换字符的写法

用法示例：

```
title_replace=[{"rules":[{ "^〔(.-)〕": "%1"},{ "^.*《(.-)》": "%1" }]}]
```

</details>

---

<details>
<summary>
excluded_path

> 指定哈希匹配中需忽略的共享盘（挂载盘）的路径/目录

</summary>

### excluded_path

指定哈希匹配中需忽略的共享盘（挂载盘）的路径/目录。支持绝对路径和相对路径，多个路径用逗号分隔

用法示例：

```
excluded_path=["X:", "Z:", "F:/Download/", "Download"]
```

</details>

---

<details>
<summary>
history_path

> 指定弹幕关联历史记录文件路径

</summary>

### history_path

#### 功能说明

指定弹幕关联历史记录文件的路径，支持绝对路径和相对路径。默认值是 `~~/danmaku-history.json`也就是mpv配置文件夹的根目录下

#### 使用示例

想要配置此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加类似如下内容：

> **⚠️IMPORTANT**
> 不要直接复制这里的配置，这只是一个示例，路径要写成真实存在的路径。此选项可以不配置，脚本会默认放在mpv配置文件夹的根目录下。

```
history_path=/path/to/your/danmaku-history.json
```

</details>

---

### 自定义弹幕样式相关配置

默认配置如下，可根据需求更改并自定义弹幕样式

想要配置此选项，请在mpv配置文件夹下的 `script-opts`中创建 `uosc_danmaku.conf`文件并添加类似如下内容：

```
#滚动弹幕的显示时间
scrolltime=15
#固定弹幕的显示时间
fixtime=5
#字体(名称两边不需要使用引号""括住)
fontname=sans-serif
#大小
fontsize=50
#阴影
shadow=0
#粗体
bold=yes
#全部弹幕的显示范围(0.0-1.0)
displayarea=0.85
#描边 0-4
outline=1
#指定弹幕屏蔽词文件路径(black.txt)，支持绝对路径和相对路径。文件内容以换行分隔
##支持 lua 的正则表达式写法；修改文件后可在「弹幕过滤」菜单中热重载，blacklist_enabled 可运行时开关
##相对路径先按 mpv 工作目录解析，找不到时自动回退按脚本所在目录解析（适合把 black.txt 放脚本目录、从任意位置启动 mpv 的场景）
blacklist_path=
```

## 插件自定义属性

- `user-data/uosc_danmaku/danmaku-delay`

    从 `user-data/uosc_danmaku/danmaku-delay`属性中可以获取到当前弹幕延迟的值，具体用法可以参考[此issue](https://github.com/Tony15246/uosc_danmaku/issues/77)

- `user-data/uosc_danmaku/has-danmaku`

    从`user-data/uosc_danmaku/has-danmaku`属性中可以获取到表示当前是否有弹幕在显示的布尔值，具体用法可以参考[此pr](https://github.com/Tony15246/uosc_danmaku/pull/276)

- `user-data/uosc_danmaku/danmaku-switch-on`

    从`user-data/uosc_danmaku/danmaku-switch-on`属性中可以获取到表示当前弹幕开关状态的布尔值，具体用法可以参考[此issue](https://github.com/Tony15246/uosc_danmaku/issues/362)

- `user-data/uosc_danmaku/danmaku-count`

    从`user-data/uosc_danmaku/danmaku-count`属性中可以获取到当前弹幕池里的弹幕总数

## 常见问题

### 来自弹弹play的弹幕源问题如何从根源进行调整解决

本插件动画弹幕均来自[弹弹play api](https://github.com/kaedei/dandanplay-libraryindex/blob/master/api/OpenPlatform.md)，所以你可能会遇到 `部分动画没有弹幕`和 `弹幕时间轴对不上`这类问题，虽然你可以使用本插件的 [从源获取弹幕](#从弹幕源向当前弹幕添加新弹幕内容可选) 和 [弹幕源延迟设置](#弹幕源延迟设置可选) 这两个功能解决，但你如果想为弹幕源做贡献从根源解决帮所有用户解决这类问题，可以参考下列教程:

1.下载[弹弹play pc端](https://www.dandanplay.com)

2.使用弹弹play `播放任意视频文件`并 `绑定你想要调整的动画弹幕库`

3.然后就可以参考下方详细教程对弹幕源进行操作并使所有用户同步操作内容了

**为动画添加弹幕源**

如果你想为一部动画添加弹幕可以使用 `视频设置菜单`-→`弹幕列表`-→`添加更多弹幕` 这项功能添加对应的弹幕

> [!NOTE]
> 如果想使API（本插件）弹幕同步操作内容请将链接重复添加三次（弹弹play投票抉择机制）

**为动画弹幕源调整延迟**

如果你想为动画弹幕源修改延迟，请在 `视频设置菜单`-→`编辑弹幕来源`中复制下你要编辑的弹幕源的具体网址，然后点击删除，然后使用 `视频设置菜单`-→`弹幕列表`-→`添加更多弹幕` 这项功能进行重新添加，添加时在下方 `已选弹幕`中更改 `弹幕偏移`（单位为秒）调整延迟，然后依旧是重复添加三次就能使API弹幕同步了

另外，弹弹play的弹幕源一直是人工维护人工绑定制，感谢所有用此方式做贡献的人

## 特别感谢

感谢以下项目为本项目提供了实现参考或者外部依赖

- 弹幕api：[弹弹play](https://github.com/kaedei/dandanplay-libraryindex/blob/master/api/OpenPlatform.md)
- 菜单api：[uosc](https://github.com/tomasklaen/uosc)
- 弹幕格式解析转换：[DanmakuConvert](https://github.com/timerring/DanmakuConvert)
- 简繁转换：[OpenCC](https://github.com/BYVoid/OpenCC)
- lua原生md5计算实现：https://github.com/rkscv/danmaku
- lua原生zip解压缩实现：[lua-inflate](https://github.com/TohruMKDM/lua-inflate)
- 爱优腾及芒果TV的弹幕解析参考：https://github.com/lyz05/danmaku
- 弹幕相似度合并算法参考（行为复刻，未复制源码/数据）：[pakku.js](https://github.com/xmcp/pakku.js)（GPLv3, by xmcp）
- 拼音字典数据源：[pinyin-data](https://github.com/mozillazg/pinyin-data)（MIT）
- b站在线播放弹幕获取实现参考：[MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments)
- 巴哈姆特在线播放弹幕获取实现参考：[MPV-Play-BAHA-Comments](https://github.com/s594569321/MPV-Play-BAHA-Comments)

## 相关项目

- [slqy123/uosc_danmaku](https://github.com/slqy123/uosc_danmaku) 本项目的fork版本，实现了通过dandanplay api发送弹幕的功能，由于版本的兼容性以及功能的易用性问题未被合并，具体讨论请参阅 [#220](https://github.com/Tony15246/uosc_danmaku/pull/220)
- ~~[Loukyuu1120/uosc_danmaku](https://github.com/Loukyuu1120/uosc_danmaku) 本项目的fork版本，实现了自定义多个 api_servers 与 弹幕来源选择菜单 功能，具体讨论请参阅 [#282](https://github.com/Tony15246/uosc_danmaku/issues/282)~~ 相关功能主仓库已实现
