# Android 正式版与测试版共用安装

Android 正式版与测试版共用 `com.meteor.iroru` 和发行签名。用户可以在同一个
Iroru 安装内切换更新渠道，并保留该安装的数据。两条渠道共用 Android 版本号规则，
应用只提示可覆盖安装的新版本。

旧 Iroru Beta 的安装与数据留在原处。仅安装了旧 Iroru Beta 的用户可通过发布说明
获取统一版。统一版使用自己的数据，不导入旧应用的数据。这项决定取代
[ADR 0014](0014-iroru-independent-installation.md)为 Android 测试版单设安装标识的决定。
