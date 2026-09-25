# note-relay v2

浏览器端到端加密 → GitHub Actions 中转 → WebDAV 落盘。无自建服务器，单文件前端 + 一个 workflow。

## 架构

```
[index.html @ GitHub Pages]
  口令 --PBKDF2--> key[token] 解出 PAT（内存 only）
  口令 --PBKDF2--> key[payload] 加密 {v,title,folder,content,overwrite,timestamp,nonce}
        -- workflow_dispatch(payload=密文) -->
[forward.yml @ Actions] 解密 → 校验时间戳/文件名 → curl PUT WebDAV
```

## 加密格式（只有 v2，不兼容老格式）

信封：`0x01 ‖ iterations u32BE ‖ salt16 ‖ iv12 ‖ AES-GCM-256(ct+tag)`，整体 base64。
PBKDF2-HMAC-SHA256 **310000 次**（`PBKDF2_ITER`，三处必须一致：`index.html` / `forward.yml` / `tools/make_blob.py`），
口令按用途隔离：`password + \x00 + note-relay/<token|payload>`。
迭代次数对不上或非 `0x01` 开头，前后端一律拒绝并提示重新生成。

## 部署

1. **Token 密文串**：已固定写死在 `index.html` 顶部 `ENCRYPTED_TOKEN_BLOB`，页面无任何修改入口。
   轮换 PAT / 口令时用 `tools/make_blob.py` 重新生成并改源码：
   ```bash
   read -s GHPAT && read -s PWD && python3 tools/make_blob.py --purpose token
   ```
   PAT 用 fine-grained token，仓库只选本仓，权限 `Actions: Read and write`，有效期尽量短。
2. **Secrets**（仓库 Settings → Secrets and variables → Actions）：
   `DECRYPT_PASSWORD`（与发送口令一致）、`WEBDAV_URL`（以 `/` 结尾，如 `https://dav.example.com/notes/`）、
   `WEBDAV_USER`、`WEBDAV_PASSWORD`。
3. **Pages**：从 `main` 分支发布根目录 `index.html`。
4. **分支**：dispatch 默认 `ref: main`；仓库、分支、文件名全固定在源码顶部，改部署只改那一处。

## 防滥用限流（两层）

* **Actions 端守卫（真限流，绕不过）**：每次运行先用 `GITHUB_TOKEN` 查本 workflow 近 5 分钟触发次数，
  超过 3 次直接失败退出，不解密不上传。窗口/上限在 `forward.yml` 的 `RATE_WINDOW_SEC` / `RATE_MAX_RUNS` 调。
  攻击者即使拿到 PAT 狂调 API，也只会产生一堆"已限流"的失败运行，网盘不会被刷。
* **前端 60 秒冷却（体验层）**：每次发送后按钮倒计时，可被改 JS 绕过，不管真攻击，只防误触连点。

另建议：dispatch 专用 PAT 只给 `Actions: Read and write` 单权限，即使泄露，破坏半径也仅限于触发运行。

## 前端功能（index.html，零构建单文件）

* 口令强度条、显示/隐藏、`Ctrl/⌘+Enter` 发送，成功才清空正文+口令
* 编辑/预览双 tab（自带轻量 Markdown 渲染，先转义防 XSS）、字数/行数/阅读时长
* 草稿自动保存（localStorage **明文**，仅本机）、一键插入模板/清空草稿
* 文件夹 + 标题 + 覆盖开关 + 空标题按日期自动命名；密文过大（~28KB）预警
* dispatch 后轮询 Actions 运行状态，给结论 + 运行记录链接
* 明暗主题

## 后端行为（forward.yml）

* 只接受 `payload` 一个明文输入；`folder/title` 都在密文内，避免元数据明文泄露
* 时间戳新鲜度校验（默认 15 分钟，`MAX_AGE_SEC` 可调，未来时钟允 300s）→ 防重放
* 文件名/目录逐段清洗：去控制字符，最多 5 级、每级 ≤64 字符，标题 ≤100 字符并强制 `.md` 后缀，
  上传 URL 按段 percent-encode；缺父目录自动 MKCOL
* `overwrite=false` 时先 HEAD 检查，已存在则跳过（日志与 Summary 说明）
* 日志只打印相对路径与字节数，不打印完整 URL/凭据；结果写入 Step Summary；失败自动重试 3 次
* `permissions: {}` 最小权限，`timeout-minutes: 10`

## 安全模型与局限（必读）

* Token 密文公开在页面中，安全性 = 口令强度。务必 ≥14 位混合字符，定期轮换 PAT+口令。
* Actions 运行历史会留下密文与触发时间（频率元数据），仓库建议设为私有。
* 草稿在浏览器明文存放，仅在可信设备开启；公共电脑用后点「清草稿」。
* 大正文（>1MB 明文 / dispatch 输入超限）会被拒绝，请拆分发送。

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` | 前端全部逻辑（配置全在顶部常量，无其他入口） |
| `.github/workflows/forward.yml` | 解密 + 校验 + WebDAV 上传 |
| `tools/make_blob.py` | 离线生成 `ENCRYPTED_TOKEN_BLOB` |
