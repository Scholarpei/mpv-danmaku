-- maccms_parse 单元测试（自断言，输出 PASS/FAIL 行）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local mp_ = require("modules/maccms_parse")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ---------- split_groups / split_episodes ----------

do
    local g = mp_.split_groups("qq$$$m3u8$$$mp4")
    check("groups 三组", #g == 3 and g[1] == "qq" and g[2] == "m3u8" and g[3] == "mp4")
    local g2 = mp_.split_groups("  qq $$$ $$$ m3u8 ")
    check("groups 空组跳过+trim", #g2 == 2 and g2[1] == "qq" and g2[2] == "m3u8")
    check("groups 空串安全", #mp_.split_groups("") == 0 and #mp_.split_groups(nil) == 0)

    local e = mp_.split_episodes("第01集$https://v.qq.com/x/cover/a.html#第02集$https://v.qq.com/x/cover/b.html")
    check("episodes 两组集", #e == 2 and e[1].title == "第01集"
        and e[2].url == "https://v.qq.com/x/cover/b.html")

    local e2 = mp_.split_episodes("无名$https://x.com/a$b$c")
    check("episodes 首个$切分防误切", e2[1].title == "无名" and e2[1].url == "https://x.com/a$b$c")

    local e3 = mp_.split_episodes("https://bare.example/1.m3u8")
    check("episodes 无$视为纯链接", #e3 == 1 and e3[1].title == ""
        and e3[1].url == "https://bare.example/1.m3u8")

    local e4 = mp_.split_episodes("第1集$https://a##第2集$https://b")
    check("episodes 空段跳过", #e4 == 2 and e4[2].title == "第2集")
    check("episodes 空串安全", #mp_.split_episodes("") == 0 and #mp_.split_episodes(nil) == 0)
end

-- ---------- parse_vod_list ----------

do
    local root_list = {
        code = "1", page = "1", total = "2",
        list = {
            { vod_id = "101", vod_name = "庆余年", vod_year = "2024",
              vod_class = "国产剧", vod_area = "大陆" },
            { vod_id = 102, vod_name = "无年份条目" },
            { vod_name = "缺id被跳过" },
        },
    }
    local r = mp_.parse_vod_list(root_list)
    check("vodlist 根list+字符串字段容错", #r == 2 and r[1].vod_id == 101
        and r[1].vod_year == 2024 and r[1].vod_class == "国产剧")
    check("vodlist 缺年份回退0", r[2].vod_year == 0)

    local nested = { data = { list = { { vod_id = "9", vod_name = "嵌套条目" } } } }
    local r2 = mp_.parse_vod_list(nested)
    check("vodlist data.list 嵌套封装", #r2 == 1 and r2[1].vod_id == 9)

    check("vodlist 无list为空", #mp_.parse_vod_list({ code = 1 }) == 0)
    check("vodlist 非table入参安全", #mp_.parse_vod_list(nil) == 0)
end

-- ---------- parse_play_sources / get_episode ----------

do
    local vod = {
        vod_play_from = "qq$$$m3u8",
        vod_play_url = "第01集$https://v.qq.com/x/cover/a.html#第02集$https://v.qq.com/x/cover/b.html"
            .. "$$$"
            .. "第01集$/vod/a.m3u8#第02集$/vod/b.m3u8",
    }
    local play = mp_.parse_play_sources(vod)
    check("play 两组对齐", #play.from == 2 and #play.urls == 2
        and play.from[1] == "qq" and play.from[2] == "m3u8")
    check("play 组内集数", #play.urls[1] == 2 and #play.urls[2] == 2)

    check("get_episode 命中", mp_.get_episode(play, 1, 2).url == "https://v.qq.com/x/cover/b.html")
    check("get_episode 组越界", mp_.get_episode(play, 3, 1) == nil)
    check("get_episode 集越界", mp_.get_episode(play, 1, 3) == nil)
    check("get_episode 非法入参", mp_.get_episode(nil, 1, 1) == nil)

    -- from 多于 url：按小者截断
    local vod2 = {
        vod_play_from = "a$$$b$$$c",
        vod_play_url = "第1集$https://x/1",
    }
    local play2 = mp_.parse_play_sources(vod2)
    check("play 两组数不齐截断", #play2.from == 1 and #play2.urls == 1)

    -- 空组名回退「来源N」（空名配的是有效集数组才触发；空 url 组则整组剔除）
    local vod3 = {
        vod_play_from = "qq$$$",
        vod_play_url = "第1集$https://x/1$$$第2集$https://x/2",
    }
    local play3 = mp_.parse_play_sources(vod3)
    check("play 空组名回退来源N", #play3.from == 2 and play3.from[1] == "qq"
        and play3.from[2] == "来源2" and #play3.urls[2] == 1)

    check("play 空字段安全", #mp_.parse_play_sources({}).from == 0
        and #mp_.parse_play_sources(nil).urls == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
