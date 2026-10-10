-- search_hub 纯函数单元测试（分组构建/进度行/provider 标签映射）
-- 运行：mpv.com --idle=once --no-config --script=<本文件路径>
-- 退出码非 0 或输出含 FAIL 即失败

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*)[/\\]") or "."
local root = script_dir:match("^(.*)[/\\]") or "."
package.path = root .. "/?.lua;" .. package.path

local hub = require("modules/search_hub")
require("modules/utils") -- provider_label_from_url 等全局

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- ---------- build_grouped_items ----------

do
    local d_item = { title = "番剧A", hint = "TV动画", value = { "v", 1 } }
    local t_item = { title = "番剧A", hint = "动漫 | 2023", value = { "v", 2 } }
    local k_item = { title = "番剧A", hint = "动漫 | 2023 | 来源：b 站", value = { "v", 3 } }
    local m_item = { title = "番剧A", hint = "2023|国产动漫|x.com|全24集", value = { "v", 4 } }

    local items = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = { t_item } },
        kan360 = { items = { k_item } },
        maccms = { items = { m_item } },
    })
    check("四组顺序 dandanplay→腾讯→360kan→maccms",
        #items == 8
        and items[1].title == "── dandanplay ──" and items[2] == d_item
        and items[3].title == "── 腾讯 ──" and items[4] == t_item
        and items[5].title == "── 360kan ──" and items[6] == k_item
        and items[7].title == "── maccms ──" and items[8] == m_item)

    local h = items[1]
    check("组头形状 bold/不可选/居中",
        h.bold == true and h.selectable == false and h.align == "center" and h.keep_open == true)

    -- nil 键整组跳过（源未参与，如未配置 maccms）
    local items2 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = { t_item } },
        kan360 = { items = { k_item } },
    })
    check("nil 组跳过", #items2 == 6 and items2[7] == nil)

    -- 空结果组隐藏（连组头都不出）
    local items3 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { items = {} },
        kan360 = { items = { k_item } },
    })
    check("空组隐藏", #items3 == 4 and items3[1].title == "── dandanplay ──"
        and items3[3].title == "── 360kan ──")

    -- 失败组：组头 + 错误行（占住组位）
    local items4 = hub.build_grouped_items({
        dandanplay = { items = { d_item } },
        tencent = { err = "请求失败" },
        kan360 = { err = "超时" },
    })
    check("错误组=组头+错误行", #items4 == 6
        and items4[3].title == "── 腾讯 ──" and items4[4].title == "请求失败"
        and items4[5].title == "── 360kan ──" and items4[6].title == "超时")
    check("错误行形状 italic/muted/不可选",
        items4[4].italic == true and items4[4].muted == true and items4[4].selectable == false)

    -- 全空/全 nil → 单行「无结果」
    local items5 = hub.build_grouped_items({
        dandanplay = { items = {} },
        tencent = { items = {} },
        kan360 = { items = {} },
    })
    check("全空→单行无结果", #items5 == 1 and items5[1].title == "无结果"
        and items5[1].selectable == false and items5[1].italic == true)
    check("空表入参→单行无结果", #hub.build_grouped_items({}) == 1)
end

-- ---------- progress_title / progress_row ----------

do
    local title = hub.progress_title({
        dandanplay = { status = "pending", done = 2, total = 3 },
        tencent = { status = "done", count = 5 },
        kan360 = { status = "pending" },
        maccms = { status = "error" },
    })
    check("进度标题混合态",
        title:find("dandanplay 2/3", 1, true) ~= nil
        and title:find("腾讯 ✓ 5条", 1, true) ~= nil
        and title:find("360kan 搜索中", 1, true) ~= nil
        and title:find("maccms ✗", 1, true) ~= nil)

    local title2 = hub.progress_title({
        dandanplay = { status = "done", count = 0 },
    })
    check("nil 源不显示/完成0条", title2:find("dandanplay ✓ 0条", 1, true) ~= nil
        and title2:find("腾讯", 1, true) == nil)

    local row = hub.progress_row("聚合搜索中 ...")
    check("进度行形状 italic+spinner+不可选（strip 兼容）",
        row.italic == true and row.icon == "spinner" and row.selectable == false
        and row.value == "")
end

-- ---------- provider_label_from_url（utils） ----------

do
    check("provider bilibili",
        provider_label_from_url("https://www.bilibili.com/bangumi/play/ep123") == "bilibili")
    check("provider bilivideo",
        provider_label_from_url("https://upos.example.com/xx") == nil -- 无匹配 host
        and provider_label_from_url("https://xy123.bilivideo.cn/a.m4s") == "bilibili")
    check("provider 腾讯",
        provider_label_from_url("https://v.qq.com/x/cover/a/b.html") == "腾讯视频")
    check("provider 爱奇艺/优酷/芒果/巴哈",
        provider_label_from_url("https://www.iqiyi.com/v_1.html") == "爱奇艺"
        and provider_label_from_url("https://v.youku.com/v_show/id_x.html") == "优酷"
        and provider_label_from_url("https://www.mgtv.com/b/1/2.html") == "芒果TV"
        and provider_label_from_url("https://bahamut.akamaized.net/x") == "巴哈姆特")
    check("provider 未知/非串",
        provider_label_from_url("https://unknown.example/a") == nil
        and provider_label_from_url(nil) == nil
        and provider_label_from_url(123) == nil)
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("ALL PASS")
os.exit(0)
