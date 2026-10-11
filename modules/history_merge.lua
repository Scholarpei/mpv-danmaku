-- 文件夹弹幕记忆的多源合并纯函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：main.lua（write_history 写侧 / dandanplay_flow 读侧）
--
-- 历史记录结构（history[dir]）：
--   旧格式：{ episodeId?, extra = {kind=..., episodenum=...} }（dandanplay 与直连源互斥，后写覆盖先写）
--   新格式：{ episodeId?, extras = { {kind=..., episodenum=..., fname=锚}, ... } }（多源并存，同 kind 替换）
-- 迁移规则：读侧遇到旧单 extra 自动包成单元素表；写侧 extras 优先、无 extras 时用旧 extra 种子
-- 锚点：extras[].fname = 选择该源时的文件名。多源异步续载时快源先 write_history 会把全局
--   fname/episodeNumber 移到当前集，慢源未完成的 episodenum 仍停在旧集——全局差值对慢源失效，
--   故每源按自己的锚独立推算（anchor_delta）；老记录无锚回退全局差值

local M = {}

-- 旧记录里的 extras 种子：extras 表（过滤无效项）优先，否则单 extra 包一层；都没有返回 {}
function M.seed_extras(old)
    old = type(old) == "table" and old or {}
    local extras = {}
    if type(old.extras) == "table" then
        for _, ex in ipairs(old.extras) do
            if type(ex) == "table" and ex.kind then
                extras[#extras + 1] = ex
            end
        end
    elseif type(old.extra) == "table" and old.extra.kind then
        extras = { old.extra }
    end
    return extras
end

-- 写侧合并：旧记录种子 ∪ 当前直连源选择（同 kind 替换，保持原有顺序）
-- current_extra 为 nil（如 dandanplay 选择路径）时仅返回种子——防止全局 DANMAKU.extra 残留污染新文件夹
-- anchor_fname 非 nil 时对本次写入条目注入 fname 锚（副本注入，不改全局 DANMAKU.extra）
function M.merge_extras(old, current_extra, anchor_fname)
    local extras = M.seed_extras(old)
    if type(current_extra) == "table" and current_extra.kind then
        local entry = current_extra
        if anchor_fname then
            entry = {}
            for k, v in pairs(current_extra) do entry[k] = v end
            entry.fname = anchor_fname
        end
        local replaced = false
        for i, ex in ipairs(extras) do
            if ex.kind == entry.kind then
                extras[i] = entry
                replaced = true
                break
            end
        end
        if not replaced then
            extras[#extras + 1] = entry
        end
    end
    return extras
end

-- 每源锚点差值：anchor_fname 为该源选择时的文件名
--   锚==当前文件 → 0（选择就发生在当前集，快源移动全局锚后的二次触发不再误判换集）
--   锚可解析     → 当前集 - 锚集（慢源按自身进度独立推算）
--   锚缺失/解析失败 → fallback_x（老记录回退现行全局差值）
-- parse_fn 即 utils.get_episode_number(filename, fname) → (锚侧集数, 当前集数)
function M.anchor_delta(parse_fn, filename, anchor_fname, fallback_x)
    if anchor_fname == filename then return 0 end
    if anchor_fname then
        local a, cur = parse_fn(filename, anchor_fname)
        if a and cur then return cur - a end
    end
    return fallback_x
end

-- 读侧展开：记录 → 有效 extras 列表（含旧单 extra 迁移）
function M.read_extras(record)
    return M.seed_extras(record)
end

return M
