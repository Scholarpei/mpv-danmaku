-- 弹幕源状态聚合器单元测试（modules/source_status.lua + utils 格式化函数）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local source_status = require("modules/source_status")
require("modules/utils")  -- utf8_sub / abbr_str / provider_label_from_url / 标题格式化全局

-- stub：捕获 OSD 输出与时长
local osd = {}
show_message = function(text, time)
    osd[#osd + 1] = { text = tostring(text), time = time }
end
DANMAKU = { sources = {} }

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function last_osd()
    return osd[#osd] or {}
end

do -- utils：short_episode_title（简体/繁体/无前缀/尾随空格）
    check("话标题截取", short_episode_title("第12话 某某标题") == "第12话")
    check("繁体話标题截取", short_episode_title("第3話 繁體標題") == "第3話")
    check("集标题截取", short_episode_title("第5集") == "第5集")
    check("无前缀原样", short_episode_title("电影") == "电影")
    check("EP格式原样", short_episode_title("EP12") == "EP12")
    check("B站分P名原样保留", short_episode_title("P2 某分P标题") == "P2 某分P标题")
end

do -- utils：source_display_title（截断/回退/自定义URL长度）
    check("标题+集数",
        source_display_title({anime_title = "转生史莱姆", episode_title = "第12话 某某"}, "u") == "《转生史莱姆》第12话")
    local long = string.rep("字", 25)
    local inside = source_display_title({anime_title = long, episode_title = "第1话"}, "u"):match("《(.+)》")
    check("动画名截断到18", utf8_len(inside) == 21 and inside:sub(-3) == "...", inside)
    check("无标题回退URL",
        source_display_title({episode_title = "第1话"}, "https://v.qq.com/x/cover/a/b.html") == "https://v.qq.com/x/cover/a/b.html")
    check("无标题URL自定义截断",
        utf8_len(source_display_title({}, "https://v.qq.com/x/cover/a/b.html", 10)) == 10)
    check("无集数仅动画名", source_display_title({anime_title = "电影名"}, "u") == "《电影名》")
end

do -- 状态机：begin → 等待行 → header
    source_status.begin({
        { key = "extra:qq", provider = "腾讯视频", anime = "扫黑风暴" },
        { key = "extra:youku", provider = "优酷", anime = "扫黑风暴" },
    })
    check("begin后current_epoch非空", source_status.current_epoch() ~= nil)
    check("begin即刷新OSD", #osd == 1)
    check("等待时长30", last_osd().time == 30)
    local lines = source_status.format_lines()
    check("等待header", lines[1] == "弹幕加载中：", lines[1])
    check("等待行1", lines[2] == "· 腾讯视频《扫黑风暴》 等待中…", lines[2])
    check("等待行2", lines[3] == "· 优酷《扫黑风暴》 等待中…", lines[3])
    check("has_pending真", source_status.has_pending() == true)
end

do -- ensure 换键：extra:kind 占位条目 → 真实 URL，meta 补全标题
    source_status.ensure("https://v.qq.com/x/cover/a/b.html", "腾讯视频",
        { anime = "扫黑风暴 (2021)", episode = "第3集", kind = "qq" })
    local lines = source_status.format_lines()
    check("换键后等待行升级标题",
        lines[2] == "· 腾讯视频《扫黑风暴 (2021)》第3集 等待中…", lines[2])
    check("条目数不变（换键非追加）", #lines == 3, #lines)
end

do -- 自动完成检测：DANMAKU.sources[url] 有数据即转 done
    DANMAKU.sources["https://v.qq.com/x/cover/a/b.html"] = {
        provider = "腾讯视频", anime_title = "扫黑风暴 (2021)", episode_title = "第3集",
        data = { 1, 2, 3, 4, 5 },
    }
    local lines = source_status.format_lines()
    check("完成header（尚有等待源）", lines[1] == "弹幕加载中：", lines[1])
    check("完成行带条数", lines[2] == "· 腾讯视频《扫黑风暴 (2021)》第3集 5条", lines[2])
    check("另一源仍等待", lines[3] == "· 优酷《扫黑风暴》 等待中…", lines[3])
    check("has_pending仍真", source_status.has_pending() == true)
end

do -- mark_failed：会话内折进汇总；对已完成条目忽略
    source_status.mark_failed("extra:youku", "无法获取剧集列表", "优酷弹幕续载失败")
    local lines = source_status.format_lines()
    check("失败header（有成功有失败）", lines[1] == "弹幕已加载：", lines[1])
    check("失败行", lines[3] == "✗ 优酷：无法获取剧集列表", lines[3])
    check("失败刷新时长6（全终态）", last_osd().time == 6, last_osd().time)
    -- 已 done 的条目（换键后）不受过期失败污染
    source_status.mark_failed("extra:qq", "过期回调误标", nil)
    lines = source_status.format_lines()
    check("done条目不受mark_failed影响", lines[2]:find("5条") ~= nil, lines[2])
    -- 未登记的 key 忽略
    source_status.mark_failed("extra:notexist", "不存在", nil)
    check("未登记key忽略", #source_status.format_lines() == 3)
end

do -- mark_done：显式完成（B站合集临时键），count 按 url 查源条目
    source_status.begin({
        { key = "bilibili#12345", provider = "bilibili", anime = "某番剧" },
    })
    DANMAKU.sources["https://www.bilibili.com/video/BV1xx?p=2"] = {
        anime_title = "某番剧", episode_title = "P2 标题", data = { 1, 2, 3 },
    }
    source_status.mark_done("bilibili#12345",
        { anime = "某番剧", episode = "P2 标题", url = "https://www.bilibili.com/video/BV1xx?p=2" })
    local lines = source_status.format_lines()
    check("mark_done行", lines[2] == "· bilibili《某番剧》P2 标题 3条", lines[2])
    check("全终态header", lines[1] == "弹幕已加载：", lines[1])
end

do -- 无会话 mark_failed 退化单行（label 前缀与旧独立报错口径一致）
    source_status.reset()
    local n = #osd
    source_status.mark_failed("extra:qq", "无法获取剧集列表", "腾讯弹幕续载失败")
    check("退化单行", last_osd().text == "✗ 腾讯弹幕续载失败：无法获取剧集列表", last_osd().text)
    check("退化只弹一条", #osd == n + 1)
end

do -- 无会话 format_lines：遍历已加载源、按显示名排序、确定性
    local lines = source_status.format_lines()
    check("无会话列出已加载源",
        lines[1] == "弹幕已加载：" and lines[2] == "· bilibili《某番剧》P2 标题 3条"
            and lines[3] == "· 腾讯视频《扫黑风暴 (2021)》第3集 5条",
        table.concat(lines, " / "))
    check("无会话has_pending假", source_status.has_pending() == false)
    check("无会话refresh返回false", source_status.refresh() == false)
end

do -- 无会话 + 无已加载源：空表（show_loaded 回退仅统计行）
    DANMAKU.sources = {}
    check("无源空表", #source_status.format_lines() == 0)
end

do -- 缓存标注 header（读 DANMAKU.cache_hit，不消费）
    DANMAKU.sources = { ["https://x/y"] = { provider = "ddp", anime_title = "A", episode_title = "第1话", data = { 1 } } }
    DANMAKU.cache_hit = "cache"
    check("缓存header", source_status.format_lines()[1] == "弹幕已加载（缓存）：")
    DANMAKU.cache_hit = "stale"
    check("离线缓存header", source_status.format_lines()[1] == "弹幕已加载（离线缓存）：")
    DANMAKU.cache_hit = nil
end

do -- kind_provider_label 映射与回退
    check("qq标签", source_status.kind_provider_label("qq") == "腾讯视频")
    check("360kan标签", source_status.kind_provider_label("360kan") == "360kan")
    check("未知kind回退", source_status.kind_provider_label("nosuch") == "弹幕源")
end

do -- provider 回退链：条目无 provider 时按 URL 域名推断
    source_status.begin({ { key = "https://v.qq.com/x/cover/a/b.html", anime = "X" } })
    local lines = source_status.format_lines()
    check("URL域名推断provider", lines[2] == "· 腾讯视频《X》 等待中…", lines[2])
    source_status.reset()
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
