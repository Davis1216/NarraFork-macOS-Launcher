# NarraFork 核心二进制文件存放目录 (Core Binaries)

本目录用于存放官方编译的 NarraFork 离线核心服务端二进制文件（如 `narrafork-0.7.0-macos-arm64`）。

### 📥 核心获取与使用方法

1. **下载或放置核心文件**：
   - 将下载得到的 macOS 核心可执行文件（例如 `narrafork-0.7.0-macos-arm64`）直接放入本 `bin/` 目录中。
   - 文件名需包含版本号及架构（例如包含 `narrafork` 和 `macos`）。

2. **自动识别打包**：
   - 项目根目录下的 `一键打包App.command` 会自动优先扫描并捕获本目录中最新版本的核心二进制。
   - 打包脚本会自动为二进制赋予执行权限 (`chmod +x`) 并完成 macOS 隔离属性清理 (`xattr -cr`)。

3. **版本保留**：
   - 本目录已在 `.gitignore` 中配置忽略实际可执行文件，防止将数十兆的二进制产物提交至 Git 仓库。
