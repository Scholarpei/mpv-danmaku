-- AcFun 搜索/视频页/合集页/弹幕解析单元测试（基于 2026-10 实抓的 tests/fixtures/acf_* 样本）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local aparse = require("modules/acfun_parse")
local utils = require("mp.utils")

local function read_file(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local content = f:read("*all")
    f:close()
    return content
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

do -- parse_search：孤独摇滚搜索页（BigPipe SSR，pagelet_video 30 条 + pagelet_album 3 条）
    local parsed = aparse.parse_search(read_file("acf_search.html"))
    check("搜索 ok", parsed.ok)
    local nv, na = 0, 0
    for _, it in ipairs(parsed.items) do
        if it.type == "video" then nv = nv + 1 elseif it.type == "album" then na = na + 1 end
    end
    check("视频条目数=30", nv == 30, ("got %d"):format(nv))
    check("合集条目数=3", na == 3, ("got %d"):format(na))
    -- 页面 pagelet 顺序：album 在 video 前（合集季包优先展示，适合追番场景）
    local first_album, first_video = nil, nil
    for _, it in ipairs(parsed.items) do
        if not first_album and it.type == "album" then first_album = it end
        if not first_video and it.type == "video" then first_video = it end
    end
    check("首条目为合集", parsed.items[1].type == "album")
    check("合集条目形状", first_album.aa_id ~= "" and first_album.title ~= "" and first_album.user ~= "",
        utils.format_json(first_album))
    check("视频条目形状", first_video.ac_id ~= "" and first_video.title ~= "" and first_video.user ~= "",
        utils.format_json(first_video))
    check("视频条目弹幕数字段", first_video.danmu:find("弹幕", 1, true) ~= nil, first_video.danmu)
    check("视频条目时长字段", first_video.duration:match("^%d+:%d+$") ~= nil, first_video.duration)
    local album_ok = false
    for _, it in ipairs(parsed.items) do
        if it.type == "album" and it.aa_id == "6115094" then
            album_ok = it.title == "孤独摇滚！OP ED"
            break
        end
    end
    check("合集条目字段（aa6115094 OP ED）", album_ok)
    check("空入参安全", aparse.parse_search("").ok and #aparse.parse_search("").items == 0)
    check("非字符串安全", aparse.parse_search(nil).ok == false)
end

do -- parse_video_page：ac40407984 单P（pageInfo.currentVideoInfo.id=30010597）
    local parsed = aparse.parse_video_page(read_file("acf_video_page.html"))
    check("视频页 ok", parsed.ok)
    check("videoList 单P", #parsed.videos == 1, ("got %d"):format(#parsed.videos))
    check("videoId=30010597", parsed.videos[1].video_id == "30010597", parsed.videos[1].video_id)
    check("标题非空", parsed.title ~= "" and parsed.user ~= "")
    check("多P 排序", (function()
        -- 构造合成 pageInfo 验证多P 顺序与提取（videoList 按序）
        local html = "window.pageInfo = " .. utils.format_json({
            title = "T", videoList = {
                { id = 111, title = "P1" }, { id = 222, title = "P2" }, { id = 333, title = "P3" },
            },
        }) .. ";"
        local p = aparse.parse_video_page(html)
        return p.ok and #p.videos == 3 and p.videos[2].video_id == "222" and p.videos[3].title == "P3"
    end)())
    check("空 page 安全", aparse.parse_video_page("<html></html>").ok == false)
    check("非字符串安全", aparse.parse_video_page(nil).ok == false)
end

do -- parse_album_page：aa6115094（5 个 DOUGA 分P，页面原序倒序、sort 升序为正片序）
    local parsed = aparse.parse_album_page(read_file("acf_album_page.html"))
    check("合集页 ok", parsed.ok)
    check("分P数=5", #parsed.parts == 5, ("got %d"):format(#parsed.parts))
    check("sort 升序首P为 op", parsed.parts[1].ac_id == "39477926" and parsed.parts[1].title:find("op", 1, true) ~= nil,
        utils.format_json(parsed.parts[1]))
    check("末P为 ED3.1", parsed.parts[5].ac_id == "40040169", parsed.parts[5].ac_id)
    check("空 page 安全", aparse.parse_album_page("<html></html>").ok == false)
    check("非字符串安全", aparse.parse_album_page(nil).ok == false)
end

do -- parse_danmaku：ac40407984 第0页实抓（200 条，pcursor="2"）
    local parsed = aparse.parse_danmaku(utils.parse_json(read_file("acf_danmaku_p0.json")))
    check("弹幕 ok", parsed.ok)
    check("首页条数=200", #parsed.comments == 200, ("got %d"):format(#parsed.comments))
    check("游标=2", parsed.pcursor == "2", tostring(parsed.pcursor))
    check("总数=289", parsed.total == 289, tostring(parsed.total))
    local c1 = parsed.comments[1]
    check("首条换算（position ms→s）", math.abs(c1.time - 26.826) < 0.001, tostring(c1.time))
    check("首条颜色", c1.color == 16777215, tostring(c1.color))
    check("首条模式透传", c1.mode == 1, tostring(c1.mode))
    check("首条文本", c1.text ~= "")
    check("no_more 终止", aparse.parse_danmaku({ result = 0, pcursor = "no_more" }).pcursor == nil)
    check("result 非0 拒绝", aparse.parse_danmaku({ result = 403 }).ok == false)
    check("空入参安全", aparse.parse_danmaku(nil).ok == false)
    check("mode 4/5 透传（底/顶）", (function()
        local p = aparse.parse_danmaku({ result = 0, danmakus = {
            { body = "底", position = 1000, color = 16777215, mode = 4 },
            { body = "顶", position = 2000, color = 16711680, mode = 5 },
        } })
        return p.comments[1].mode == 4 and p.comments[2].mode == 5 and p.comments[2].time == 2
    end)())
end

do -- build_cache_payload → parse_danmaku roundtrip（缓存载荷与网络响应同构）
    local src = {
        { time = 1.5, color = 16711680, mode = 4, text = "红底" },
        { time = 61.234, color = 16777215, mode = 1, text = "白滚" },
    }
    local payload = aparse.build_cache_payload(src)
    local back = aparse.parse_danmaku(utils.parse_json(payload))
    check("roundtrip ok 且游标终止", back.ok and back.pcursor == nil)
    check("roundtrip 条数", #back.comments == 2)
    check("roundtrip 字段还原", back.comments[1].text == "红底" and back.comments[1].mode == 4
        and back.comments[1].color == 16711680 and math.abs(back.comments[2].time - 61.234) < 0.001)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
