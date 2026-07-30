# 安全策略

## 支持范围

仅维护最新 GitHub Release。旧版本发现问题后应升级，不再单独提供安全修复。

## 报告漏洞

不要在公开 Issue 中披露可利用细节、凭据或个人会话内容。使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告功能。

报告中可包含：

- 受影响版本与 macOS 版本；
- 最小复现步骤；
- 实际影响和预期行为；
- 已脱敏的日志片段。

不要提交账号令牌、API Key、密码、完整会话日志或其他人的个人信息。

## 发布边界

- 当前项目没有 Apple Developer 证书，Release 使用 Hardened Runtime 和 ad-hoc 签名，但未经过 Apple 公证。
- 公共 Release 应仅由本仓库 GitHub Actions 从版本标签构建。
- 每个安装包同时发布 SHA-256 文件。
- 发布审计会拒绝包含编译机用户路径或常见凭据格式的二进制。
