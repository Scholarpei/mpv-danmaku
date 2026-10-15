-- dandanplay 历史续载校验纯函数（无 mp.* 依赖以便单元测试）
-- 调用方：apis/dandanplay.lua（resume_dandanplay_episode / resolve_ddp_episode_id）
--
-- 背景：续载原先按 episodeId + 集数差盲算（tmp_id = history_id + x），episodeId 落到全局
-- ID 空间里其他条目时加载错误内容却显示本地拼的「第N话」成功（Amagami SS ep26 特别篇
-- 实锤：源条目 25 集，id+1 落到别的番）。本模块在服务器分集表（/api/v2/bangumi/{id} 的
-- episodes[]）里按锚点定位目标集：拿到真实 episodeId 与 episodeTitle（显示层展示源端
-- 真实标题），越界则如实报告，绝不拿猜测值冒充。
--
-- episodeId 约定（2026-10 实测：圣诞之吻SS 7506→75060001..75060025、海贼王 69→
-- 690001..691002 再后接 699429 等特典非连续段）：episodeId = bangumiId×10000 + 集内
-- 编号。分集 id 在正片段内连续，特典/加播段的 id 不与数组位置对应——故定位主策略取
-- 「锚在数组中的位置 ± delta」（与旧 id 算术在连续段内等价，且不受超 1000 集回绕与
-- 特典段影响）；锚不在数组（分集表 id 变更的异常场景）才降级按集号等值
--（目标 = 锚 % 1000 + delta，与 write_history 的 episodeNumber 同口径，仅 <1000 集可靠）。
-- delta（集数差）是本地文件名空间的值叠加在 ddp 空间锚上（偏移语义：S2 连续编号等
-- 存量用户初始匹配建立的偏移经算术保持，不能用本地裸集数）。

local M = {}

-- episodeId → (bangumiId, 集内序号)；非数字/非正整数返回 nil
function M.split_episode_id(episode_id)
    local n = tonumber(episode_id)
    if n == nil or n <= 0 or n ~= math.floor(n) then return nil end
    return math.floor(n / 10000), n % 1000
end

-- 续载会话缓存键（各镜像 bangumi 库不一致，键须含 server）
function M.cache_key(server, bangumi_id)
    return tostring(server) .. "#" .. tostring(bangumi_id)
end

-- 分集表按锚点差值定位目标集
-- episodes: /api/v2/bangumi 的 bangumi.episodes（{episodeId=, episodeTitle=, episodeNumber=}）
-- anchor_episode_id: 历史记录的 episodeId（ddp 空间锚）
-- delta: 集数差（x_ddp，可为负 = 回看更早一集）
-- 返回 {episodeId=, episodeTitle=, via="position"|"number"}；失败返回 nil, reason（中文文案供 OSD/台账直用）
function M.select_episode(episodes, anchor_episode_id, delta)
    if type(episodes) ~= "table" or #episodes == 0 then
        return nil, "服务器分集表为空"
    end
    local anchor = tonumber(anchor_episode_id)
    if anchor == nil then
        return nil, "锚 episodeId 非数字（历史记录异常）"
    end
    delta = tonumber(delta) or 0

    -- 主策略：锚在数组中的位置 ± delta（与旧 episodeId 算术在连续段内等价；超 1000 集
    -- id 回绕、特典段 id 不对应位置等情形均不受影响）
    local anchor_pos = nil
    for i, ep in ipairs(episodes) do
        if tonumber(ep.episodeId) == anchor then
            anchor_pos = i
            break
        end
    end
    if anchor_pos ~= nil then
        local ep = episodes[anchor_pos + delta]
        if ep ~= nil then
            return { episodeId = ep.episodeId, episodeTitle = ep.episodeTitle, via = "position" }, nil
        end
        -- 越界：目标话数按锚条目自身集号 + delta（集号缺失时不编造话数）
        local anchor_num = tonumber(episodes[anchor_pos].episodeNumber)
        if anchor_num ~= nil then
            return nil, ("第%s话不存在（该源共%d话）")
                :format(tostring(anchor_num + delta), #episodes)
        end
        return nil, ("目标分集不存在（该源共%d话）"):format(#episodes)
    end

    -- 次策略：锚不在数组（分集表 id 已变更的异常场景），按集号等值定位。
    -- 目标 = 锚 % 1000 + delta（write_history 的 episodeNumber 同口径）；取首个命中
    --（与 match_episode 现行为一致）；小数集号精确等值不会误中整数目标
    local target = anchor % 1000 + delta
    for _, ep in ipairs(episodes) do
        local num = tonumber(ep.episodeNumber)
        if num ~= nil and num == target then
            return { episodeId = ep.episodeId, episodeTitle = ep.episodeTitle, via = "number" }, nil
        end
    end
    return nil, "无法定位锚集（服务器分集表已变更）"
end

return M
