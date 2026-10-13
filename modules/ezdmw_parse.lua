-- ezdmw（E站弹幕网）搜索页/详情页/播放页/弹幕 XML 的纯解析函数（无 mp.* 依赖，便于单元测试）
-- 调用方：apis/ezdmw_search.lua、sites/ezdmw.lua
--
-- 接口形态（2026-10-13 实测，见 tests/fixtures/ezd_*）：
--   搜索 GET https://www.ezdmw.org/Index/search.html?searchText=<kw> —— 服务端渲染 HTML，
--     结果区 <section class="some_drama" id="some_drama">，每条为
--     <div><a href="/Index/bangumi/{bangumiId}.html"><img/></a><p><span class="play_some"
--     style="...">标题</p></div>。⚠️ 标题前有【不闭合】HTML 注释：<!--<img .../> 12万</span>-->
--     ——注释的 --> 在 </span> 之后，先剥注释再剥标签才拿得到标题。页面另有瀑布流推荐区
--     （链接 /Index/up_details/，与 bangumi 链接不碰撞）；无结果时 some_drama 区整段缺席。
--   详情 GET https://www.ezdmw.org/Index/bangumi/{bangumiId}.html —— 集数链接
--     <a class="circuit_switch1" href="/Index/video/{videoId}.html"><span class="{ep}">{ep}</span>。
--     ⚠️ videoId 是每集独立 ID，与 bangumiId 两套体系。多线路分组：circuit_switch1=主线线路
--     （固定第一组，取此组），circuit_switch2/3=备用/导入线路（span class 带「备用N/导入N」
--     前缀，数字锚点天然不匹配），另有 circuit_switch_ban 锁定线路；单集剧场版同样只有
--     circuit_switch1 命中。页面顺序为降序（末集在前），须按集数升序排；页面另有
--     「动漫下载」磁力链接区（magnet:?xt 不与集数链接碰撞）。
--     ⚠️ 多季番多季合并在同一页，span 文本为「{季}-{集}」格式（圣诞之吻SS 实测：S1 26 集
--     纯数字 + S2 十三集 2-01..2-13）——纯数字模式会静默丢整季，须两格式都认。
--   播放页 GET https://www.ezdmw.org/Index/video/{videoId}.html —— 内嵌弹幕播放器
--     <iframe src="https://player.ezdmw.com/danmuku/?nk={资源名}/{资源名_集数}&name=…
--     &sign={32位hex}&…">，nk 与 sign 均由服务端预计算嵌在 HTML（无需逆向签名）。
--     ⚠️ sign 每次请求轮换（实测两次连抓同一播放页即不同），不可缓存——每次加载都须
--     先取播放页提取新 nk+sign。页面另有评论区 iframe src="/comment/?comment_index=nk=
--     {bangumiId}"，提取必须锚定 danmuku 播放器，不能按 nk= 盲取。
--     ⚠️ 部分番（圣诞之吻SS 实测全线路）E站未绑弹幕资源：播放页只有第三方解析 iframe
--     （//jx.aidouer.net/?url=…）+ 评论区 iframe、无 danmuku 播放器——无 nk/sign 可取，
--     属确定性无弹幕而非网络失败（调用方按 no_data 口径处理，见 sites/ezdmw.lua）。
--   弹幕 GET https://player.ezdmw.com/index/getData.html?video_id={nk}&json=xml&danmu={nk}
--     &sign={sign}&timeAxis=false&getUser=%E6%B8%B8%E5%AE%A2（游客）——无需 cookie/referer
--     纯 GET 直达；备用域 player.danmuzf.vip 同路径（主域失败降级）。
--     响应为 B站标准 XML：<d p="time,mode,fontsize,color,sendts,pool,user,rowid">文本</d>
--     （time 秒 / mode 1滚动 4底 5顶 / color 十进制整数 RGB，与B站同语义；文本含
--     &lt;&gt;&amp; 实体需反转义）。实测样本：Re:0 第四季 ep19 = 1701 条。

local M = {}

-- 常用 HTML/XML 实体解码（&amp; 必须最后：&amp;lt; 应解成字面 "<" 而非二次解码）
local function xml_unescape(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&gt;", ">")
        :gsub("&lt;", "<"):gsub("&amp;", "&"))
end

-- ============ 搜索页 ============

-- 搜索页 HTML → { ok=bool, items={ {bangumi_id, title} } }
-- ok 仅表示完成了解析流程（含无结果的空表——此时 some_drama 区整段缺席）；
-- 请求失败由调用方在 HTTP 层判定
function M.parse_search(html)
    local result = { ok = false, items = {} }
    if type(html) ~= "string" then return result end

    local j = html:find('id="some_drama"', 1, true)
    if j then
        -- some_drama 区内无嵌套 <section>：其后首个 </section> 即本区结束
        local k = html:find("</section>", j, true)
        local region = k and html:sub(j, k - 1) or html:sub(j)
        for bid, raw in region:gmatch('<a href="/Index/bangumi/(%d+)%.html"[^>]->.-<p>(.-)</p>') do
            -- 标题在不闭合注释之后：先剥 <!--...--> 再剥残余标签、去首尾空白
            local title = raw:gsub("<!%-%-.-%->", "")
                :gsub("<[^>]->", "")
                :gsub("^%s+", ""):gsub("%s+$", "")
            result.items[#result.items + 1] = { bangumi_id = bid, title = title }
        end
    end
    result.ok = true
    return result
end

-- ============ 详情页（/Index/bangumi/{bangumiId}.html）============

-- → { ok=bool, episodes={ {video_id, ep, season} } }（仅主线线路 circuit_switch1；按
-- (季,集) 升序=正片顺序，页面原始顺序为降序不可直接用；span 文本纯数字=集数（单季，
-- season=1）、「{季}-{集}」=多季合并页（圣诞之吻SS 实测 2-13=第二季第13集），其他形状跳过）
function M.parse_detail(html)
    local result = { ok = false, episodes = {} }
    if type(html) ~= "string" then return result end

    for vid, raw in html:gmatch('<a class="circuit_switch1" href="/Index/video/(%d+)%.html"'
        .. '[^>]->%s*<span[^>]*>%s*([%d%-]+)%s*</span>') do
        local season, ep = raw:match("^(%d+)%-(%d+)$")
        if season then
            season, ep = tonumber(season), tonumber(ep)
        else
            season, ep = 1, tonumber(raw:match("^%d+$"))
        end
        if ep then
            result.episodes[#result.episodes + 1] =
                { video_id = vid, ep = ep, season = season }
        end
    end
    table.sort(result.episodes, function(a, b)
        if a.season ~= b.season then return a.season < b.season end
        return a.ep < b.ep
    end)
    result.ok = #result.episodes > 0
    return result
end

-- ============ 季集复合键（apis/ezdmw_search.lua 菜单/续载/预取共用）============

-- (season, ep) → 集数键：S1 恒为纯集数（单季旧历史 back-compat），S2+ 为 season*10000+ep
-- （跨季键恒 >10000 不与单季纯集数碰撞；季内 +delta 预取算术保持成立）
function M.episode_key(season, ep)
    if season and season > 1 then return season * 10000 + ep end
    return ep
end

-- 集数键 → 显示名（「第26集」/「第2季13集」）
function M.episode_label(key)
    local n = tonumber(key) or 0
    local season = math.floor(n / 10000)
    if season >= 2 then
        return ("第%d季%d集"):format(season, n % 10000)
    end
    return ("第%d集"):format(n)
end

-- ============ 播放页（/Index/video/{videoId}.html）============

-- → { ok=bool, nk, sign }：nk=弹幕资源名（含 / 分隔的资源名_集数）、sign=32位hex。
-- 锚定弹幕播放器 iframe（src 含 /danmuku/?nk=），跳过评论区 iframe（comment_index=nk=）
function M.parse_player(html)
    local result = { ok = false, nk = nil, sign = nil }
    if type(html) ~= "string" then return result end

    local src = html:match('<iframe[^>]-src="(https://player%.[^"]-/danmuku/[^"]*)"')
    if not src then return result end
    local nk = src:match("[?&]nk=([^&\"]*)")
    local sign = src:match("[?&]sign=([^&\"]*)")
    if not nk or nk == "" or not sign or sign == "" then return result end
    result.nk = nk
    result.sign = sign
    result.ok = true
    return result
end

-- ============ 弹幕（getData 响应，B站标准 XML）============

-- → { ok=bool, comments={ {time=秒, color=整数RGB, mode=1/4/5, text} } }
-- p 字段序：time,mode,fontsize,color,sendts,pool,user,rowid（与B站同约定；
-- 首 4 字段齐备才收，畸形单条跳过不击穿整批）；文本反转义实体
function M.parse_danmaku(xml)
    local out = { ok = false, comments = {} }
    if type(xml) ~= "string" then return out end
    out.ok = true
    for p_attr, text in xml:gmatch('<d%s+[^>]*%f[^%s]p="([^"]+)"[^>]*>([^<]+)</d>') do
        local params = {}
        local i = 1
        for val in p_attr:gmatch("([^,]+)") do
            params[i] = tonumber(val)
            i = i + 1
        end
        if params[1] and params[2] and params[3] and params[4] then
            out.comments[#out.comments + 1] = {
                time = params[1],
                mode = params[2],
                color = params[4],
                text = xml_unescape(text),
            }
        end
    end
    return out
end

return M
