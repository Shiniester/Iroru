# MissAV 镜像访问

MissAV 在 Cloudflare 验证下无法直接读取。应用改用官方备用域名和匿名镜像站。
方案参考 [HANiEX](https://github.com/lwprfs/HANiEX) 的 MissAV 主机列表和 Recombee 搜索。

## 访问顺序

1. 用户在设置页选择线路时，先测速该线路。
2. 未选择线路时，并发请求自动候选域名的目录页。`missav.ws` 和 `missav.live` 优先于第三方镜像。
3. 候选域名返回正常页面时，保留该站作为本次运行的内容主机。
4. 所有镜像站均失败时，请求 `https://missav.ai`；仍遇到验证页时恢复浏览器会话和“验证访问”流程。

镜像站会把 `/cn` 等路径重定向到 `/dmNNN/...`。
现有地址处理保留该前缀，后续分页和详情链接沿用同一路径。

## 域名测速

线路列表共 36 个域名，全部通过以下筛选：

- `https://<域名>/status.html` 返回 HTTP 200 和 `ok`。
- `https://<域名>/cn` 返回 HTTP 200，响应头不含 `cf-mitigated: challenge`。

测速请求 `https://<域名>/status.html?ts=<时间戳>`。
只有状态码 200、正文为 `ok` 且没有验证标记的域名计入延迟。
自动选择直接请求 7 个候选域名的 `/<locale>/release`。
目录页请求超时为 3 秒。
只有目录页返回 HTTP 200、包含 HTML 且没有验证标记的域名参与最终选优。
完整列表在 [missav_mirrors.dart](../../lib/src/videos/missav_mirrors.dart)。

测速前等待系统代理解析完成。
`www.missav365.icu`、`www.njavtv.nl`、`www.missav666.net` 曾在未初始化系统代理的测试中连接失败；初始化系统代理后均通过，已保留。
测速超时只影响本次自动选择，不从列表删除；只有确认返回 Cloudflare 验证的域名会排除。

在视频设置的 **MissAV 线路** 中，可查看全部域名的延迟、选择线路、重新测速或恢复自动选择。
选择结果写入 `missav_mirror_base_url`。
自动选择只使用测速通过的非 Cloudflare 域名。
不可用线路保留展示，但不能选择。
旧版镜像域名 `thisav66.com` 不参与测速，只用于识别已保存的页面地址；请求改写到当前线路。

## 搜索

镜像站的搜索结果由浏览器脚本生成，原生 HTML 只含少量无关卡片。
搜索页始终优先调用 Recombee 搜索接口，接口无结果时才保留 HTML 卡片：

```text
POST https://client-rapi-missav.recombee.com/missav-default/search/users/anonymous/items/
```

请求体使用 `searchQuery`、`scenario: "search"` 和 `returnProperties: true`。
后续页使用返回的 `recommId` 调用 `recomms/next/items/{recommId}`。

## 播放与下载

镜像站详情页把媒体地址改写为 `https://<镜像站>/jmpres/<原始主机>/<路径>`。
应用解析打包脚本后执行同样的改写。
播放器和下载器收到的请求头使用镜像站页面作为 `Referer` 和 `Origin`。

## 账号 Cookie

MissAV 账号 Cookie 只发送给官方域名 `missav.ai`、`missav.ws` 和 `missav.live`。
第三方镜像不接收账号 Cookie。
登录、收藏、播放列表和观看历史使用同一源站账号态。
镜像响应不写回源站会话，避免覆盖本地 Cookie。
登录由账号页提交；验证窗口只通过 Cloudflare。
账号登录默认按 `missav.live`、`missav.ws`、`missav.ai` 顺序尝试，账号页可选择线路。
登录成功后关闭验证浏览器，内容回到当前线路。
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
| `flutter test --no-pub test/videos/missav_client_test.dart` | 117 项通过，1 项跳过 |
| `flutter test --no-pub test/videos/missav_mirrors_test.dart test/videos/missav_mirror_settings_test.dart` | 5 项通过 |
| `flutter analyze --no-pub` 指定本次修改文件 | 通过 |
| `flutter test --no-pub test/videos` | 649 项通过，1 项跳过；2 项既有抽屉测试失败，基线同样失败 |
| 真实镜像探测：目录返回 12 条，搜索返回 24 条，分类目录返回 37 项，分类页返回 12 条，详情提取 `jmpres` 媒体地址 | 通过 |
| 真实自动测速：选择可用线路（最近一次为 `www.missav666.cc`），目录返回 12 条 | 通过 |

本轮未在 Android 或 iOS 设备上验证镜像站播放和下载。
