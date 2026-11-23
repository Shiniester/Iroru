# ADR 0008: 按视频源区分本机资料并保留 MissAV 旧标识

视频源之间分别保存视频续播进度和视频下载。
MissAV 继续使用源站 ID 作为本机标识。

## 决策

`VideoItem.id` 保留源站原生 ID。
`VideoItem.sourceKey` 标识视频源。
旧资料缺少 `sourceKey` 时，按 MissAV 读取。

本机资料统一使用 `VideoItem.storageKey`：

- MissAV 使用原始 `id`。
- Jable 使用 `jable:<id>`。

视频续播进度、下载任务和集合条目使用这个标识。
视频下载保存在下载根目录的 `videos` 子目录，任务目录沿用原编码方式。
升级后，原 `video_downloads` 目录的文件留在原处。离线播放需要重新下载。
旧续播进度按 [ADR 0016](0016-unified-local-history.md) 处理。

## 原因

不同视频源可能使用相同的作品 ID。
直接共用 ID 会让下载任务或视频续播进度互相覆盖。

原生 ID 与本机标识分开后，源站请求继续使用原生 ID。
账号接口中的 `VideoLink.sourceKey` 保留现有含义。
