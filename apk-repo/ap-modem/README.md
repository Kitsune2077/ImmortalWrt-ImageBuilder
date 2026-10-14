# apk-repo/ap-modem

存放 luci-app-ap-modem (+ 中文翻译) 的自编译 **apk** 包, 由
`.github/workflows/build-ap-modem-package.yml` 使用与镜像 ImageBuilder 同版本的
ImmortalWrt SDK 编译后自动提交到这里。

为什么不用 istore 官方 repo-apk 的预编译包: 其 APKv3 产物与 IB 自带的
apk/mkndx 工具链不兼容, 会被 mkndx **静默跳过**, 索引中查无此包, 安装必败
(已实测确认)。自编译产物与 IB 工具链同源, 可正常索引和安装。

镜像 workflow 把本目录挂载为容器内的 `extra-packages/ap-modem/`,
`apk-prepare-packages.sh` 收集进本地 `packages/` 源, 由 `PACKAGES` 正规安装
(设备上可被 apk 管理)。

升级方式: 重新运行 `Build luci-app-ap-modem apk package` workflow 即可
(可指定新的 `app_ref` 或 `sdk_version`), 产物自动覆盖提交。
