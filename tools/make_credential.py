#!/usr/bin/env python3
"""生成填入 index.html 顶部 SYNC_CREDENTIAL 的同步凭证。

用法（访问令牌不进 shell 历史，先 read 再执行）：
    read -s GHPAT && read -s PWD && python3 tools/make_credential.py --purpose token
    # 按提示粘贴访问令牌与同步密码（通过环境变量传入），输出 base64 凭证串

也可直接传参（会进 shell 历史，仅可信本机用）：
    python3 tools/make_credential.py --purpose token --password '你的密码' --secret 'ghp_xxx'
"""
import argparse
import base64
import getpass
import os
import sys

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

PBKDF2_ITER = 310000  # 必须与 index.html / forward.yml 一致


def scope_usage(password: str, purpose: str) -> bytes:
    return (password + "\x00" + "note-relay/" + purpose).encode()


def pack_envelope(plain: str, password: str, purpose: str) -> str:
    salt, iv = os.urandom(16), os.urandom(12)
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=PBKDF2_ITER)
    key = kdf.derive(scope_usage(password, purpose))
    ct = AESGCM(key).encrypt(iv, plain.encode(), None)
    return base64.b64encode(bytes([0x01]) + PBKDF2_ITER.to_bytes(4, "big") + salt + iv + ct).decode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--purpose", default="token", choices=["token", "payload"])
    ap.add_argument("--password", default=os.environ.get("PWD") or os.environ.get("PASSWORD"))
    ap.add_argument("--secret", default=os.environ.get("GHPAT"))
    args = ap.parse_args()
    password = args.password or getpass.getpass("同步密码: ")
    secret = args.secret or getpass.getpass("访问令牌/内容: ")
    if not password or not secret:
        print("密码和内容不能为空", file=sys.stderr)
        return 1
    print(pack_envelope(secret, password, args.purpose))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
