# MissAV 镜像访问

MissAV 在 Cloudflare 验证下无法直接读取。应用改用官方备用域名和匿名镜像站。
方案参考 [HANiEX](https://github.com/lwprfs/HANiEX) 的 MissAV 主机列表和 Recombee 搜索。

## 访问顺序

1. 目录、视频详情、播放列表封面和首页推荐先尝试手动选择的线路，再尝试上次可用内容线路。
2. 发生线路故障时，按实测顺序逐条尝试其余镜像。
3. 镜像因线路故障全部失败后，按 `missav.live`、`missav.ws`、`missav.ai` 尝试官方线路。

页面通过检查后才更新当前线路。只有通过检查的镜像页面可以更新上次可用内容线路。手动选择只在遇到 Cloudflare 验证时清除。换线条件和页面检查规则见 [ADR 0012](../adr/0012-missav-content-host-cache.md)。

镜像站会把 `/cn` 等路径重定向到 `/dmNNN/...`。
现有地址处理保留该前缀，后续分页和详情链接沿用同一路径。
视频页直接请求第一页，不单独预测速，也不持久化页面内容。

## 域名测速

线路列表共 34 个镜像。线路测试请求 `https://<域名>/cn?ts=<时间戳>`，超时 12 秒，并发 3。
只有状态码 200、正文包含 HTML 且没有验证标记的域名计入延迟。
测试路径与浏览器实际打开首页的路径一致，不使用 `/status.html`。

内容页不再预测速。线路测试用于手动选择，不参与首次内容请求。
完整列表在 [missav_mirrors.dart](../../lib/src/videos/missav_mirrors.dart)。

测速前等待系统代理解析完成。
`www.missav365.icu`、`www.njavtv.nl`、`www.missav666.net` 曾在未初始化系统代理的测试中连接失败；初始化系统代理后均通过，已保留。
测速超时只影响本次线路测试，不从列表删除；只有确认返回 Cloudflare 验证的域名会排除。

2026-11-16 实测：34 个镜像均返回 HTML 且没有 `cf-mitigated: challenge`；`missav.live` 和
`missav.ws` 返回 403 和 Cloudflare 验证。镜像列表按本次实测延迟排序，缓存线路仍优先于该顺序。

在视频设置的 **MissAV 线路** 中，可查看全部镜像的延迟、选择线路或重新测速。
选择结果写入 `missav_mirror_base_url`。
官方线路不在镜像列表中，只作为内容页的最后回退。
不可用线路保留展示，但不能选择。
旧版镜像域名 `thisav66.com` 不参与测速，只用于识别已保存的页面地址；请求改写到当前线路。

## 搜索

搜索直接请求 Recombee，不先读取镜像页面。只有请求失败或响应无效时，搜索才回退到镜像页面。Recombee 成功返回空结果时，搜索显示无结果，不使用镜像卡片。

```text
POST https://client-rapi-missav.recombee.com/missav-default/search/users/anonymous/items/
```

请求体使用 `searchQuery`、`scenario: "search"` 和 `returnProperties: true`。
后续页使用返回的 `recommId` 调用 `recomms/next/items/{recommId}`。
已访问的搜索页只保存在内存中，返回上一页不会继续推进游标。同一页的并发请求共用一次续页请求。新搜索、账号会话或语言变化后，应用重新建立分页状态。回退后的上一页和下一页均沿用镜像链接，重新搜索时再尝试 Recombee。

取消请求本身不会触发镜像回退。取消续页后，再次打开该页时使用镜像分页，避免复用可能已推进的游标。过期响应不会覆盖新搜索的分页状态。

## 播放与下载

镜像站详情页把媒体地址改写为 `https://<镜像站>/jmpres/<原始主机>/<路径>`。
应用解析打包脚本后执行同样的改写。
播放器和下载器收到的请求头使用镜像站页面作为 `Referer` 和 `Origin`。
镜像 HLS 的分段文件名为 `.jpeg`，内容是 MPEG-TS。
项目使用的 mpv 已为 FFmpeg HLS 设置 `extension_picky=0`，下载端把分段保存为 `.ts`。
播放器保留 media_kit 的 `demuxer-lavf-o` 原值，其中 `protocol_whitelist` 是包含逗号的单个值。
将该属性的字符串结果整串写回会拆坏协议白名单，使 HTTPS 媒体加载失败。

Android 播放流使用现有 `native_audio` 通道获取系统证书文件。
原生播放器在打开播放流前设置 `tls-ca-file`，保留证书和主机名校验。

`test/videos/video_native_stream_host_test.dart` 使用真实 libmpv 加载本地多级 HLS 清单和 `.jpeg` 分段。
该测试要求解码完成且播放器未报错，已接入 Windows 正式版和测试版构建检查。
Windows 宿主测试还模拟 Android 证书通道，覆盖可信证书播放和错误主机名拒绝。

## 账号 Cookie

MissAV 账号 Cookie 只发送给官方域名 `missav.ai`、`missav.ws` 和 `missav.live`。
第三方镜像不接收账号 Cookie。
登录、收藏、播放列表和观看历史使用同一源站账号态。
镜像响应不写回源站会话，避免覆盖本地 Cookie。
登录由账号页提交。遇到视频源验证时，应用自动打开验证窗口；取消后也可选择“验证访问”。
在验证窗口登录后，选择**检查访问**接续网页会话。
提交登录后，如果网页只完成视频源验证，应用重试登录一次。
账号登录默认按 `missav.live`、`missav.ws`、`missav.ai` 顺序尝试，账号页可选择线路。
验证浏览器使用 `missav.ai`。通过验证浏览器登录后，账号请求沿用已验证的会话。
视频播放列表和视频观看历史通过账号线路加载。视频播放列表封面沿用内容线路。
镜像详情页不请求源站账号 API；账号 API 返回验证或登录错误时只清空收藏状态，不阻塞详情页。

## 检查结果

2026-11-16 在当前网络直接请求以下地址，均返回 HTTP 403 和 `Cf-Mitigated: challenge`：

- `https://missav.ai/cn`
- `https://missav.ws/cn`
- `https://missav.live/cn`

同一网络请求镜像站，返回 HTTP 200 和 MissAV 页面：

- `https://www.missav9.net/dm247/cn`
- `https://www.thisav66.com/dm247/cn`
- `https://www.missav123.life/dm247/cn`

镜像站详情页的 `jmpres` 媒体地址返回 HTTP 302，跳转到可播放的 HLS 清单，最终返回 HTTP 200。

自动检查：

| 检查范围 | 结果 |
| --- | --- |
| Windows libmpv 真实镜像详情页播放 | 视频尺寸有效，播放进度超过 200 毫秒，无播放错误 |
| 原生 HLS 与 HTTPS、MissAV 解析与转发、视频播放器回归测试 | 290 项通过，1 项跳过 |
| `flutter test --no-pub test/videos/missav_client_test.dart` | 117 项通过，1 项跳过 |
| `flutter test --no-pub test/videos/missav_mirrors_test.dart test/videos/missav_mirror_settings_test.dart` | 5 项通过 |
| `flutter analyze --no-pub` 指定本次修改文件 | 通过 |
| `flutter test --no-pub test/videos` | 649 项通过，1 项跳过；2 项既有抽屉测试失败，基线同样失败 |
| 真实镜像探测：目录返回 12 条，搜索返回 24 条，分类目录返回 37 项，分类页返回 12 条，详情提取 `jmpres` 媒体地址 | 通过 |
| 真实自动测速：选择可用线路（最近一次为 `www.missav666.cc`），目录返回 12 条 | 通过 |

本轮未在 Android 或 iOS 设备上验证镜像站播放和下载。
