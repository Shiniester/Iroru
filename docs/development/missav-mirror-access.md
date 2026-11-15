# MissAV 镜像访问

MissAV 在 Cloudflare 验证下无法直接读取。应用改用匿名镜像站，避免登录和网页验证。
方案参考 [HANiEX](https://github.com/lwprfs/HANiEX) 的 MissAV 主机列表和 Recombee 搜索。

## 访问顺序

1. 请求 `https://missav.ai`。
2. 遇到验证页或 HTTP 403 时，依次尝试以下镜像站：
   - `https://www.missav9.net`
   - `https://www.thisav66.com`
   - `https://www.thisav33.com`
   - `https://www.missav123.life`
3. 镜像站返回正常页面时，保留该站作为本次运行的内容主机。
4. 所有镜像站均失败时，恢复原有浏览器会话和“验证访问”流程。

镜像站会把 `/cn` 等路径重定向到 `/dmNNN/...`。
现有地址处理保留该前缀，后续分页和详情链接沿用同一路径。

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

## 账号隔离

MissAV 账号 Cookie 只发送给 `https://missav.ai`。
镜像站请求不携带 Cookie。
登录、收藏、播放列表和观看历史仍使用源站账号接口。

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
| `flutter test --no-pub test/videos/missav_client_test.dart` | 108 项通过，1 项跳过 |
| `flutter analyze --no-pub lib/src/videos/missav_client.dart test/videos/missav_client_test.dart` | 通过 |
| 真实镜像探测：目录返回 12 条，搜索返回 24 条，分类目录返回 37 项，分类页返回 12 条，详情提取 `jmpres` 媒体地址 | 通过 |

本轮未在 Android 或 iOS 设备上验证镜像站播放和下载。
