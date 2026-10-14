-- OmoFun（Lanerc）App API 签名/域名发现/响应解密与搜索/选集/弹幕的纯解析函数
-- （除 mp.utils 零 mp 依赖，单测直打；md5/aes/base64 照 aiyifan_parse 先例直接 require）
-- 调用方：apis/omofun_search.lua、sites/omofun.lua（网络与域名发现状态机在后者）
--
-- 接口形态（2026-10-14/15 全链路线上实测，见 tmp/OMOFUN_DANMU_REVERSE.md §0.5 与
-- tmp/samples/ 实抓夹具；逆向报告：静态 blutter + 动态 MuMu/ProxyPin 抓包）：
--   Base：域名经 DoH TXT 发现——公共 DoH（doh.pub / 阿里）查 dohx.lanerc.moe TXT
--     （type=16）→ 标准 base64 → AES-256-ECB（key=ASCII("2dd30ebfb8ed481a31a3-
--     7036eaf7ed3da")，PKCS7 去垫）→ 完整 API URL（当前 "https://v3.yyghk.com/"，
--     GCCDN CDN 大陆直连可达）；TXT 失败用内置兜底同值。旧发现链（domains.
--     lanerc.app 域名对 + 随机前缀子域）已废弃——旧后端 8.209.229.171 被 TLS-RST。
--   签名（dio 拦截器注入 query 参数 sign；头不参与）：
--     nonce = 6 位随机小写字母（真机 HAR 实测纯字母）；ts = 秒级时间戳
--     统一公式（真机 HAR 实测定稿）：sign = "{ts}-{nonce}-{md5("/{path}"@{ts}@
--       {nonce}@盐)}"——首段 ts、payload 路径带前导斜杠；盐硬编码
--       "@4x2g5efd84fb46a9"（含前导 @）。服务端当前不校验签名（坏签名/无签名
--       实测放行——报告的 path 首段/不带斜杠读法亦能过），照 App 真机形态发送
--   头（真机 HAR 实测仅三个，均不参与签名）：user-agent: Dart/3.9.2 (dart:io)、
--     content-type: application/json; charset=utf-8、accept-encoding: gzip；
--     静态里的 accept: x-protobuf 与 Authorization 真机均未发送（实测所有弹幕侧
--     接口无 token 可访问，guest/credential 不需要）
--   响应信封（加密接口）：{"code":201,"data":"<密文>","msg":"Success"}——
--     ⚠️ data 字段为加密载荷：自定义字母表 base64（数字段被置换为 0523496781，
--     末两字符 "/-"，运行期拼装——池中无字面量）→ AES-256-ECB（key=ASCII(
--     "8f81c2519e3b661834219e7142000093")，静态定位 pp+0x133a0 紧邻
--     "responseCodec"）→ PKCS7 去垫 → 明文 JSON。密钥固定无随机 IV（App 与复现
--     请求密文前 16288 字节一致实锤）。错误口径 code=400 且 data=""（缺参数
--     "请求参数解析失败" / 坏 vod_id "获取视频数据失败"）——data 为空串不可解密。
--     health 响应例外：明文 {"status":true} 无信封无 data。
--   搜索 GET app/vod/search?keyword={关键词}（⚠️ 参数名 keyword，wd= 报 400）→
--     明文 {"search_vods":[{id, vod_name, vod_year(字符串), vod_class, vod_isend,
--     vod_total, vod_author, vod_pic}]}；空结果 search_vods=[]；多季番为独立条目
--   详情 GET app/v2/vod/{vod_id} → 明文 {"video_play_info":{vod_name, vod_year,
--     vod_total, vod_remarks, …}, "video_play_list":[{player, name, sort,
--     video:[{title, resource_id, can_play_without_login}]}]}——线路取首个非空
--     （App 默认首选线路 sort 最高），列表序=集数序；resource_id 为选集不透明
--     token（仅视频流解析用，弹幕侧不需要）
--   弹幕 GET app/chat/barragev2?vid={番剧 vod_id}&vod={集序号}（1 起）→ 明文
--     {"new_barrages":[…], "old_barrages":[…]}（键序不定——App 真机样本
--     old_barrages 在前，须按 key 取不可依赖顺序）；单次全量无分页无时间窗分段
--     （真机 HAR query 仅 vid/vod/sign）；条目字段严格等于 {id, bcolor, position,
--     second, content}——匿名弹幕无 uid/nick。bcolor 为 "#AARRGGBB" 8 位十六进制
--     字符串（如 #ffffffff 白 / #ff00a0ea 蓝）；position 实测仅 0(滚动)/1(顶部)
--     （0→143 条、1→22 条、2→0 条），bottom=2 候选未见样本；second 秒 0~1420。
--     ⚠️ vid/vod 参数语义（2026-10-15 真机 HAR 实锤）：vid=番剧 vod_id（与
--     搜索/详情同一 id）、vod=集序号——与静态报告「vid 由 resource_id 经
--     app/v2/play 解析」的推断相反（play 响应为 protobuf 流 token 与弹幕无关），
--     弹幕侧无需 play 解析。无效 vid / 越界集序号均返回 code=201 + 空数组
--     （合法空口径——错误 vid 与无弹幕不可区分，按无弹幕处理）
--   ⚠️ vid/vod 源头 Dart int(64 位)，JSON 按字符串处理防 >2^53 截断

local utils = require("mp.utils")
local md5 = require("modules/md5")
local b64 = require("modules/base64")
local AES = require("modules/aes")

local M = {}

-- 签名盐（含前导 @；libapp.so pp+0x11b70，通用拦截器与 health 两处引用）
M.SIGN_SALT = "@4x2g5efd84fb46a9"
-- 域名 TXT 发现的 AES-256-ECB key（32 字节 ASCII 字符串本身；标准 base64）
M.TXT_AES_KEY = "2dd30ebfb8ed481a3317036eaf7ed3da"
-- 响应体 data 字段的 AES-256-ECB key（pp+0x133a0 紧邻 "responseCodec"）
M.RESP_AES_KEY = "8f81c2519e3b661834219e7142000093"
-- 域名发现的 TXT 记录名（App 真正查询的域名；旧 domains.lanerc.app 已废弃）
M.TXT_DOMAIN = "dohx.lanerc.moe"
-- TXT 发现失败时的兜底 API base（与当前 TXT 记录解密值一致；站方换域名时
-- TXT 先行更新，兜底值随发布页维护）
M.FALLBACK_API_BASE = "https://v3.yyghk.com"

-- ⚠️ modules/aes.lua 的 key 须为 0 基字节表（main.lua 的 KEY 同款约定），密文为
-- 字符串；本模块自带转换不依赖全局 table_to_zero_indexed（保持纯模块）
local function zero_indexed_bytes(s)
    local t = {}
    for i = 1, #s do t[i - 1] = s:byte(i) end
    return t
end
local TXT_KEY_BYTES = zero_indexed_bytes(M.TXT_AES_KEY)
local RESP_KEY_BYTES = zero_indexed_bytes(M.RESP_AES_KEY)

-- ============ 签名 ============

local nonce_seeded = false

-- 6 位随机小写字母（非安全边界——服务端实测不校验签名，弱随机即可）
function M.nonce()
    if not nonce_seeded then
        nonce_seeded = true
        math.randomseed(os.time() + math.floor((os.clock() % 1) * 1000000))
    end
    local buf = {}
    for i = 1, 6 do buf[i] = string.char(97 + math.random(0, 25)) end
    return table.concat(buf)
end

-- 通用签名 payload（path 须带前导斜杠，与真机 HAR 一致）
function M.general_payload(path, ts, nonce)
    return path .. "@" .. ts .. "@" .. nonce .. M.SIGN_SALT
end

-- 统一签名公式（真机 HAR 实测定稿，验证向量见 tests/omofun_parse_test.lua）：
--   sign = "{ts}-{nonce}-{md5("/{path}"@{ts}@{nonce}@盐)}"
-- path 传入不带前导斜杠（调用方路径常量形态）；ts 为秒级时间戳。
-- 服务端当前不校验签名（坏签名/无签名实测放行），照 App 真机形态发送
function M.sign_general(path, ts, nonce)
    local payload = M.general_payload("/" .. path, ts, nonce)
    return ts .. "-" .. nonce .. "-" .. md5.sum(payload)
end

-- ============ 域名发现（DoH TXT） ============

-- TXT 记录值（标准 base64，可能带 DNS 引号包裹）→ 明文完整 API URL；
-- 解密失败 / 非 URL 形态返回 nil（调用方用兜底 base）
function M.decrypt_domain_txt(txt)
    if type(txt) ~= "string" then return nil end
    local s = txt:gsub('^"', ""):gsub('"$', ""):gsub("%s+", "")
    if s == "" then return nil end
    local ok_ct, ct = pcall(b64.decode, s)
    if not ok_ct or type(ct) ~= "string" or #ct == 0 or #ct % 16 ~= 0 then return nil end
    local ok_pt, pt = pcall(AES.ECB.decrypt, TXT_KEY_BYTES, ct)
    if not ok_pt or type(pt) ~= "string" then return nil end
    if not pt:match("^https?://[%w%.%-]+:?%d*/?$") then return nil end
    return pt:gsub("/$", "")
end

-- ============ 响应体解密（自定义字母表 base64 → AES-256-ECB → PKCS7） ============

-- 自定义字母表：标准表数字段（index 52..61）被置换为 "0523496781"，末两字符 "/-"；
-- 字母表为运行期拼装（池中无字面量），据 lanerc_crypto.py 实测定稿
local CUSTOM_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0523496781/-"
local CUSTOM_DEC = {}
for i = 1, #CUSTOM_B64 do
    CUSTOM_DEC[CUSTOM_B64:byte(i)] = i - 1
end

-- 自定义字母表 base64 解码（容忍 '=' 填充与空白；含非法字符返回 nil）
function M.custom_b64_decode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s+", ""):gsub("=+$", "")
    if s == "" then return nil end
    local out, n, bits = {}, 0, 0
    for i = 1, #s do
        local v = CUSTOM_DEC[s:byte(i)]
        if not v then return nil end
        bits = bits * 64 + v
        n = n + 6
        if n >= 8 then
            n = n - 8
            out[#out + 1] = string.char(math.floor(bits / 2 ^ n) % 256)
            bits = bits % 2 ^ n  -- 已提取的高位清零，防 bits 无限增长丢精度
        end
    end
    return table.concat(out)
end

-- 响应 data 字段 → 明文字符串；非 16 字节对齐 / 解密失败 / 非 UTF-8 可判形态
-- 返回 nil（调用方按接口错误口径处理）
function M.decrypt_response(data)
    if type(data) ~= "string" or data == "" then return nil end
    local ok_ct, ct = pcall(M.custom_b64_decode, data)
    if not ok_ct or type(ct) ~= "string" or #ct == 0 or #ct % 16 ~= 0 then return nil end
    local ok_pt, pt = pcall(AES.ECB.decrypt, RESP_KEY_BYTES, ct)
    if not ok_pt or type(pt) ~= "string" or #pt == 0 then return nil end
    return pt
end

-- ============ 响应信封 ============

-- 加密接口信封成功判定：code 201（实测）/ 200（防御）为成功；data 为空串或缺失
-- 按错误（badwd/bad detail 实测 code=400 data=""）
function M.code_ok(d)
    if type(d) ~= "table" then return false end
    local c = tonumber(d.code)
    return c == 201 or c == 200
end

-- 原始响应 JSON 字符串 → { ok=bool, payload=明文 JSON 表|nil, msg, code }
-- ok=false = 网络层外的一切失败（非 JSON / code≠201/200 / data 空 / 解密失败 /
-- 明文非 JSON）；成功时 payload 为解密后的业务表
function M.parse_envelope(raw)
    local out = { ok = false, payload = nil, msg = nil, code = nil }
    if type(raw) ~= "string" or raw == "" then return out end
    local d = utils.parse_json(raw)
    if type(d) ~= "table" then return out end
    out.code = tonumber(d.code)
    out.msg = type(d.msg) == "string" and d.msg or nil
    if not M.code_ok(d) or type(d.data) ~= "string" or d.data == "" then return out end
    local pt = M.decrypt_response(d.data)
    if not pt then return out end
    local payload = utils.parse_json(pt)
    if type(payload) ~= "table" then return out end
    out.ok = true
    out.payload = payload
    return out
end

-- ============ 搜索（/app/vod/search?keyword= 响应明文） ============

-- → { ok=bool, items={ {vod_id, title, year, total, is_end, class_name} } }
-- 条目字段 {id, vod_name, vod_year(字符串), vod_class, vod_isend, vod_total}；
-- 无 id 或无名的条目跳过；ok 仅表示完成解析流程（含空结果空表）
function M.parse_search(payload)
    local out = { ok = false, items = {} }
    if type(payload) ~= "table" then return out end
    out.ok = true
    local list = type(payload.search_vods) == "table" and payload.search_vods or {}
    for _, it in ipairs(list) do
        if type(it) == "table" and it.id ~= nil then
            local title = type(it.vod_name) == "string" and it.vod_name or ""
            if title ~= "" then
                out.items[#out.items + 1] = {
                    vod_id = tostring(it.id),
                    title = title,
                    year = tonumber(it.vod_year) or 0,
                    total = tonumber(it.vod_total) or 0,
                    is_end = it.vod_isend,
                    class_name = type(it.vod_class) == "string" and it.vod_class or "",
                }
            end
        end
    end
    return out
end

-- ============ 详情选集（/app/v2/vod/{vod_id} 响应明文） ============

-- → { ok=bool, episodes={ {resource_id, title} }, count, vod_name, year, total }
-- video_play_list[] 为线路列表（{player, name, sort, video=[集数组]}），取首个
-- 非空线路（App 默认首选线路，sort 最高）；列表序=集数序（App 渲染序，不重排）；
-- ⚠️ 集条目只有 resource_id（vid 须经 guest/play 解析，见 sites/omofun.lua）；
-- video_play_info 的番剧元数据透传（vod_total 用于越界判定、vod_year 用于标题）
function M.parse_detail(payload)
    local out = { ok = false, episodes = {}, count = 0,
        vod_name = nil, year = 0, total = 0 }
    if type(payload) ~= "table" then return out end
    out.ok = true
    local info = type(payload.video_play_info) == "table" and payload.video_play_info or {}
    out.vod_name = type(info.vod_name) == "string" and info.vod_name or nil
    out.year = tonumber(info.vod_year) or 0
    out.total = tonumber(info.vod_total) or 0
    local eps = nil
    if type(payload.video_play_list) == "table" then
        for _, line in ipairs(payload.video_play_list) do
            if type(line) == "table" and type(line.video) == "table"
                and #line.video > 0 then
                eps = line.video
                break
            end
        end
    end
    if not eps then return out end
    for _, e in ipairs(eps) do
        if type(e) == "table" and type(e.resource_id) == "string" and e.resource_id ~= "" then
            out.episodes[#out.episodes + 1] = {
                resource_id = e.resource_id,
                title = type(e.title) == "string" and e.title or "",
            }
        end
    end
    out.count = #out.episodes
    return out
end

-- ============ 弹幕（/app/chat/barragev2 响应明文） ============

-- bcolor "#AARRGGBB"（8 位，丢弃 alpha）/"#RRGGBB"（6 位）→ 整数 RGB；十进制整数
-- 原样；无效兜底白 0xFFFFFF（实测全 8 位形态，6 位/整数为防御分支）
local function parse_color(v)
    if type(v) == "number" then return math.floor(v) end
    if type(v) == "string" then
        local s = v:gsub("^#", ""):gsub("%s+", "")
        if s:match("^%x%x%x%x%x%x%x%x$") then return tonumber(s:sub(3), 16) end
        if s:match("^%x%x%x%x%x%x$") then return tonumber(s, 16) end
        if s:match("^%d+$") then return tonumber(s) end
    end
    return 0xFFFFFF
end

-- position：实测 0=scroll 滚动（绝大多数）/ 1=top 顶部；bottom（候选 2）全站未见
-- ——除 0/1 外一律按滚动兜底（与 sendbarrage 表单枚举对齐的口径，出现新值时校准）
local function position_to_mode(position)
    if position == 1 then return 5 end
    return 1
end

-- → { ok=bool, comments={ {time=秒, color=整数RGB, mode=1/5, text} } }
-- new_barrages 与 old_barrages 拼接（两组仅客户端展示语义，old 实测恒空）；
-- 键序不定（App 样本 old 在前）——按 key 取不依赖顺序；无效 vid/vod 与无弹幕
-- 同口径（code=201 + 空数组，合法空）；畸形单条（缺 second/content）跳过不击穿
-- 整批；防御性升序再排（实测样本同秒乱序）
function M.parse_danmaku(payload)
    local out = { ok = false, comments = {} }
    if type(payload) ~= "table" then return out end
    out.ok = true
    for _, key in ipairs({ "new_barrages", "old_barrages" }) do
        local arr = type(payload[key]) == "table" and payload[key] or nil
        if arr then
            for _, c in ipairs(arr) do
                if type(c) == "table" then
                    local sec = tonumber(c.second)
                    local text = type(c.content) == "string" and c.content or ""
                    if sec and text ~= "" then
                        out.comments[#out.comments + 1] = {
                            time = sec,
                            color = parse_color(c.bcolor),
                            mode = position_to_mode(tonumber(c.position)),
                            text = text,
                        }
                    end
                end
            end
        end
    end
    table.sort(out.comments, function(a, b) return a.time < b.time end)
    return out
end

return M
