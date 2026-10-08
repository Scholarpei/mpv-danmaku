local opt = require("mp.options")

-- 选项
options = {
    -- 指定弹幕服务器地址，自定义服务需兼容 dandanplay 的 api
    -- 可指定多个用逗号分隔的有序 api_server 列表
    -- 支持每项使用 '|' 或 '#' 分隔备注，例如: "https://a.example.com|备用A" 或 "https://b.example.com#备用B"
    api_server = "https://danmaku-api.152468.xyz",
    -- 指定 b 站和爱腾优的弹幕获取的兜底服务器地址，主要用于获取非动画弹幕
    -- 可用： https://dmku.hls.one
    fallback_server = "https://dmku.hls.one",
    -- 设置 tmdb 的 API Key，用于获取非动画条目的中文信息(当搜索内容非中文时)
    -- 可以在 https://www.themoviedb.org 注册后去个人账号设置界面获取
    -- 注意：自定义此参数时还需要对获取到的 API Key 进行 base64 编码
    tmdb_api_key = "NmJmYjIxOTZkNzIyN2UyMTIzMGM3Y2YzZjQ4MDNkZGM=",
    -- 自动加载弹幕开关
    auto_load = false,
    -- 自动加载可能支持的 url 视频文件实现弹幕关联记忆和继承，配合播放列表食用效果最佳
    autoload_for_url = false,
    -- 当自动弹幕加载失败时，自动弹出搜索框让用户手动搜索
    auto_fallback_search = false,
    -- 自动加载播放文件同目录下同名的 xml 格式的弹幕文件
    autoload_local_danmaku = false,
    -- B站合集弹幕记忆：在文件夹内任一集手动添加过B站视频弹幕源后，同文件夹其他剧集
    -- 播放时自动按分P标题/集数差/时长匹配对应分P并加载弹幕（每文件夹最多记忆 3 个视频）
    -- off-关闭 / add-与自动填装叠加加载 / first-匹配成功时优先仅用B站源（失败回退自动填装）
    -- 非法值回落 add
    bilibili_series_memory = "add",
    -- 播放结束时自动保存弹幕为xml文件
    save_danmaku = false,
    -- 指定弹幕保存目录。为空时保存到视频同目录；目录需要用户提前创建
    save_danmaku_path = "",
    -- 指定 save_danmaku_path 的应用范围：local / url / all
    save_danmaku_path_mode = "local",
    -- 向 HTTP 请求时使用的 User Agent
    user_agent = "mpv_danmaku/1.0",
    -- 可选：向 HTTP 请求时使用的代理，默认禁用
    proxy = "",
    -- 可选：向 HTTP 请求传递 cookie.txt 文件路径
    cookie_file = "",
    -- 使用 fps 视频滤镜，大幅提升弹幕平滑度。默认禁用
    vf_fps = false,
    -- 设置要使用的 fps 滤镜参数
    fps = "60/1.001",
    -- pakku 式弹幕相似度合并总开关（完全相同/字符多重集/拼音谐音/二元组余弦四通道，参考 pakku.js）
    merge_enabled = true,
    -- 合并时间窗口，单位为秒：时间差在窗口内的相似弹幕合并为一簇。pakku 默认 30；<=0 禁用合并
    merge_tolerance = 30,
    -- 是否跨模式合并（滚动/顶部/底部互并，合并后模式提升 底部>顶部>滚动）。
    -- 原 merge_without_style=yes 等价于现在的默认行为
    merge_cross_mode = true,
    -- 拼音谐音合并（如「泪目/累目」），依赖 dicts/pinyin_chars.lua，字典缺失时自动禁用
    merge_pinyin = true,
    -- 相似度强度四档：off-禁用 / light-轻微 / medium-中等 / strong-强力。
    -- 映射合并引擎的 max_dist/max_cosine（自拟插值档，medium = pakku 默认 5/45）；非法值回落 medium
    merge_similarity = "medium",
    -- 套路规则重写：合并比较前先按规则改写文本（如任意长「2333…」统一为「23333」）。
    -- 多条规则用 | 分隔，格式 pattern=>replacement，Lua pattern 语法
    merge_forcelist = "^2333+=>23333|^666+=>66666",
    -- 顶部弹幕转为滚动弹幕：no-不转 / yes-全部转（pakku 惯例加 ↑ 前缀）/
    -- auto-仅超宽的转（pakku SCROLL_THRESHOLD 语义，短固定弹幕保留原样）
    convert_top_to_scroll = false,
    -- 底部弹幕转为滚动弹幕：no-不转 / yes-全部转（加 ↓ 前缀）/ auto-仅超宽的转
    convert_bottom_to_scroll = false,
    -- auto 模式的宽度阈值（像素，按 fontsize 估算文本宽度）。pakku 默认 1200；<=0 等同禁用 auto
    scroll_threshold = 1200,
    -- 黑名单过滤开关（规则文件见 blacklist_path，可在菜单中热重载）
    blacklist_enabled = true,
    -- 合并弹幕字号的对数增长系数，必须为正整数
    merge_fontsize_growth = 8,
    -- 合并弹幕允许使用的最大字号
    merge_fontsize_max = 100,
    -- 指定弹幕关联历史记录文件的路径，支持绝对路径和相对路径
    history_path = "~~/danmaku-history.json",
    -- 自定义插件快捷键，若 mpv.conf 里设置 input-default-bindings=no 将禁用以下两个选项
    open_search_danmaku_menu_key = "Ctrl+d",
    show_danmaku_keyboard_key = "j",
    -- 中文简繁转换。0-不转换，1-转换为简体，2-转换为繁体
    chConvert = 0,
    --滚动弹幕的显示时间
    scrolltime = 15,
    --固定弹幕的显示时间
    fixtime = 5,
    --字体
    fontname = "sans-serif",
    --字体大小 
    fontsize = 50,
    --字体阴影
    shadow = 0,
    --字体粗体
    bold = true,
    -- 透明度：0（完全透明）到 1（不透明）
    opacity = 0.7,
    --全部弹幕的显示范围(0.0-1.0)
    displayarea = 0.85,
    --描边 0-4
    outline = 1.0,
    -- 限制屏幕中同时显示的最大弹幕数量，0 表示不限制（仅 density_control=simple 简单模式时生效）
    max_screen_danmaku = 0,
    -- 弹幕密度控制模式：off-不控制 / simple-简单模式（同屏条数上限随机丢弃，仅此模式读取
    -- max_screen_danmaku）/ smart-智能模式（pakku 式：按视觉密度先等比缩小字号，超更硬阈值再
    -- 按权重概率丢弃，未合并弹幕先死、xN 合并弹幕受保护）。默认 smart；非法值回落 smart
    density_control = "smart",
    -- 智能密度强度三档：loose-宽松 / medium-中等 / strict-严格，映射（收缩阈值, 丢弃阈值）
    -- 两个 dispval 密度档位；非法值回落 medium。仅 density_control=smart 时生效
    density_level = "medium",
    --指定弹幕屏蔽词文件路径(black.txt)，支持绝对路径和相对路径。文件内容以换行分隔
    --支持 lua 的正则表达式写法
    blacklist_path = "",
    --指定脚本相关消息显示的消息的对齐方式
    message_anlignment = 7,
    --指定脚本相关消息显示的消息的x轴坐标
    message_x = 30,
    --指定脚本相关消息显示的消息的y轴坐标
    message_y = 30,
    -- 自定义标题解析中的额外替换规则，内容格式为 JSON 字符串，替换模式为 lua 的 string.gsub 函数
    --! 注意：由于 mpv 的 lua 版本限制，自定义规则只支持形如 %n 的捕获组写法，即示例用法，不支持直接替换字符的写法
    title_replace = [[
       [{ 
           "rules": [{ "^〔(.-)〕": "%1"},{ "^.*《(.-)》": "%1" }],
       }]
    ]],
    -- 指定哈希匹配中需忽略的共享盘（挂载盘）的路径/目录。支持绝对路径和相对路径，多个路径用逗号分隔
    -- 示例：["X:", "Z:", "F:/Download/", "Download"]
    excluded_path = [[
        []
    ]],
}

opt.read_options(options, mp.get_script_name(), function() end)
