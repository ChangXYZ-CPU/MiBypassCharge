#!/usr/bin/env bash
# 打包模块：读 module/module.prop 的 version，生成 bypass-guard-v<版本>.zip
set -e
cd "$(dirname "$0")"

VER=$(awk -F= '/^version=/{print $2}' module/module.prop | tr -d '\r')
[ -n "$VER" ] || { echo "读不到版本号"; exit 1; }
OUT="bypass-guard-${VER}.zip"
[ -f "$OUT" ] && rm -f "$OUT"

python - "$OUT" <<'PY'
import os, sys, zipfile, hashlib
out = sys.argv[1]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'module')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for dp, dn, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            z.write(p, os.path.relpath(p, root).replace('\\', '/'))
with zipfile.ZipFile(out) as z:
    bad = [n for n in z.namelist() if n.endswith(('.sh', '.prop', '.html', '.css')) and b'\r\n' in z.read(n)]
    print('文件数:', len(z.namelist()))
    if bad:
        print('!! 含 CRLF，mksh 会报错:', bad); sys.exit(1)
d = open(out, 'rb').read()
print('输出:', out, len(d), 'bytes')
print('MD5 :', hashlib.md5(d).hexdigest())
PY
