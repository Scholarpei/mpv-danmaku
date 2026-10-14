# OmoFun（Lanerc）App API 逆向笔记

> **状态**：✅ 全链路线上验证通过，已接入本插件（2026-10-15，commit `2e19638`）。
> 本文是 tmp/ 逆向工作区（omofun.apk v1.0.8 / blutter 静态 + MuMu·ProxyPin 动态）清理后的存档提炼，
> 含维护所需的全部密钥、算法与排障路径。**知识以本文与 `modules/omofun_parse.lua` 文件头注释为准。**

## 1. 快速事实表

| 项 | 值 |
|---|---|
| App 包名 / 版本 | `com.clggjv.xcjfmd.ffo`（混淆名；镜像包 `com.lhzjxf.omofun` 等为山寨勿用）/ 1.0.8 (32) |
| 平台 | Flutter（iOS 同源），HTTP 栈 dio，**无 WebSocket/QUIC** |
| 官方发布页 | `https://lanerc.app`（加任意前缀可访问）；TG `t.me/omofun1212`（config 公告里是 `@lanerc233`） |
| **API base 发现** | 公共 DoH（App 实际用 doh.pub）查 **`dohx.lanerc.moe` TXT** → 标准 base64 → AES-256-ECB 解密 → **完整 URL**（当前 `https://v3.yyghk.com/`，GCCDN CDN，大陆直连 TLS 11ms） |
| TXT 解密 key | ASCII `"2dd30ebfb8ed481a3317036eaf7ed3da"`（32B；PKCS7 去垫） |
| **统一签名** | `sign = "{ts}-{nonce}-{md5(\"/{path}\"@{ts}@{nonce}@盐)}"`——首段 ts、payload 路径**带**前导斜杠、nonce 6 位小写字母、盐 `@4x2g5efd84fb46a9`（含前导 @）；真机 HAR 实测定稿。**服务端实测不校验签名**（坏/无签名放行），照真机形态发 |
| **响应体加密** | 信封 `{"code":201,"data":"<密文>","msg":"Success"}`；data = 自定义字母表 base64 → AES-256-ECB → PKCS7 → 明文 JSON。密钥固定无随机 IV（App 与复现请求密文前 16288 字节一致实锤） |
| 响应体 key | ASCII `"8f81c2519e3b661834219e7142000093"`（pp+0x133a0，紧邻 `"responseCodec"`） |
| 自定义 base64 字母表 | `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0523496781/-`——**数字段（index 52..61）置换为 `0523496781`**、末两字符 `/-`；运行期拼装，池中无字面量（「有 key 也解不开」的唯一原因） |
| 错误口径 | `code=400` 且 `data=""`（缺参数「请求参数解析失败」/ 坏 vod_id「获取视频数据失败」）；health 例外：明文 `{"status":true}` 无信封 |
| 鉴权 | **无**。全弹幕侧接口无 token 可访问；真机 HAR 仅 `user-agent: Dart/3.9.2`、`content-type: application/json`、`accept-encoding: gzip` 三头，Authorization 未发送 |
| 已废弃 | 旧发现链（`domains.lanerc.app` 域名对 + 随机 4~7 位前缀子域）；旧后端 `*.lanerc.life → 8.209.229.171` 被 TLS-RST。插件规范 URL 仍用 `https://lanerc.life/vod/{vod_id}/{ep}` 作固定标识域（与运行时 base 解耦） |

## 2. 接口清单（弹幕侧全部）

| 接口 | 说明 |
|---|---|
| `GET /app/vod/search?keyword={关键词}` | ⚠️ 参数名 `keyword`（`wd=` 报 400）。明文 `{"search_vods":[{id, vod_name, vod_year(字符串), vod_class, vod_isend, vod_total, vod_author, vod_pic}]}`；多季番独立条目 |
| `GET /app/v2/vod/{vod_id}` | 详情+选集：`{"video_play_info":{…元数据}, "video_play_list":[{player, name, sort, video:[{title, resource_id, can_play_without_login}]}]}`。线路取首个非空（App 默认首选 sort 最高，通常 lcmain=2000）；列表序=集数序；h265 线路新番延迟更新 |
| `GET /app/chat/barragev2?vid={番剧vod_id}&vod={集序号}` | **弹幕。vid=搜索/详情同一 vod_id，vod=选集序号（1 起）**。单次全量无分页无时间窗 |
| `POST /app/v2/play` | 视频流解析（body 为 JSON `{"resource_id":…}`，响应为未加密 protobuf 流 token）。**弹幕侧不需要** |
| `GET /app/health` | `{"status":true}`，明文；响应 `domain` 字段可下发新 API 域名（客户端 0x96cfd8 消费） |
| `GET /app/config` | 版本/广告位/公告/`new_md5` 等开关 |

## 3. 弹幕响应与字段（实测）

- 明文 `{"new_barrages":[…], "old_barrages":[…]}`，**键序不定**（App 真机样本 old 在前），两组都可能有数据（芙莉莲 ep1：new=751 + old=4746 = 5497 条），拼接即可
- 条目字段**严格等于** `{id, bcolor, position, second, content}`——匿名弹幕，无 uid/nick
- `bcolor`：`#AARRGGBB` 8 位十六进制（如 `#ffffffff` 白/`#ff00a0ea` 蓝），取后 6 位
- `position`：`0`=滚动（绝大多数）、`1`=顶部；bottom（候选 2）全站未见——发一条才能实锤
- `second`：秒，0~1420+；**无效 vid / 越界集序号均返回 201+空数组**（与「该集无弹幕」同口径，不可区分）
- 发送表单（`POST app/chat/sendbarrage`，未实测）：`video_id/video_url/color/second/position/content`

## 4. 维护手册

### 域名又换了（现象：全部请求网络失败）
DoH TXT 是权威通道，插件运行时自动跟随，**一般无需动作**。确认现状/更新兜底值：用 §5 的探活脚本跑一遍，把 `FALLBACK_API_BASE`（sites/omofun.lua 与 modules/omofun_parse.lua）改成新值即可。

### 报「解密失败」类错误（现象：code=201 但明文解析不出）
服务端换了响应 key 或字母表（可能性低——key 是编译期常量）。需重新逆向新 APK：
blutter 跑 libapp.so，在 `pp.txt` 搜 `responseCodec`，key 在其上方 pp+0x133a0 附近；字母表置换段运行期拼装，动态抓一份密文用新 key 试解校准。

### 签名被拒（现象：code 突然变 401/403）
当前服务端不验签；若某天开始验：先试本文公式（真机形态），再试静态报告的 path 首段不带斜杠变体；`app/config` 的 `new_md5` 开关暗示存在新旧算法切换。

### App 版本升级
`lanerc.app` 下载新 APK 重跑逆向；dio 三头与接口路径历史稳定，重点核对签名盐与响应 key。

## 5. 最小探活工具（域名/健康/弹幕三连，依赖 pycryptodome）

```python
#!/usr/bin/env python3
"""lanerc_check.py — OmoFun API 探活：DoH TXT → health → barrage（python3 x.py [关键词]）"""
import base64, hashlib, json, random, string, sys, time, urllib3
import requests
urllib3.disable_warnings()
from Crypto.Cipher import AES

SALT = "@4x2g5efd84fb46a9"
TXT_KEY = b"2dd30ebfb8ed481a3317036eaf7ed3da"
RESP_KEY = b"8f81c2519e3b661834219e7142000093"
_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0523496781/-"
_DEC = {c: i for i, c in enumerate(_B64)}
UA = {"user-agent": "Dart/3.9.2", "content-type": "application/json", "accept-encoding": "gzip"}

def b64c(s):  # 自定义字母表解码
    s = s.strip().rstrip("="); bits = n = 0; out = bytearray()
    for ch in s:
        bits = (bits << 6) | _DEC[ch]; n += 6
        if n >= 8: n -= 8; out.append((bits >> n) & 0xFF)
    return bytes(out)

def unpad(b): return b[:-b[-1]] if 1 <= b[-1] <= 16 else b

def sign(path):
    n = "".join(random.choice(string.ascii_lowercase) for _ in range(6)); ts = int(time.time())
    return f"{ts}-{n}-" + hashlib.md5(f"/{path}@{ts}@{n}{SALT}".encode()).hexdigest()

# ① 域名发现
r = requests.get("https://doh.pub/resolve", params={"name": "dohx.lanerc.moe", "type": "txt"},
                 headers=UA, timeout=10, verify=False)
ct = base64.b64decode(r.json()["Answer"][0]["data"].strip('"'))
base = unpad(AES.new(TXT_KEY, AES.MODE_ECB).decrypt(ct)).decode().rstrip("/")
print("API base:", base)
# ② health
print("health:", requests.get(f"{base}/app/health", params={"sign": sign("app/health")},
      headers=UA, timeout=10, verify=False).json())
# ③ 弹幕（默认进击的巨人完结篇，弹量大）
path = "app/chat/barragev2"
vid, vod = (sys.argv[1], sys.argv[2]) if len(sys.argv) > 2 else ("1", "1")
r = requests.get(f"{base}/{path}", params={"vid": vid, "vod": vod, "sign": sign(path)},
                 headers=UA, timeout=15, verify=False)
env = r.json()
obj = json.loads(unpad(AES.new(RESP_KEY, AES.MODE_ECB).decrypt(b64c(env["data"]))))
print(f"barrage vid={vid} vod={vod}: code={env['code']} "
      f"new={len(obj.get('new_barrages', []))} old={len(obj.get('old_barrages', []))}")
```

## 6. 历史考古（已废弃路径，仅供追溯）

- 旧发现链：`domains.lanerc.app` TXT → 解密 `lanerc.app-lanerc.life` 域名对 → `https://{rand4-7[a-z0-9]}.{域名}` 随机前缀（IDA sub_695364）；该链已非实际数据源（App 抓包只查 dohx.lanerc.moe）
- 旧后端 `8.209.229.171`（阿里云）：2026-10-14 实测全球 TCP 拒连（check-host 5 节点 Connection refused），站方公告却称「服务正常」——当时疑似换域过渡期
- `notice.lanerc.app` TXT：同 TXT_KEY 解密的运营公告通道（当时内容「APP服务一切正常…重启APP」）
- 逆向产物原件（blutter_out/pp.txt、HAR、omofun.apk）存于 WSL `~/Reverse-workspace/`
