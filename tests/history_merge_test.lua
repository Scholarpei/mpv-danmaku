-- 文件夹弹幕记忆多源合并单元测试（modules/history_merge.lua 场景矩阵）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local hmerge = require("modules/history_merge")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function kinds(list)
    local out = {}
    for i, ex in ipairs(list) do out[i] = ex.kind end
    return table.concat(out, ",")
end

do -- 旧格式迁移：单 extra → 单元素表
    check("旧单extra读取", kinds(hmerge.read_extras({ extra = { kind = "qq", episodenum = 3 } })) == "qq")
    check("旧extra无kind丢弃", #hmerge.read_extras({ extra = { episodenum = 3 } }) == 0)
    check("新extras读取+无效项过滤", kinds(hmerge.read_extras({ extras = {
        { kind = "qq", episodenum = 1 }, "garbage", { episodenum = 2 }, { kind = "animeko", episodenum = 2 },
    } })) == "qq,animeko")
    check("空记录", #hmerge.read_extras({}) == 0)
    check("nil记录", #hmerge.read_extras(nil) == 0)
end

do -- 写侧合并：追加/替换/顺序保持
    local old = { extras = { { kind = "qq", episodenum = 5 }, { kind = "animeko", episodenum = 5 } } }
    local merged = hmerge.merge_extras(old, { kind = "youku", episodenum = 5 })
    check("新kind追加", kinds(merged) == "qq,animeko,youku")

    local merged2 = hmerge.merge_extras(old, { kind = "qq", episodenum = 6 })
    check("同kind替换保序", kinds(merged2) == "qq,animeko"
        and merged2[1].episodenum == 6 and merged2[2].episodenum == 5)

    check("旧单extra种子+新kind", kinds(hmerge.merge_extras(
        { extra = { kind = "qq", episodenum = 2 } }, { kind = "mgtv", episodenum = 2 })) == "qq,mgtv")

    check("无当前extra返回种子", kinds(hmerge.merge_extras(old, nil)) == "qq,animeko")
    check("dandanplay残留防护（current为nil不合并）",
        #hmerge.merge_extras({ extras = {} }, nil) == 0)
end

do -- 锚点注入：merge_extras 第三参
    local cur = { kind = "animeko", episodenum = 5 }
    local merged = hmerge.merge_extras({}, cur, "Show S01E05")
    check("写入条目注入fname锚", merged[1].fname == "Show S01E05")

    -- 副本注入：不污染全局 DANMAKU.extra（write_history 的 current 引用）
    check("锚注入不改动current_extra", cur.fname == nil and next(cur) ~= nil)

    -- 替换同 kind 时新条目带新锚，未触碰条目锚保持
    local old = { extras = { { kind = "qq", episodenum = 5, fname = "Show S01E04" } } }
    local m2 = hmerge.merge_extras(old, { kind = "qq", episodenum = 6 }, "Show S01E05")
    check("替换条目锚更新", m2[1].fname == "Show S01E05" and m2[1].episodenum == 6)

    -- anchor_fname 为 nil（如测试/兼容路径）：不注入，条目无锚
    local m3 = hmerge.merge_extras({}, { kind = "qq", episodenum = 1 }, nil)
    check("无锚参数不注入", m3[1].fname == nil)
end

do -- anchor_delta：每源锚点差值推算
    local function fake_parse(filename, anchor)
        -- 模拟 get_episode_number(filename, fname)：返回 (锚侧集数, 当前集数)
        local a = tonumber(anchor:match("E(%d+)"))
        local c = tonumber(filename:match("E(%d+)"))
        if a and c then return a, c end
        return nil, nil
    end

    -- 场景还原（E06 竞态）：快源 bili 已把全局锚移到 E06，二次触发时全局 x=0；
    -- 慢源 ako 的锚还在 E05 → 应按自身锚 +1 而非 +0
    local filename = "Seihantai na Kimi to Boku 2026 S01E06-[1080p]"
    local global_x = 0
    check("慢源锚在旧集按锚推算",
        hmerge.anchor_delta(fake_parse, filename, "Seihantai na Kimi to Boku 2026 S01E05-[1080p]", global_x) == 1)
    check("快源锚已移至当前集差值为0",
        hmerge.anchor_delta(fake_parse, filename, filename, global_x) == 0)
    check("无锚回退全局差值",
        hmerge.anchor_delta(fake_parse, filename, nil, 1) == 1)
    check("锚解析失败回退全局差值",
        hmerge.anchor_delta(fake_parse, filename, "完全不同的名字", 2) == 2)

    -- 常规换集：全局锚 E05→E06，慢源锚 E04（上上次）→ 差值 2
    check("跨多集锚推算",
        hmerge.anchor_delta(fake_parse, filename, "Show S01E04", 1) == 2)
end

do -- 端到端场景：多源续载时逐源 write_history 的合并链
    -- 场景：旧记录 episodeId+qq；先 resume animeko（extra=animeko），再 resume qq（extra=qq）
    local history_record = { episodeId = 1001, extras = { { kind = "qq", episodenum = 5 } } }
    -- resume animeko：write_history(episodeid=nil, DANMAKU.extra=animeko)
    local after_animeko = hmerge.merge_extras(history_record, { kind = "animeko", episodenum = 5 })
    -- resume qq：write_history(episodeid=nil, DANMAKU.extra=qq)
    local after_qq = hmerge.merge_extras({ episodeId = 1001, extras = after_animeko },
        { kind = "qq", episodenum = 5 })
    check("续载链保持双源", kinds(after_qq) == "qq,animeko"
        and after_qq[1].episodenum == 5 and after_qq[2].episodenum == 5)

    -- 场景：用户切回 dandanplay 搜索选择（episodeid 非 nil → current 传 nil）
    local after_dandan = hmerge.merge_extras({ episodeId = 1001, extras = after_qq }, nil)
    check("dandanplay选择不清除直连源", kinds(after_dandan) == "qq,animeko")

    -- 场景：全新文件夹第一次 dandanplay 选择（old 空、current nil）
    check("全新文件夹无残留", #hmerge.merge_extras({}, nil) == 0)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
