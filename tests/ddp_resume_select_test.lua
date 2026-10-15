-- dandanplay 续载校验纯函数测试（modules/ddp_resume.lua 场景矩阵）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败
-- 覆盖：episodeId 拆分约定（bangumiId×10000，实测 7506→75060001 / 69→690001）/ 缓存键 /
--   主策略=锚在数组中的位置±delta（负 delta、delta=0 自洽、超 1000 集回绕、集号缺失、
--   越界话数文案）/ 次策略=锚不在数组按集号等值（精确等值、小数集号不误中、重复取首）/
--   双失败 reason 文案 / 防御性输入

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local ddp_resume = require("modules/ddp_resume")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

-- 25 集 Amagami 形状（75060001..75060025）
local function amagami_eps(n)
    n = n or 25
    local eps = {}
    for i = 1, n do
        eps[i] = { episodeId = 75060000 + i, episodeTitle = ("第%d话 副标题%d"):format(i, i),
            episodeNumber = tostring(i) }
    end
    return eps
end

do -- split_episode_id：episodeId = bangumiId×10000 + 集内编号（2026-10 实测约定）
    check("拆分正常", ddp_resume.split_episode_id(75060025) == 7506)
    local bid, num = ddp_resume.split_episode_id(75060025)
    check("拆分返回集内序号", num == 25)
    check("拆分海贼王 4 位集号", ddp_resume.split_episode_id(690001) == 69)
    check("拆分字符串 id", ddp_resume.split_episode_id("75060001") == 7506)
    check("非数字 nil", ddp_resume.split_episode_id("abc") == nil)
    check("nil nil", ddp_resume.split_episode_id(nil) == nil)
    check("零/负数 nil", ddp_resume.split_episode_id(0) == nil
        and ddp_resume.split_episode_id(-5) == nil)
    check("小数 nil", ddp_resume.split_episode_id(75060025.5) == nil)
end

do -- cache_key：键含 server（各镜像 bangumi 库不一致）
    check("缓存键含 server", ddp_resume.cache_key("https://a.example", 7506)
        == "https://a.example#7506")
    check("缓存键区分 server", ddp_resume.cache_key("https://a.example", 7506)
        ~= ddp_resume.cache_key("https://b.example", 7506))
end

do -- select_episode 主策略：锚在数组中的位置 ± delta
    local ep = ddp_resume.select_episode(amagami_eps(), 75060013, 1)
    check("主策略命中", ep ~= nil and ep.episodeId == 75060014 and ep.via == "position")
    check("主策略带真实标题", ep ~= nil and ep.episodeTitle == "第14话 副标题14")
    check("delta=0 自洽", (ddp_resume.select_episode(amagami_eps(), 75060013, 0)).episodeId == 75060013)
    check("负 delta 回看", (ddp_resume.select_episode(amagami_eps(), 75060013, -2)).episodeId == 75060011)
    check("字符串锚", (ddp_resume.select_episode(amagami_eps(), "75060013", 1)).episodeId == 75060014)
    check("字符串 delta", (ddp_resume.select_episode(amagami_eps(), 75060013, "1")).episodeId == 75060014)
    check("delta 缺省 0", (ddp_resume.select_episode(amagami_eps(), 75060013)).episodeId == 75060013)
end

do -- 主策略越界（用户场景：源 25 集、本地第 26 集特别篇）
    local ep, reason = ddp_resume.select_episode(amagami_eps(), 75060025, 1)
    check("越界返回 nil", ep == nil)
    check("越界 reason 含源集数", reason ~= nil and reason:find("该源共25话", 1, true) ~= nil)
end

do -- 小数集号：主策略按位置可达；次策略集号等值不误中
    local eps = {
        { episodeId = 100101, episodeTitle = "第25.5话", episodeNumber = "25.5" },
        { episodeId = 100102, episodeTitle = "第26话", episodeNumber = "26" },
    }
    -- 主策略：锚 100101 在 pos 1，+1 → 第 26 话条目
    local ep = ddp_resume.select_episode(eps, 100101, 1)
    check("小数集号条目主策略可达", ep ~= nil and ep.episodeId == 100102 and ep.via == "position")
    -- 次策略（锚不在数组）：目标 = 999101%1000+(-76) = 25，「25.5」≠ 25 不误中 → 落空
    check("次策略小数集号不误中整数目标",
        ddp_resume.select_episode(eps, 999101, -76) == nil)
    -- 次策略目标 26 精确等值命中「26」（而非相邻 25.5）
    ep = ddp_resume.select_episode(eps, 999101, -75)
    check("次策略整数目标精确等值", ep ~= nil and ep.episodeId == 100102 and ep.via == "number")
end

do -- 超 1000 集回绕：集号等值算错（5+1=6 不在 1001..1008 集号中），主策略按位置救回
    --（实测形状：海贼王 ep1000+ 的 id 与集号不再对齐 %1000，位置是唯一可靠锚）
    local eps = {}
    for i = 1, 8 do
        eps[i] = { episodeId = 1001000 + i, episodeTitle = ("回绕%d"):format(i),
            episodeNumber = tostring(1000 + i) }
    end
    local ep = ddp_resume.select_episode(eps, 1001005, 1)
    check("回绕场景位置主策略救回", ep ~= nil and ep.episodeId == 1001006 and ep.via == "position")
    check("回绕场景带真实标题", ep ~= nil and ep.episodeTitle == "回绕6")
end

do -- episodeNumber 缺失/非数值条目：位置主策略不受影响
    local eps = {
        { episodeId = 200101, episodeTitle = "a" },
        { episodeId = 200102, episodeTitle = "b" },
        { episodeId = 200103, episodeTitle = "c" },
    }
    local ep = ddp_resume.select_episode(eps, 200101, 2)
    check("集号缺失按数组定位", ep ~= nil and ep.episodeId == 200103 and ep.via == "position")
    -- 越界且锚集号缺失：不编造话数
    local _, reason = ddp_resume.select_episode(eps, 200101, 5)
    check("集号缺失越界不编造话数",
        reason ~= nil and reason:find("目标分集不存在", 1, true) ~= nil)
end

do -- 次策略：锚不在数组（分集表 id 变更）按集号等值
    -- 锚 8001012 不在表内（%1000=12），delta=1 → 目标 13 集号命中
    local ep = ddp_resume.select_episode(amagami_eps(), 8001012, 1)
    check("锚不在数组次策略集号命中", ep ~= nil and ep.episodeId == 75060013 and ep.via == "number")
end

do -- 双失败文案
    local ep, reason = ddp_resume.select_episode(amagami_eps(), 8001012, 99)
    check("锚不在数组且越界 nil", ep == nil)
    check("锚不在数组 reason", reason ~= nil and reason:find("无法定位锚集", 1, true) ~= nil)
    ep, reason = ddp_resume.select_episode({}, 75060013, 1)
    check("空表 nil", ep == nil)
    check("空表 reason", reason ~= nil and reason:find("分集表为空", 1, true) ~= nil)
    ep, reason = ddp_resume.select_episode(amagami_eps(), "corrupt", 1)
    check("非数字锚 nil", ep == nil)
    check("非数字锚 reason", reason ~= nil and reason:find("非数字", 1, true) ~= nil)
end

do -- 次策略重复 episodeNumber 取首（与 match_episode 现行为一致）
    local eps = {
        { episodeId = 300001, episodeTitle = "第一处", episodeNumber = "3" },
        { episodeId = 300002, episodeTitle = "第二处", episodeNumber = "3" },
    }
    -- 锚 8900003 不在数组（%1000=3），delta=0 → 目标 3 → 首个「3」
    local ep = ddp_resume.select_episode(eps, 8900003, 0)
    check("次策略重复集号取首", ep ~= nil and ep.episodeId == 300001)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
-- os.exit 直杀：mpv 正常 quit 的关机路径在 Windows 控制台代理下偶发挂起（测试环境已知问题）
os.exit(failures > 0 and 1 or 0)
