# Codex 用量菜单栏

一个原生 macOS 菜单栏工具，显示 Codex 剩余用量、重置倒计时，以及当前正在执行或等待用户操作的任务。

![应用图标](Resources/AppIcon-1024.png)

详细介绍和完整操作步骤见：[产品功能与使用说明](docs/product-and-usage.md)。

## 功能

- 实时显示用量百分比和重置倒计时。
- `▶` 表示任务正在正常执行。
- `⏸` 表示任务正在等待批准、选择、手动输入或回复。
- 使用本机 Codex 登录状态，不要求用户向本项目提供账号令牌。
- 不含广告、遥测或第三方依赖。

## 系统要求

- macOS 14 或更高版本。
- 已安装并登录 Codex 桌面版、ChatGPT 桌面版内置 Codex，或 Codex CLI。
- GitHub Release 分别提供 Apple Silicon（`arm64`）和 Intel（`x86_64`）版本。

## 安装

1. 从 GitHub Releases 下载与处理器匹配的 ZIP。
2. 对照 Release 中的 `.sha256` 文件校验下载内容。
3. 解压后将 `Codex用量.app` 拖入“应用程序”。
4. 因项目目前没有 Apple Developer 证书，应用采用 ad-hoc 签名且未经过 Apple 公证。首次启动可能被 Gatekeeper 阻止，可在 Finder 中右键应用并选择“打开”。

不要从不明转载站点下载安装包。公开发布包应由本仓库的 GitHub Actions 从对应标签自动构建。

## 隐私

应用会通过本机 Codex 进程查询用量和任务列表，并在本机读取 Codex 会话日志末尾最多 512KB，以判断任务处于执行、等待或完成状态。读取内容可能包含任务标题和当前轮回复，但只在内存中处理，不保存、不上传，也不包含遥测。

完整说明见 [PRIVACY.md](PRIVACY.md)。

## 安全边界

- 应用没有 App Sandbox，因为它需要启动本机 Codex 子进程并读取 Codex 会话日志。
- 发布构建启用 Hardened Runtime，但无 Apple Developer 证书时仍不会获得 Gatekeeper 信任。
- Codex 本身可能按其正常工作方式连接 OpenAI 服务；本应用没有自行实现网络上传。
- 安全问题的报告方式见 [SECURITY.md](SECURITY.md)。

## 登录时自动启动

打开“系统设置 → 通用 → 登录项”，点击“+”并选择 `Codex用量.app`。

## 从源码构建

需要 Xcode Command Line Tools：

```sh
./build-app.sh
```

构建脚本会：

1. 创建 Release 二进制；
2. 移除调试符号和编译机绝对路径；
3. 加入应用图标；
4. 启用 Hardened Runtime 并进行 ad-hoc 签名；
5. 验证包内签名。

如 Codex 安装在非标准位置，可在启动环境中设置 `CODEX_CLI_PATH`。

## 发布审计

```sh
ditto -c -k --sequesterRsrc --keepParent dist/Codex用量.app Codex用量.zip
./scripts/audit-release.sh Codex用量.zip
```

审计脚本会检查 ZIP 完整性、签名、绝对用户路径、常见凭据格式、动态依赖和包内文件范围，并输出 SHA-256。

## 许可证

源代码以 [MIT License](LICENSE) 发布。项目与 OpenAI 无隶属或官方认可关系，图标不使用 OpenAI 或 Codex 官方商标。
