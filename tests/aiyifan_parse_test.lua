-- 爱壹帆 App API 签名与搜索/选集/详情/弹幕解析单元测试
-- （基于 2026-10-13 实抓的 tests/fixtures/ayf_* 样本；弹幕样本已剥离用户资料字段，
--   弹幕相关字段 color/contxt|content/position/second/good 原样保留）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local aparse = require("modules/aiyifan_parse")
local utils = require("mp.utils")

local function read_json(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local content = f:read("*all")
    f:close()
    return utils.parse_json(content)
end

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

do -- app_sign：固定输入输出（向量由 python hashlib 独立计算）
    check("GET 弹幕签名向量", aparse.app_sign(
        "mediaKey=aIEHicrw641&videoId=912438&videoType=1", "1791900000", "testPrivateKey01")
        == "55cc749c4dd44d599bad61de1d473c7c")
    check("GET 详情签名向量", aparse.app_sign(
        "mediaKey=aIEHicrw641&videoType=1&episodeKey=A0MkTzRVXyc", "1791900555", "testPrivateKey01")
        == "73238a77bd2370f1d415e13563ed3b9e")
    check("POST 搜索签名向量", aparse.app_sign(
        "_t=1791900666", "1791900666", "testPrivateKey01")
        == "e050a2df209333aefa2549cbe7ae0662")
    check("config 引导默认私钥向量", aparse.app_sign(
        "_t=1791900777", "1791900777", aparse.DEFAULT_PRIVATE_KEY)
        == "f71fd297a8c9caf23ab73da38abc3bd6")
    check("数字时间戳与字符串同构", aparse.app_sign("_t=1", 1, "k")
        == aparse.app_sign("_t=1", "1", "k"))
end

do -- build_sign_query：GET 参数按序拼接 / POST 固定 _t / 空参数回退 / nil 值跳过
    check("POST 固定 _t", aparse.build_sign_query("POST", nil, 1791900000) == "_t=1791900000")
    check("GET 参数按序拼接", aparse.build_sign_query("GET", {
        { "mediaKey", "aIEHicrw641" }, { "videoId", 912438 }, { "videoType", 1 },
    }, 1791900000) == "mediaKey=aIEHicrw641&videoId=912438&videoType=1")
    check("GET 空参数回退 _t", aparse.build_sign_query("GET", nil, 1791900000) == "_t=1791900000")
    check("GET 空表回退 _t", aparse.build_sign_query("GET", {}, 1791900000) == "_t=1791900000")
    check("GET nil 值项跳过", aparse.build_sign_query("GET", {
        { "a", 1 }, { "b", nil }, { "c", 3 },
    }, 1) == "a=1&c=3")
end

do -- parse_config：实抓 home/config（pConfig.publicKey + privateKey 数组取 [1]）
    local parsed = aparse.parse_config(read_json("ayf_config.json"))
    check("config ok", parsed.ok)
    check("config publicKey", parsed.public_key == "CJSvCJamD34pD2unC30vDryfewzCZ0sBZ4uEIunD3GkCJCvNsHXD6OqD3PZEJ9YPJHYCZSvE3XYPMOpDZ4tDJCuCMCoNpbcCpGtP35aCsOqDZ1ZOZWpD3DYCZCoPZ8rP34uPJPb", parsed.public_key)
    check("config privateKey 取数组首项", parsed.private_key == "SvCJJSvCJamD34pD2unC", parsed.private_key)
    check("config privateKey 字符串变体", aparse.parse_config(
        { ret = 200, data = { list = { pConfig = { publicKey = "pub", privateKey = "priv" } } } }).ok)
    check("config privateKey 空数组不 ok", not aparse.parse_config(
        { ret = 200, data = { list = { pConfig = { publicKey = "pub", privateKey = {} } } } }).ok)
    check("config 缺 pConfig 不 ok", not aparse.parse_config(
        { ret = 200, data = { list = {} } }).ok)
    check("config ret≠200 不 ok", not aparse.parse_config({ ret = 401, msg = "sign error" }).ok)
    check("config 非表安全", not aparse.parse_config(nil).ok)
end

do -- parse_search：葬送的芙莉莲关键词（25 条，动漫/电影/电视剧/综艺混合）
    local parsed = aparse.parse_search(read_json("ayf_search_frieren.json"))
    check("搜索 ok", parsed.ok)
    check("搜索条目数=25", #parsed.items == 25, ("got %d"):format(#parsed.items))
    local it1 = parsed.items[1]
    check("首条目 芙莉莲 动漫·冒险", it1.media_key == "aIEHicrw641" and it1.title == "葬送的芙莉莲"
        and it1.media_type == "动漫" and it1.content_type == "冒险", utils.format_json(it1))
    check("第2条目 第2季", parsed.items[2].media_key == "Ayxok89CKkM"
        and parsed.items[2].title == "葬送的芙莉莲第2季" and parsed.items[2].media_type == "动漫")
    check("第3条目 电影·剧情", parsed.items[3].media_key == "4y2lBuLyXio"
        and parsed.items[3].media_type == "电影" and parsed.items[3].content_type == "剧情")
    -- 搜索响应内嵌 episodes 仅 6 条预览且无 uniqueID：parse_search 不产出分集（真选集走选集接口）
    check("搜索不产出内嵌分集", parsed.items[1].episodes == nil and parsed.items[1].episode_count == nil)
    check("无 mediaKey 条目跳过", (function()
        local p = aparse.parse_search({ ret = 200, data = { list = {
            { title = "有key", mediaKey = "abc" },
            { title = "无key无id" },
            { mediaKey = "无标题" },
        } } })
        return p.ok and #p.items == 1 and p.items[1].media_key == "abc"
    end)())
    check("空结果 ok 空表", (function()
        local p = aparse.parse_search({ ret = 200, data = { list = {} } })
        return p.ok and #p.items == 0
    end)())
    check("搜索 ret≠200 不 ok", not aparse.parse_search({ ret = 401 }).ok)
    check("搜索 非表安全", not aparse.parse_search(nil).ok)
end

do -- parse_episodes：芙莉莲 28 集（升序；ep5 起 uniqueID 与 episodeId 分叉）
    local parsed = aparse.parse_episodes(read_json("ayf_episodes_frieren.json"))
    check("选集 ok", parsed.ok)
    check("集数=28", #parsed.episodes == 28, ("got %d"):format(#parsed.episodes))
    local e1 = parsed.episodes[1]
    check("第1集形状", e1.episode_key == "OUOLuGAsKu5" and e1.video_id == "912438"
        and e1.title == "01" and e1.video_type == "1", utils.format_json(e1))
    -- ep5 uniqueID=914774 / episodeId=914790：video_id 必须取 uniqueID（用 episodeId 实测返回空弹幕）
    check("第5集 video_id=uniqueID≠episodeId", parsed.episodes[5].video_id == "914774",
        parsed.episodes[5].video_id)
    check("末集=第28集", parsed.episodes[28].title == "28"
        and parsed.episodes[28].episode_key == "y1LANEZOJKH")
    check("video_id 全表唯一", (function()
        local seen = {}
        for _, e in ipairs(parsed.episodes) do
            if seen[e.video_id] then return false end
            seen[e.video_id] = true
        end
        return true
    end)())
    check("选集 ret≠200 不 ok", not aparse.parse_episodes({ ret = 401 }).ok)
    check("选集 非表安全", not aparse.parse_episodes(nil).ok)
end

do -- parse_episodes：剧场版单集（videoType=0、episodeTitle="1"）
    local parsed = aparse.parse_episodes(read_json("ayf_episodes_movie.json"))
    check("剧场版 ok 单集", parsed.ok and #parsed.episodes == 1)
    check("剧场版形状（videoType=0 透传）", parsed.episodes[1].episode_key == "bT1njOJMAdE"
        and parsed.episodes[1].video_id == "173193" and parsed.episodes[1].video_type == "0"
        and parsed.episodes[1].title == "1", utils.format_json(parsed.episodes[1]))
    check("缺 uniqueID 回退 episodeId", (function()
        local p = aparse.parse_episodes({ ret = 200, data = { list = {
            { episodeKey = "ek", episodeId = 111 } } } })
        return p.ok and p.episodes[1].video_id == "111"
    end)())
end

do -- parse_details：老链接缺 videoId 补齐（uniqueID 优先）
    local p1 = aparse.parse_details(read_json("ayf_details_ep1.json"))
    check("详情 ep1 ok", p1.ok and p1.video_id == "912438" and p1.video_type == "1",
        utils.format_json(p1))
    local p5 = aparse.parse_details(read_json("ayf_details_ep5.json"))
    check("详情 ep5 补齐 uniqueID=914774", p5.ok and p5.video_id == "914774"
        and p5.video_type == "1", utils.format_json(p5))
    check("详情 缺 detailInfo 不 ok", not aparse.parse_details({ ret = 200, data = {} }).ok)
    check("详情 ret≠200 不 ok", not aparse.parse_details({ ret = 401 }).ok)
    check("详情 非表安全", not aparse.parse_details(nil).ok)
end

do -- parse_danmaku：芙莉莲 ep1（360 条；position 0滚动/1顶）
    local parsed = aparse.parse_danmaku(read_json("ayf_barrage_frieren_ep1.json"))
    check("弹幕 ok", parsed.ok)
    check("条数=360", #parsed.comments == 360, ("got %d"):format(#parsed.comments))
    local n1, n4, n5 = 0, 0, 0
    for _, c in ipairs(parsed.comments) do
        if c.mode == 1 then n1 = n1 + 1 elseif c.mode == 4 then n4 = n4 + 1
        elseif c.mode == 5 then n5 = n5 + 1 end
    end
    check("mode 分布 1×357/5×3/4×0", n1 == 357 and n5 == 3 and n4 == 0,
        ("1:%d 4:%d 5:%d"):format(n1, n4, n5))
    check("按 time 升序", (function()
        for i = 2, #parsed.comments do
            if parsed.comments[i].time < parsed.comments[i - 1].time then return false end
        end
        return true
    end)())
    check("时间字段为秒（末条 >1300s）", parsed.comments[#parsed.comments].time > 1300,
        tostring(parsed.comments[#parsed.comments].time))
    -- 色字段 "#ffffff"/"#FFFFFF" 大小写混合均换算为整数白
    local color_ok = false
    for _, c in ipairs(parsed.comments) do
        if c.text == "第一次，听说很好看" and c.color == 16777215 then color_ok = true break end
    end
    check("色 #RRGGBB→整数（大小写不敏感）", color_ok)
end

do -- parse_danmaku：海贼王 ep1（771 条；含 position=2 底部弹幕 1 条——站点播放器枚举
    -- Barrel=0/FixTop=1/FixBottom=2 实锤，danmu_api 把 2 当滚动此处修正为 4）
    local parsed = aparse.parse_danmaku(read_json("ayf_barrage_op_ep1.json"))
    check("海贼王弹幕 ok", parsed.ok)
    check("海贼王条数=771", #parsed.comments == 771, ("got %d"):format(#parsed.comments))
    local bottom, top_red = nil, nil
    for _, c in ipairs(parsed.comments) do
        if c.mode == 4 then bottom = c end
        if c.text == "Russia" then top_red = c end
    end
    check("position=2→mode4 底部（1 条）", bottom ~= nil and bottom.text == "1/18/2021"
        and bottom.time == 85 and bottom.color == 16646144, bottom and utils.format_json(bottom))
    check("position=1→mode5 顶部红字", top_red ~= nil and top_red.mode == 5
        and top_red.time == 400 and top_red.color == 16646144, top_red and utils.format_json(top_red))
end

do -- parse_danmaku：芙莉莲 ep5（196 条全滚动——episodeId 分叉集的正确 uniqueID 样本）
    local parsed = aparse.parse_danmaku(read_json("ayf_barrage_frieren_ep5.json"))
    check("ep5 弹幕 ok", parsed.ok)
    check("ep5 条数=196", #parsed.comments == 196, ("got %d"):format(#parsed.comments))
    local all_scroll = true
    for _, c in ipairs(parsed.comments) do
        if c.mode ~= 1 then all_scroll = false break end
    end
    check("ep5 全为滚动弹幕", all_scroll)
end

do -- parse_danmaku：合法空（错误 videoId 实测同口径——ret=200 且 list=[]）
    local empty = aparse.parse_danmaku(utils.parse_json(
        '{"ret":200,"data":{"list":[]},"msg":"ok"}'))
    check("合法空 ok 零条", empty.ok and #empty.comments == 0)
    check("弹幕 ret≠200 不 ok", not aparse.parse_danmaku({ ret = 401, msg = "sign error" }).ok)
    check("弹幕 非表安全", not aparse.parse_danmaku(nil).ok)
    -- 合成边界：contxt 缺失回退 content / 畸形条目跳过 / 未知 position 按滚动 / 无色兜底白
    local mixed = aparse.parse_danmaku({ ret = 200, data = { list = {
        { second = 1.5, position = 0, color = "#00ff00", contxt = "hi" },
        { second = 2.5, position = 1, color = "#ff0000", content = "顶（无contxt）" },
        { second = 3.5, position = 9, contxt = "未知position" },
        { second = 4.5, position = 0, color = "#zzzzzz", contxt = "坏色" },
        { second = "5.5", position = 2, color = "#ffffff", contxt = "字符串秒与底部" },
        { second = 6.5, contxt = "" },             -- 空文本跳过
        { position = 0, contxt = "缺秒跳过" },     -- 缺 second 跳过
        { second = 7.5, position = 0 },            -- 无文本跳过
        { second = 8.5, color = "#ffffff", contxt = 123 },  -- 非字符串文本跳过
    } } })
    check("合成边界 ok 收 5 条", mixed.ok and #mixed.comments == 5,
        ("got %d"):format(#mixed.comments))
    check("content 备选字段", mixed.comments[2].text == "顶（无contxt）" and mixed.comments[2].mode == 5)
    check("未知 position 按滚动", mixed.comments[3].mode == 1)
    check("坏色兜底白", mixed.comments[4].color == 16777215)
    check("字符串秒换算与底部", mixed.comments[5].time == 5.5 and mixed.comments[5].mode == 4)
    check("合成边界按 time 升序", mixed.comments[1].time == 1.5 and mixed.comments[5].time == 5.5)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
