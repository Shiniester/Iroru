# Iroru 使用独立安装标识和数据目录

Iroru 使用新的安装标识，以便与旧版分别安装。Android、iOS、macOS 和 Linux
使用 `com.meteor.iroru`。Iroru Beta 使用 `com.meteor.iroru.beta`。
Windows 使用新的 Inno Setup `AppId`。macOS 发布包中的应用文件名为
`Iroru Desktop.app`，以便与旧版的 `Iroru.app` 并存。

新版从独立的数据目录启动，旧应用和旧数据留在原处。新版的默认音声下载和字幕库
位于应用支持目录下的 `downloads`。用户仍可在新版内手动更改下载目录。
遇到同名目录或复制失败时，继续使用原路径并保留源文件。
视频源使用新版专用的密钥存储键。即使系统密钥存储由新旧应用共用，新版也会要求重新登录。

安装包继续通过 `Shiniester/Iroru` 的 GitHub Releases 发布。首次更换安装标识的
版本标为破坏性变更。旧版仍可能显示更新提示，发布说明须注明全新安装要求。
Android 发布包的文件名以安装标识结尾。新版只选择所选更新渠道的安装包。
