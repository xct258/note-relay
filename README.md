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

## 加密格式

* v2 信封：`0x01 ‖ iterations u32BE ‖ salt16 ‖ iv12 ‖ AES-GCM-256(ct+tag)`，整体 base64。
  PBKDF2-HMAC-SHA256 **310000 次**，口令按用途隔离：`password + \x00 + note-relay/<token|payload>`。
* v1 兼容读取：`salt16 ‖ iv12 ‖ ct`，PBKDF2 100k（先试隔离口令，再试裸口令）。**新生成的一律用 v2**；
  建议用页面内「重新生成 Token 密文串」工具把 `ENCRYPTED_TOKEN_BLOB` 换成 v2。

## 部署

1. **PAT**：新建 fine-grained token，仅授目标仓库 `Actions: Read and write`，有效期尽量短。
   用页面工具（或下述脚本）以你的口令加密 PAT，得到密文串，填入 `index.html` 的 `DEFAULTS.blob`。
2. **Secrets**（仓库 Settings → Secrets and variables → Actions）：
   `DECRYPT_PASSWORD`（与发送口令一致）、`WEBDAV_URL`（以 `/` 结尾，如 `https://dav.example.com/notes/`）、
   `WEBDAV_USER`、`WEBDAV_PASSWORD`。
3. **Pages**：从 `main` 分支发布根目录 `index.html`。
4. **分支**：dispatch 默认 `ref: main`，换分支请同步改前端。

离线生成密文串（等价于页内工具，避免把 PAT 贴进浏览器）：

```python
import os, base64
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
pwd, pat, purpose = "你的口令", "ghp_xxx", "token"
salt, iv = os.urandom(16), os.urandom(12)
kdf = PBKDF2HMAC(hashes.SHA256(), 32, salt, 310000)
key = kdf.derive((pwd + "\x00note-relay/" + purpose).encode())
ct = AESGCM(key).encrypt(iv, pat.encode(), None)
blob = bytes([1]) + (310000).to_bytes(4, "big") + salt + iv + ct
print(base64.b64encode(blob).decode())
```

## 前端功能（index.html，零构建单文件）

* 口令强度条、显示/隐藏、`Ctrl/⌘+Enter` 发送，成功才清空正文+口令
* 编辑/预览双 tab（自带轻量 Markdown 渲染，先转义防 XSS）、字数/行数/阅读时长
* 草稿自动保存（localStorage **明文**，仅本机）、一键插入模板/清空草稿
* 文件夹 + 标题 + 覆盖开关 + 空标题按日期自动命名；密文过大（~28KB）预警
* dispatch 后轮询 Actions 运行状态，给出结论与运行记录链接；本机历史（20 条，只存标题/时间/大小）
* 明暗主题、仓库配置页内可改（存 localStorage）、Token 密文 v2 生成器

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
| `index.html` | 前端全部逻辑 |
| `.github/workflows/forward.yml` | 解密 + 校验 + WebDAV 上传 |
