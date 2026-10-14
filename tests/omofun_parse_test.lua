-- OmoFun 签名/域名发现/响应解密/搜索/选集/弹幕解析单元测试
-- 样本全部为 2026-10-14/15 线上实抓（tmp/samples → tests/fixtures/omf_*；弹幕侧
-- 元素字段严格等于 {id,bcolor,position,second,content}——匿名弹幕无用户资料字段，
-- 无需剥离）；签名向量含真机 HAR 实抓值（ground truth）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local oparse = require("modules/omofun_parse")
local utils = require("mp.utils")

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

local function read_file(name)
    local f = assert(io.open(script_dir .. "/fixtures/" .. name, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

local function read_json(name)
    return utils.parse_json(read_file(name))
end

-- ============ 签名（真机 HAR 实抓向量 + python hashlib 独立计算） ============

-- 真机 HAR（har_v3.yyghk.com_*）：ts 首段 + payload 路径带前导斜杠（ground truth）
check("通用签名真机 HAR 向量（ts 首段 + / 前缀 payload）",
    oparse.sign_general("app/chat/barragev2", 1791988656, "hhzwps")
        == "1791988656-hhzwps-c0586f4edba961a87f34e9f8986b5df6")
check("通用签名向量 2（python hashlib 独立计算）",
    oparse.sign_general("app/vod/search", 1791980000, "abcdef")
        == "1791980000-abcdef-" .. require("modules/md5").sum(
            "/app/vod/search@1791980000@abcdef@4x2g5efd84fb46a9"))
check("payload 拼接（/{path}@ts@nonce@盐）",
    oparse.general_payload("/app/vod/search", 1791980000, "abcdef")
        == "/app/vod/search@1791980000@abcdef@4x2g5efd84fb46a9")

local n = oparse.nonce()
check("nonce 为 6 位小写字母", type(n) == "string" and n:match("^[a-z][a-z][a-z][a-z][a-z][a-z]$") ~= nil)

-- ============ 域名发现（DoH TXT → 标准 base64 + AES-256-ECB） ============

-- dohx.lanerc.moe TXT 记录实抓值（2026-10-15）→ 完整 API URL
check("真实 TXT 记录解密为 API base",
    oparse.decrypt_domain_txt("1n4aoOeW5/QPKutimGgc78mX2D6i2yUmM2KeDK5jnRY=")
        == "https://v3.yyghk.com")
check("TXT 值带 DNS 引号包裹可解",
    oparse.decrypt_domain_txt('"1n4aoOeW5/QPKutimGgc78mX2D6i2yUmM2KeDK5jnRY="')
        == "https://v3.yyghk.com")
check("非 URL 明文形态拒绝（旧域名对记录）", oparse.decrypt_domain_txt(
    "gZivTY8pnizBa16kuGNq2wYfX1EAQY/51vPOYXFVLlE=") == nil)
check("非 base64 输入拒绝", oparse.decrypt_domain_txt("!!!not-base64!!!") == nil)
check("非 16 字节对齐密文拒绝", oparse.decrypt_domain_txt("QUJD") == nil)
check("非字符串输入拒绝", oparse.decrypt_domain_txt(123) == nil)

-- ============ 响应体解密（自定义字母表 base64 → AES-256-ECB → PKCS7） ============

-- 三份实抓密文逐一与实抓明文比对（密钥固定无随机 IV 的回归锚点）
for _, name in ipairs({ "omf_barrage_6905", "omf_barrage_APP_real", "omf_barrage_2302_1",
    "omf_search", "omf_config", "omf_home", "omf_vod_1", "omf_vod_2302", "omf_vod_5275" }) do
    local pt = oparse.decrypt_response(read_file(name .. ".enc.txt"):gsub("%s+", ""))
    local want = read_file(name .. ".json"):gsub("%s+", "")
    check("解密一致 " .. name, pt ~= nil and pt:gsub("%s+", "") == want)
end

-- 自定义字母表：数字段置换 0523496781——'1' 自定义值 61（标准 53），同一串
-- "ZW1t" 标准解码 "emm"、自定义解码 "eom"，置换位直接可见
check("自定义字母表数字段置换生效", oparse.custom_b64_decode("ZW1t") == "eom")
check("自定义解码容忍 = 填充", oparse.custom_b64_decode("ZW1t==") == "eom")
check("自定义解码拒绝非法字符", oparse.custom_b64_decode("ZW+t") == nil)
check("空串/非串拒绝", oparse.custom_b64_decode("") == nil and oparse.custom_b64_decode(nil) == nil)
check("解密空 data 拒绝", oparse.decrypt_response("") == nil)
check("解密非 16 对齐拒绝", oparse.decrypt_response("QUJD") == nil)

-- ============ 响应信封 ============

check("code 201 成功", oparse.code_ok({ code = 201 }) == true)
check("code 200 成功（防御）", oparse.code_ok({ code = 200 }) == true)
check("code 400 失败", oparse.code_ok({ code = 400 }) == false)
check("code 缺失失败（加密接口必有 code）", oparse.code_ok({}) == false)
check("code \"201\" 字符串成功", oparse.code_ok({ code = "201" }) == true)

local env1 = oparse.parse_envelope(
    '{"code":201,"data":"' .. read_file("omf_barrage_badvid.enc.txt"):gsub("%s+", "")
    .. '","msg":"Success"}')
check("信封解析：无效 vid 的空弹幕载荷可解", env1.ok and type(env1.payload) == "table")
check("信封解析：空数组口径", type(env1.payload.old_barrages) == "table"
    and #env1.payload.old_barrages == 0 and #env1.payload.new_barrages == 0)
local env2 = oparse.parse_envelope(read_file("omf_search_badwd.json"))
check("信封解析：code=400 data 空串为错误", env2.ok == false and env2.code == 400
    and env2.msg == "请求参数解析失败")
check("信封解析：非 JSON 拒绝", oparse.parse_envelope("<html>404</html>").ok == false)
check("信封解析：空串拒绝", oparse.parse_envelope("").ok == false)

-- ============ 搜索（keyword 参数响应明文） ============

local s1 = oparse.parse_search(read_json("omf_search.json"))
check("搜索两季条目（芙莉莲 S1/S2 独立条目）", s1.ok and #s1.items == 2)
check("搜索条目字段（id/vod_name/vod_year 字符串/vod_total/vod_isend/vod_class）",
    s1.items[1].vod_id == "2302" and s1.items[1].title == "葬送的芙莉莲"
        and s1.items[1].year == 2023 and s1.items[1].total == 28
        and s1.items[1].is_end == 1 and s1.items[1].class_name == "奇幻,冒险")
check("搜索 S2 条目（2026/10 集）",
    s1.items[2].vod_id == "5275" and s1.items[2].year == 2026 and s1.items[2].total == 10)
local s2 = oparse.parse_search(read_json("omf_search_empty_pt.json"))
check("搜索空结果合法（ok 且零条目）", s2.ok and #s2.items == 0)
check("搜索非表输入失败", oparse.parse_search("x").ok == false)
check("搜索无 search_vods 结构为合法空", (function()
    local r = oparse.parse_search({})
    return r.ok and #r.items == 0
end)())
check("搜索畸形条目跳过", (function()
    local r = oparse.parse_search({ search_vods = { { vod_name = "缺id" },
        { id = 9 }, { id = 10, vod_name = "ok" } } })
    return r.ok and #r.items == 1 and r.items[1].vod_id == "10"
end)())

-- ============ 详情选集（video_play_list 线路结构） ============

local d1 = oparse.parse_detail(read_json("omf_vod_1.json"))
check("详情单集番（进击的巨人完结篇前篇）：3 线路取首个非空",
    d1.ok and d1.count == 1 and d1.episodes[1].title == "前篇"
        and #d1.episodes[1].resource_id > 100)
check("详情元数据透传（video_play_info）",
    d1.vod_name == "进击的巨人 最终季 完结篇 前篇" and d1.year == 2023 and d1.total == 1)

local d2 = oparse.parse_detail(read_json("omf_vod_2302.json"))
check("详情多集番（芙莉莲 S1）：28 集取首选线路",
    d2.ok and d2.count == 28 and d2.episodes[1].title == "第01集"
        and d2.episodes[28].title == "第28集")
check("详情每集 resource_id 独立", d2.episodes[1].resource_id ~= d2.episodes[2].resource_id)

check("详情非表输入失败", oparse.parse_detail("x").ok == false)
check("详情无线路结构为合法空", (function()
    local r = oparse.parse_detail({ video_play_info = { vod_total = 1 } })
    return r.ok and r.count == 0
end)())
check("详情畸形条目与空线路跳过", (function()
    local r = oparse.parse_detail({ video_play_list = {
        { player = "x", video = {} },
        { player = "y", video = { { title = "无rid跳过" }, { resource_id = "r1", title = "1" } } },
    } })
    return r.ok and r.count == 1 and r.episodes[1].resource_id == "r1"
end)())

-- ============ 弹幕（new/old 两组、bcolor 8 位、position 0/1） ============

local b1 = oparse.parse_danmaku(read_json("omf_barrage_6905.json"))
local b1_app = oparse.parse_danmaku(read_json("omf_barrage_APP_real.json"))
local b1_fr = oparse.parse_danmaku(read_json("omf_barrage_2302_1.json"))
check("弹幕 167 条全量（复现请求样本）", b1.ok and #b1.comments == 167)
check("弹幕 165 条全量（App 真机样本，键序 old 在前——按 key 取不依赖顺序）",
    b1_app.ok and #b1_app.comments == 165)
check("弹幕 5490 条全量（芙莉莲 ep1 原始 new=751+old=4746 两组拼接，old 组非空实锤；7 条畸形防御性跳过）",
    b1_fr.ok and #b1_fr.comments == 5490)
check("弹幕按秒升序", (function()
    for i = 2, #b1.comments do
        if b1.comments[i - 1].time > b1.comments[i].time then return false end
    end
    return true
end)())
check("弹幕 bcolor #ffffffff → 白", (function()
    for _, c in ipairs(b1.comments) do
        if c.color ~= 0xFFFFFF and c.color ~= 0x00A0EA and c.color ~= 0xFF2E2E
            and c.color ~= 0xFFEE16 and c.color ~= 0xD159CD then
            return false  -- 样本五色之外即换算错误
        end
    end
    return true
end)())
check("弹幕 position 0滚动→1 / 1顶部→5", (function()
    local m0, m1, other = 0, 0, 0
    for _, c in ipairs(b1.comments) do
        if c.mode == 1 then m0 = m0 + 1 elseif c.mode == 5 then m1 = m1 + 1 else other = other + 1 end
    end
    return m0 > 0 and m1 > 0 and other == 0
end)())

check("弹幕无效 vid 空数组合法（badvid 口径）", (function()
    local r = oparse.parse_danmaku(read_json("omf_barrage_badvid.json"))
    return r.ok and #r.comments == 0
end)())
check("弹幕缺正文/缺秒跳过", (function()
    local r = oparse.parse_danmaku({ new_barrages = {
        { second = 1, position = 0 }, { content = "", second = 2 } } })
    return r.ok and #r.comments == 0
end)())
check("弹幕字符串秒可解", (function()
    local r = oparse.parse_danmaku({ new_barrages = {
        { content = "x", second = "7.5", position = 0 } } })
    return #r.comments == 1 and r.comments[1].time == 7.5
end)())
check("弹幕 bcolor 防御分支（6 位 hex / 十进制 / 坏值白 / 8 位丢 alpha）", (function()
    local r = oparse.parse_danmaku({ new_barrages = {
        { content = "a", second = 1, bcolor = "#ff0000" },
        { content = "b", second = 2, bcolor = "68999" },
        { content = "c", second = 3, bcolor = "红色" },
        { content = "d", second = 4 },
        { content = "e", second = 5, bcolor = 12345 },
        { content = "f", second = 6, bcolor = "#80ffffff" },
    } })
    return r.comments[1].color == 0xFF0000 and r.comments[2].color == 68999
        and r.comments[3].color == 0xFFFFFF and r.comments[4].color == 0xFFFFFF
        and r.comments[5].color == 12345 and r.comments[6].color == 0xFFFFFF
end)())
check("弹幕 position 未知值按滚动兜底", (function()
    local r = oparse.parse_danmaku({ new_barrages = {
        { content = "x", second = 1, position = 2 } } })
    return r.comments[1].mode == 1
end)())
check("弹幕非表输入失败", oparse.parse_danmaku("x").ok == false)

if failures == 0 then
    print("ALL PASS")
else
    print(failures .. " FAILED")
end
os.exit(failures > 0 and 1 or 0)
