-- search_hub 纯函数单元测试（分组构建/进度行/provider 标签映射/ddp 搜索响应解析）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local hub = require("modules/search_hub")
local utils = require("mp.utils")
require("modules/utils") -- provider_label_from_url 等全局

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function read_fixture(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

-- ---------- build_grouped_items ----------

do
    local d_item = { title = "番剧A", hint = "TV动画", value = { "v", 1 } }
    local t_item = { title = "番剧A", hint = "动漫 | 2023", value = { "v", 2 } }
    local k_item = { title = "番剧A", hint = "动漫 | 2023 | 来源：b 站", value = { "v", 3 } }
    local m_item = { title = "番剧A", hint = "2023|国产动漫|x.com|全24集", value = { "v", 4 } }

    local items = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = { t_item } },
        kan360 = { items = { k_item } },
        maccms = { items = { m_item } },
    })
    check("四组顺序 dandanplay→腾讯→360kan→maccms",
        #items == 8
        and items[1].title == "── dandanplay ──" and items[2] == d_item
        and items[3].title == "── 腾讯 ──" and items[4] == t_item
        and items[5].title == "── 360kan ──" and items[6] == k_item
        and items[7].title == "── maccms ──" and items[8] == m_item)

    local h = items[1]
    check("组头形状 bold/不可选/居中",
        h.bold == true and h.selectable == false and h.align == "center" and h.keep_open == true)

    -- nil 键整组跳过（源未参与，如未配置 maccms）
    local items2 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = { t_item } },
        kan360 = { items = { k_item } },
    })
    check("nil 组跳过", #items2 == 6 and items2[7] == nil)

    -- 空结果组隐藏（连组头都不出）
    local items3 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = {} },
        kan360 = { items = { k_item } },
    })
    check("空组隐藏", #items3 == 4 and items3[1].title == "── dandanplay ──"
        and items3[3].title == "── 360kan ──")

    -- 失败组：组头 + 错误行（占住组位）
    local items4 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { err = "请求失败" },
        kan360 = { err = "超时" },
    })
    check("错误组=组头+错误行", #items4 == 6
        and items4[3].title == "── 腾讯 ──" and items4[4].title == "请求失败"
        and items4[5].title == "── 360kan ──" and items4[6].title == "超时")
    check("错误行形状 italic/muted/不可选",
        items4[4].italic == true and items4[4].muted == true and items4[4].selectable == false)

    -- has_more：dandanplay 组条目后追加截断提示行；其它组不受影响
    local items6 = hub.build_grouped_items({
        dandanplay = { items = { d_item }, has_more = true },
        tencent = { items = { t_item } },
    })
    check("has_more 组内追加截断提示行", #items6 == 5
        and items6[2] == d_item
        and items6[3].title == "ⓘ 结果过多已截断，可细化关键词"
        and items6[4].title == "── 腾讯 ──")
    check("截断行形状 italic/muted/不可选/居中",
        items6[3].italic == true and items6[3].muted == true
        and items6[3].selectable == false and items6[3].align == "center"
        and items6[3].value == "")
    check("has_more 但空条目不出行（空组仍隐藏）",
        #hub.build_grouped_items({ dandanplay = { items = {}, has_more = true } }) == 1)
    check("无 has_more 不出提示行",
        #hub.build_grouped_items({ dandanplay = { items = { d_item } } }) == 2)

    -- 全空/全 nil → 单行「无结果」
    local items5 = hub.build_grouped_items({
        dandanplay = { items = {} },
        tencent = { items = {} },
        kan360 = { items = {} },
    })
    check("全空→单行无结果", #items5 == 1 and items5[1].title == "无结果"
        and items5[1].selectable == false and items5[1].italic == true)
    check("空表入参→单行无结果", #hub.build_grouped_items({}) == 1)
end

-- ---------- progress_title / progress_row ----------

do
    local title = hub.progress_title({
        dandanplay = { status = "pending", done = 2, total = 3 },
        tencent = { status = "done", count = 5 },
        kan360 = { status = "pending" },
        maccms = { status = "error" },
    })
    check("进度标题混合态",
        title:find("dandanplay 2/3", 1, true) ~= nil
        and title:find("腾讯 ✓ 5条", 1, true) ~= nil
        and title:find("360kan 搜索中", 1, true) ~= nil
        and title:find("maccms ✗", 1, true) ~= nil)

    local title2 = hub.progress_title({
        dandanplay = { status = "done", count = 0 },
    })
    check("nil 源不显示/完成0条", title2:find("dandanplay ✓ 0条", 1, true) ~= nil
        and title2:find("腾讯", 1, true) == nil)

    local row = hub.progress_row("聚合搜索中 ...")
    check("进度行形状 italic+spinner+不可选（strip 兼容）",
        row.italic == true and row.icon == "spinner" and row.selectable == false
        and row.value == "")
end

-- ---------- parse_search_episodes（ddp v2/旧端点响应解析与归一） ----------
-- fixtures 来源：
--   ddp_search_episodes_frieren.json —— v2 端点形状（animes[].{animeId,animeTitle,type,
--     typeDescription,episodes[]} + hasMore），按 danmu-api（huangxd-/danmu_api）worker.js 的
--     searchEpisodes 构造器合成、episodeId/标题取自默认代理 /bangumi/17617 实抓（2026-10-13）；
--     官方端点因 IP 屏蔽无法实抓，字段集与 Kazumi DanmakuSearchResponse 模型核对一致
--   ddp_search_episodes_hasmore.json —— 同上形状的 hasMore=true 截断变体（合成）
--   ddp_search_anime_frieren.json —— 默认代理 /search/anime 实抓（2026-10-13）
--   ddp_search_episodes_unsupported.json —— 默认代理对 v2 端点的 404 "Unsupported API" 实抓

do -- v2 形状：支持、animeId→bangumiId 归一为字符串、内嵌 episodes 忽略
    local parsed = hub.parse_search_episodes(
        utils.parse_json(read_fixture("ddp_search_episodes_frieren.json")))
    check("v2 支持判定", parsed.supported == true)
    check("v2 两条目", #parsed.animes == 2, ("got %d"):format(#parsed.animes))
    local a1 = parsed.animes[1]
    check("v2 animeId 数字归一为字符串 bangumiId",
        a1.bangumiId == "17617" and type(a1.bangumiId) == "string", tostring(a1.bangumiId))
    check("v2 标题/typeDescription/type 透传",
        a1.animeTitle == "葬送的芙莉莲" and a1.typeDescription == "TV动画" and a1.type == "tvseries")
    check("v2 第二条目", parsed.animes[2].bangumiId == "18886"
        and parsed.animes[2].animeTitle == "葬送的芙莉莲 第二季")
    check("v2 hasMore=false", parsed.has_more == false)
    check("v2 内嵌 episodes 不透传", a1.episodes == nil)
end

do -- hasMore=true 截断变体
    local parsed = hub.parse_search_episodes(
        utils.parse_json(read_fixture("ddp_search_episodes_hasmore.json")))
    check("v2 截断判定 supported", parsed.supported == true and #parsed.animes == 1)
    check("v2 has_more=true", parsed.has_more == true)
end

do -- 旧端点形状（默认代理实抓）：支持、bangumiId 字符串保持
    local parsed = hub.parse_search_episodes(
        utils.parse_json(read_fixture("ddp_search_anime_frieren.json")))
    check("旧端点形状按支持处理", parsed.supported == true)
    check("旧端点两条目", #parsed.animes == 2)
    check("旧端点 bangumiId 字符串保持", parsed.animes[1].bangumiId == "17617"
        and type(parsed.animes[1].bangumiId) == "string")
    check("旧端点无 hasMore → false", parsed.has_more == false)
end

do -- 默认代理对 v2 端点的 "Unsupported API"：不支持（触发回退的判据）
    local parsed = hub.parse_search_episodes(
        utils.parse_json(read_fixture("ddp_search_episodes_unsupported.json")))
    check("Unsupported API 判不支持", parsed.supported == false
        and #parsed.animes == 0 and parsed.has_more == false)
end

do -- 边界：非表入参 / 空结果（支持但零条）/ 畸形条目跳过 / hasMore 键存在即支持
    check("nil 入参不支持", hub.parse_search_episodes(nil).supported == false)
    check("字符串入参不支持", hub.parse_search_episodes("{}").supported == false)
    local empty = hub.parse_search_episodes(
        utils.parse_json('{"errorCode":0,"success":true,"hasMore":false,"animes":[]}'))
    check("空结果支持且零条目", empty.supported == true and #empty.animes == 0)
    local only_flag = hub.parse_search_episodes(utils.parse_json('{"hasMore":false}'))
    check("仅 hasMore 键也算支持", only_flag.supported == true and #only_flag.animes == 0)
    local dirty = hub.parse_search_episodes(utils.parse_json(
        '{"animes":[{"animeTitle":"有id","animeId":42},' ..
        '{"animeTitle":"无id"},{"animeId":43},' ..
        '{"animeTitle":"数字串id","bangumiId":"100"},"五"]}'))
    check("畸形条目跳过（缺id/缺标题/非表条目）", #dirty.animes == 2
        and dirty.animes[1].bangumiId == "42" and dirty.animes[2].bangumiId == "100",
        utils.format_json(dirty.animes))
end

-- ---------- provider_label_from_url（utils） ----------

do
    check("provider bilibili",
        provider_label_from_url("https://www.bilibili.com/bangumi/play/ep123") == "bilibili")
    check("provider bilivideo",
        provider_label_from_url("https://upos.example.com/xx") == nil -- 无匹配 host
        and provider_label_from_url("https://xy123.bilivideo.cn/a.m4s") == "bilibili")
    check("provider 腾讯",
        provider_label_from_url("https://v.qq.com/x/cover/a/b.html") == "腾讯视频")
    check("provider 爱奇艺/优酷/芒果/巴哈",
        provider_label_from_url("https://www.iqiyi.com/v_1.html") == "爱奇艺"
        and provider_label_from_url("https://v.youku.com/v_show/id_x.html") == "优酷"
        and provider_label_from_url("https://www.mgtv.com/b/1/2.html") == "芒果TV"
        and provider_label_from_url("https://bahamut.akamaized.net/x") == "巴哈姆特")
    check("provider 未知/非串",
        provider_label_from_url("https://unknown.example/a") == nil
        and provider_label_from_url(nil) == nil
        and provider_label_from_url(123) == nil)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
