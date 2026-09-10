# NarraFork 核心二进制文件目录 (bin)

此目录专门用于存放从官方渠道下载的 NarraFork 核心后端二进制文件。

### 📌 支持芯片架构
- **Apple Silicon 芯片 (M系列)**：例如 `narrafork-0.7.2-macos-arm64`
- **Intel 芯片 (x86_64)**：例如 `narrafork-0.7.2-macos-x64`

### 📌 使用说明
1. 从官方下载对应架构的新版本核心。
2. 将下载的文件直接移动或复制到本 `bin/` 目录下。
3. 运行根目录下的 **`一键打包App.command`**（或命令行 `python3 scripts/package_app.py --arch all`），打包工具会自动扫描并识别此目录下的文件，一键完成对应架构或双架构打包！
