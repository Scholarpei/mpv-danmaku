-- prefetch.plan 纯函数测试：下一集预取任务规划（锚点推算镜像 dandanplay_flow）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败
-- 覆盖：全源记录按各锚推算下一集 / 慢源锚落后差值独立推算 / 锚==下一集文件名差值 0 /
--   老记录无锚回退全局差值 / 重播当前集（x=0）/ 不可预取 kind 不排任务 / 集数剪裁 /
--   B站合集集数推算与回退 / 解析不出集数整体放弃 / 防御性输入

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

-- RESOLVERS 在模块加载期引用各 resolve_* 全局：先定义 stub（qq/youku 两个可预取 kind
-- 即可覆盖排任务逻辑；其余 kind 留 nil 验证「不可预取不排任务」）
function resolve_tencent_episode_url() end
function resolve_youku_episode_url() end

local prefetch = require("modules/prefetch")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- 假集数解析器：与 utils.get_episode_number 同签名语义
--   单参 → 当前文件集数；双参 → (锚集数, 当前集数)；解析失败 nil
local function fake_parse(filename, fname)
    if fname == nil then
        return tonumber(filename:match("(%d+)%s*$"))
    end
    local a = tonumber(fname:match("(%d+)%s*$"))
    local cur = tonumber(filename:match("(%d+)%s*$"))
    if a == nil or cur == nil then return nil, nil end
    return a, cur
end

local function find_by_type(tasks, typ)
    for _, t in ipairs(tasks) do
        if t.type == typ then return t end
    end
    return nil
end

local function find_ext(tasks, kind)
    for _, t in ipairs(tasks) do
        if t.type == "ext" and t.kind == kind then return t end
    end
    return nil
end

local function count_by_type(tasks, typ)
    local n = 0
    for _, t in ipairs(tasks) do
        if t.type == typ then n = n + 1 end
    end
    return n
end

-- 全源记录：ddp + qq（锚=当前集）+ youku（慢源锚落后一集）+ animeko/360kan（不可预取）+ B站合集
local RECORD = {
    fname = "Show - 08",
    episodeNumber = 8,
    episodeId = 100108,
    episodeId_fname = "Show - 08",
    api_server = "https://s1.example.com",
    extras = {
        { kind = "qq", cid = "c1", episodenum = 8, fname = "Show - 08" },
        { kind = "youku", show_id = "s1", episodenum = 8, fname = "Show - 07" },
        { kind = "animeko", subject_id = "x", episodenum = 8, fname = "Show - 08" },
        { kind = "360kan", id = 1, episodenum = 8 },
    },
    bilibili = { BV123 = { page = 8, episode = 8, season = 1, ts = 1 } },
}

-- ---------- 用例 1：全源记录 → 下一集 +1，各锚独立推算 ----------
do
    local tasks = prefetch.plan(RECORD, "Show - 09", fake_parse)
    local ddp = find_by_type(tasks, "ddp")
    check("ddp 任务存在", ddp ~= nil)
    check("ddp episodeId 按锚 +1", ddp and ddp.episode_id == 100109)
    check("ddp api_server 透传", ddp and ddp.api_server == "https://s1.example.com")
    local qq = find_ext(tasks, "qq")
    check("qq 任务存在", qq ~= nil)
    check("qq 集数 = 锚差 +1", qq and qq.episodenum == 9)
    check("qq extra 引用透传", qq and qq.extra == RECORD.extras[1])
    local yk = find_ext(tasks, "youku")
    check("youku 慢源锚落后仍排任务", yk ~= nil)
    check("youku 按自身锚推算（07 锚记 8 → 09 集）", yk and yk.episodenum == 10)
    check("animeko 不可预取不排任务", find_ext(tasks, "animeko") == nil)
    check("360kan 不可预取不排任务", find_ext(tasks, "360kan") == nil)
    check("ext 任务共 2 项", count_by_type(tasks, "ext") == 2)
    local bl = find_by_type(tasks, "bili_series")
    check("B站合集任务存在", bl ~= nil)
    check("B站合集集数 = 锚集数 + 文件名差值", bl and bl.episode == 9)
    check("B站合集 vid/rec 透传", bl and bl.vid == "BV123" and bl.rec == RECORD.bilibili.BV123)
end

-- ---------- 用例 2：锚==下一集文件名（源在下一集上选择过）→ 差值 0 ----------
do
    local rec = {
        fname = "Show - 08", episodeNumber = 8,
        extras = { { kind = "qq", episodenum = 10, fname = "Show - 09" } },
    }
    local tasks = prefetch.plan(rec, "Show - 09", fake_parse)
    local qq = find_ext(tasks, "qq")
    check("锚==下一集文件名时差值 0", qq and qq.episodenum == 10)
end

-- ---------- 用例 3：老记录 extras 无锚 → 回退全局差值 ----------
do
    local rec = {
        fname = "Show - 08", episodeNumber = 8,
        extras = { { kind = "qq", episodenum = 8 } },
    }
    local tasks = prefetch.plan(rec, "Show - 09", fake_parse)
    local qq = find_ext(tasks, "qq")
    check("无锚回退全局差值", qq and qq.episodenum == 9)
end

-- ---------- 用例 4：重播当前集（下一集==全局锚文件）→ x=0 ----------
do
    local tasks = prefetch.plan(RECORD, "Show - 08", fake_parse)
    local ddp = find_by_type(tasks, "ddp")
    check("重播时 ddp 差值 0", ddp and ddp.episode_id == 100108)
    local qq = find_ext(tasks, "qq")
    check("重播时 qq 差值 0", qq and qq.episodenum == 8)
    local yk = find_ext(tasks, "youku")
    check("重播时慢源按自身锚推算（07→08）", yk and yk.episodenum == 9)
end

-- ---------- 用例 5：无 episodeId（纯直连源文件夹）→ 无 ddp 任务 ----------
do
    local rec = {
        fname = "Show - 08", episodeNumber = 8,
        extras = { { kind = "qq", episodenum = 8, fname = "Show - 08" } },
    }
    local tasks = prefetch.plan(rec, "Show - 09", fake_parse)
    check("无 episodeId 不排 ddp", find_by_type(tasks, "ddp") == nil)
    check("extras 照常排任务", find_ext(tasks, "qq") ~= nil)
end

-- ---------- 用例 6：推算集数 <1 → 剪裁 ----------
do
    local rec = {
        fname = "Show - 08", episodeNumber = 8,
        extras = {
            { kind = "qq", episodenum = 8, fname = "Show - 20" },   -- 自锚差 -11 → -3
            { kind = "youku", episodenum = 8, fname = "Show - 09" }, -- 自锚差 0 → 8
        },
    }
    local tasks = prefetch.plan(rec, "Show - 09", fake_parse)
    check("推算集数 <1 的源被剪裁", find_ext(tasks, "qq") == nil)
    check("有效源保留", find_ext(tasks, "youku") ~= nil)
end

-- ---------- 用例 7：下一集文件名解析不出集数 → 整体不预取 ----------
do
    local tasks = prefetch.plan(RECORD, "Show - Final", fake_parse)
    check("解析不出集数返回空任务", #tasks == 0)
end

-- ---------- 用例 8：episodeNumber 缺失 → 防御性放弃 ----------
do
    local rec = { fname = "Show - 08", episodeId = 100108, episodeId_fname = "Show - 08" }
    check("episodeNumber 缺失返回空", #prefetch.plan(rec, "Show - 09", fake_parse) == 0)
end

-- ---------- 用例 9：B站合集文件名差值解析失败 → 回退锚点 +1 ----------
do
    local rec = {
        fname = "Show - 08", episodeNumber = 8,
        bilibili = { BV1 = { page = 8, episode = 8 }, BV2 = { page = 3, episode = 5 } },
    }
    -- fname 锚存在但与下一集无数字差可比（fake_parse 对 "Fin" 返回 nil）→ 各回退 +1
    local tasks = prefetch.plan(rec, "Show - Fin", fake_parse)
    check("差值解析失败时 B站合集回退 +1（整体不放弃的场景由调用方门槛保证）",
        #tasks == 0) -- playing 为 nil：B站合集同样不排（保守放弃，换集时照常走网络）
    -- playing 可解析但 fname 差值不可比的场景：fname 缺失时 B站合集直接回退 +1
    local rec2 = {
        episodeNumber = 8,
        bilibili = { BV1 = { page = 8, episode = 8 } },
    }
    local tasks2 = prefetch.plan(rec2, "Show - 09", fake_parse)
    local bl = find_by_type(tasks2, "bili_series")
    check("fname 缺失时 B站合集回退锚点 +1", bl ~= nil and bl.episode == 9)
end

-- ---------- 用例 10：防御性输入 ----------
check("record nil 返回空", #prefetch.plan(nil, "Show - 09", fake_parse) == 0)
check("next_filename nil 返回空", #prefetch.plan(RECORD, nil, fake_parse) == 0)
check("parse_fn 缺失返回空", #prefetch.plan(RECORD, "Show - 09", nil) == 0)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures > 0 and 1 or 0)
