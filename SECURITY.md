# 安全策略

[English](SECURITY.en.md) | 简体中文

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

## 手机接口安全边界

- 手机接口默认关闭，只接受 `GET /v1/widget`，不提供刷新、控制、任务执行或会话读取能力。
- 首次启用时使用系统安全随机源生成 32 字节令牌，并保存在 macOS Keychain；鉴权令牌只放在 `Authorization: Bearer` 请求头中。
- 请求最大 8 KiB，五秒内未完成即关闭；错误响应不会回显令牌、请求头或内部错误栈。
- JSON 只含个人余量、重置时间、运行任务数量和公开预测汇总，不含任务标题、路径、对话或 Codex 凭据。
- 本机服务使用普通 HTTP，仅适合可信局域网或用户已有的加密 VPN/回家链路。不要把端口 `47821` 映射或暴露到公网。
- 令牌疑似泄露时，应立即在菜单中重新生成；旧令牌随即失效。公开漏洞报告中不得包含真实令牌。

## 外部预测边界

应用只向 `codex-reset.com/api/forecast` 和 `codexreset.org/api/monitor-summary` 发起公开 GET 请求，不发送个人用量、任务、身份、会话内容或 Codex 凭据。主概率只采用前者；后者只能触发独立的 `⚡` 信号。

## 发布边界

- 当前项目没有 Apple Developer 证书，Release 使用 Hardened Runtime 和 ad-hoc 签名，但未经过 Apple 公证。
- 公共 Release 应仅由本仓库 GitHub Actions 从版本标签构建。
- 每个安装包同时发布 SHA-256 文件。
- 发布审计会拒绝包含编译机用户路径或常见凭据格式的二进制。
- 自动化测试使用固定假数据，不访问真实 Keychain 或第三方预测接口。
