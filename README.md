# note-relay

在线写笔记，一键保存到本仓库。无自建服务器：单文件前端直调 GitHub API 写文件。

## 同步流程

```
[index.html @ GitHub Pages]
  同步密码在本地解出同步凭证
        -- GET contents/{path} 查是否存在（拿 sha）-->
        -- PUT contents/{path} 创建或更新 .md 文件 -->
[本仓库 @ main 分支] 直接多出 / 更新一篇笔记
```

提交信息统一为 `同步笔记：<路径>`。`overwrite` 未勾选且文件已存在时拒绝写入。

## 数据格式

同步凭证：`0x01 ‖ iterations u32BE ‖ salt16 ‖ iv12 ‖ ct`，整体 base64。
安全参数 `PBKDF2_ITER`（31 万次）两处必须一致：`index.html` / `tools/make_credential.py`；
同步密码按用途混合后派生，版本号对不上或非 `0x01` 开头一律拒绝。

## 部署

1. **同步凭证**：已固定写死在 `index.html` 顶部 `SYNC_CREDENTIAL`，页面无任何修改入口。
   轮换访问令牌 / 同步密码时用 `tools/make_credential.py` 重新生成并改源码：
   ```bash
   read -s GHPAT && read -s PWD && python3 tools/make_credential.py --purpose token
   ```
   访问令牌用 fine-grained token，仓库只选本仓，权限 `Contents: Read and write`
  （读用于查文件 sha，写用于创建/更新），有效期尽量短。
2. **Pages**：从 `main` 分支发布根目录 `index.html`。
3. **分支与路径**：目标分支、仓库名全固定在源码顶部（`GH_BRANCH` / `GH_OWNER` / `GH_REPO`）。
   笔记路径 = 子目录输入 + 标题（自动清洗非法字符、强制 `.md` 后缀，
   中文按段编码，最多 6 级）。

不再需要 Actions workflow，也不需配任何 Secrets。旧的 `DECRYPT_PASSWORD` 等可直接删掉。

## 限流

* **前端 60 秒冷却**：每次保存后按钮倒计时，只防误触连点。
* **GitHub API 自带限流**（认证后 5000 次/小时），正常使用碰不到。

## 前端功能（index.html，零构建单文件）

* 密码显示/隐藏、`Ctrl/⌘+Enter` 保存，成功才清空正文+密码
* 编辑/预览双 tab（自带轻量 Markdown 渲染，先转义防 XSS）、字数/行数/阅读时长
* 草稿自动保存（localStorage，仅本机）、一键插入模板/清空草稿
* 子目录 + 标题 + 覆盖开关 + 空标题按日期自动命名
* 明暗主题

## 使用说明（必读）

* 同步凭证公开在页面中，安全性 = 同步密码强度。务必 ≥14 位混合字符，定期轮换访问令牌+同步密码。
* 笔记以明文 `.md` 直接提交到仓库，仓库建议设为私有。
* 草稿在浏览器本机存放，仅在可信设备开启；公共电脑用后点「清草稿」。
* 大正文（>1MB）会被拒绝，请拆分保存。

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` | 前端全部逻辑（配置全在顶部常量，无其他入口） |
| `tools/make_credential.py` | 离线生成 `SYNC_CREDENTIAL` |
