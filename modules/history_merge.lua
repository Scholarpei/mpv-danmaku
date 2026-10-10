-- 文件夹弹幕记忆的多源合并纯函数（无硬性 mp.* 依赖以便单元测试）
-- 调用方：main.lua（write_history 写侧 / dandanplay_flow 读侧）
--
-- 历史记录结构（history[dir]）：
--   旧格式：{ episodeId?, extra = {kind=..., episodenum=...} }（dandanplay 与直连源互斥，后写覆盖先写）
--   新格式：{ episodeId?, extras = { {kind=..., episodenum=...}, ... } }（多源并存，同 kind 替换）
-- 迁移规则：读侧遇到旧单 extra 自动包成单元素表；写侧 extras 优先、无 extras 时用旧 extra 种子

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
function M.merge_extras(old, current_extra)
    local extras = M.seed_extras(old)
    if type(current_extra) == "table" and current_extra.kind then
        local replaced = false
        for i, ex in ipairs(extras) do
            if ex.kind == current_extra.kind then
                extras[i] = current_extra
                replaced = true
                break
            end
        end
        if not replaced then
            extras[#extras + 1] = current_extra
        end
    end
    return extras
end

-- 读侧展开：记录 → 有效 extras 列表（含旧单 extra 迁移）
function M.read_extras(record)
    return M.seed_extras(record)
end

return M
