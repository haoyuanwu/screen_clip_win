#!/bin/bash
# Configure a stable signing identity for local Flutter macOS debug builds.
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${1:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | python3 -c '
import re, sys
matches = re.findall(r"\b([0-9A-F]{40}) \"Apple Development:[^\"]+\"", sys.stdin.read())
if len(matches) != 1:
    sys.exit("需要恰好一个 Apple Development 证书；可将 security find-identity -v -p codesigning 列出的证书 SHA-1 作为参数传入。")
print(matches[0])
')"
fi
if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "请传入签名证书的 40 位 SHA-1。" >&2
  exit 1
fi
printf '// Generated locally; do not commit.\nSCREEN_CLIP_DEBUG_SIGNING_IDENTITY = %s\n' "$identity" > macos/Runner/Configs/Signing.local.xcconfig
echo '已配置本机 Debug 签名。请完全退出应用后重新运行 flutter run -d macos。'
echo '如旧授权仍失效，退出应用后执行：tccutil reset ScreenCapture com.example.screenClipWin'
