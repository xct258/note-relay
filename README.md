# note-relay

在线写笔记，一键同步到网盘。无自建服务器：单文件前端 + 一个 workflow。

## 同步流程

```
[index.html @ GitHub Pages]
  同步密码在本地处理数据，打包成 {v,title,folder,content,overwrite,timestamp,nonce}
        -- workflow_dispatch(payload=数据包) -->
[forward.yml @ Actions] 解析 → 校验时间戳/文件名 → curl PUT WebDAV
```

## 数据格式

数据包：`0x01 ‖ iterations u32BE ‖ salt16 ‖ iv12 ‖ ct`，整体 base64。
安全参数 `PBKDF2_ITER`（31 万次）三处必须一致：`index.html` / `forward.yml` / `tools/make_credential.py`；
同步密码按用途混合后派生，版本号对不上或非 `0x01` 开头，前后端一律拒绝。
`folder/title` 都在数据包内，不单独在外传输。

## 部署

1. **同步凭证**：已固定写死在 `index.html` 顶部 `SYNC_CREDENTIAL`，页面无任何修改入口。
   轮换访问令牌 / 同步密码时用 `tools/make_credential.py` 重新生成并改源码：
   ```bash
   read -s GHPAT && read -s PWD && python3 tools/make_credential.py --purpose token
   ```
   访问令牌用 fine-grained token，仓库只选本仓，权限 `Actions: Read and write`，有效期尽量短。
2. **Secrets**（仓库 Settings → Secrets and variables → Actions）：
   `DECRYPT_PASSWORD`（与同步密码一致）、`WEBDAV_URL`（以 `/` 结尾，如 `https://dav.example.com/notes/`）、
   `WEBDAV_USER`、`WEBDAV_PASSWORD`。
3. **Pages**：从 `main` 分支发布根目录 `index.html`。
4. **分支**：触发默认 `ref: main`；仓库、分支、文件名全固定在源码顶部，改部署只改那一处。

## 防滥用限流（两层）

* **服务端守卫（真限流，绕不过）**：每次运行先用 `GITHUB_TOKEN` 查本 workflow 近 5 分钟触发次数，
  超过 3 次直接失败退出，不解析不上传。窗口/上限在 `forward.yml` 的 `RATE_WINDOW_SEC` / `RATE_MAX_RUNS` 调。
* **前端 60 秒冷却（体验层）**：每次保存后按钮倒计时，只防误触连点。

另建议：同步专用访问令牌只给 `Actions: Read and write` 单权限，即使泄露，影响也仅限于触发运行。

## 前端功能（index.html，零构建单文件）

* 密码强度条、显示/隐藏、`Ctrl/⌘+Enter` 保存，成功才清空正文+密码
* 编辑/预览双 tab（自带轻量 Markdown 渲染，先转义防 XSS）、字数/行数/阅读时长
* 草稿自动保存（localStorage，仅本机）、一键插入模板/清空草稿
* 文件夹 + 标题 + 覆盖开关 + 空标题按日期自动命名；数据包过大（~28KB）预警
* 保存后轮询 Actions 运行状态，给结论 + 运行记录链接
* 明暗主题

## 服务端行为（forward.yml）

* 只接受 `payload` 一个输入；`folder/title` 都在数据包内
* 时间戳有效期校验（默认 15 分钟，`MAX_AGE_SEC` 可调，未来时钟允 300s）
* 文件名/目录逐段清洗：去控制字符，最多 5 级、每级 ≤64 字符，标题 ≤100 字符并强制 `.md` 后缀，
  上传 URL 按段 percent-encode；缺父目录自动创建
* `overwrite=false` 时先 HEAD 检查，已存在则跳过（日志与 Summary 说明）
* 日志只打印相对路径与字节数，不打印完整 URL/凭据；结果写入 Step Summary；失败自动重试 3 次
* `permissions: {}` 最小权限，`timeout-minutes: 10`

## 使用说明（必读）

* 同步凭证公开在页面中，安全性 = 同步密码强度。务必 ≥14 位混合字符，定期轮换访问令牌+同步密码。
* Actions 运行历史会留下数据包与触发时间，仓库建议设为私有。
* 草稿在浏览器本机存放，仅在可信设备开启；公共电脑用后点「清草稿」。
* 大正文（>1MB / 请求长度超限）会被拒绝，请拆分保存。

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` | 前端全部逻辑（配置全在顶部常量，无其他入口） |
| `.github/workflows/forward.yml` | 解析 + 校验 + WebDAV 上传 |
| `tools/make_credential.py` | 离线生成 `SYNC_CREDENTIAL` |
