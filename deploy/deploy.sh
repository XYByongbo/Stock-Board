#!/usr/bin/env bash
# 本地一键部署：构建前端 + 把静态产物上传到服务器（子路径 /stock）
# 用法：在项目根目录执行  bash deploy/deploy.sh
# 参考：ai-board/deploy/deploy.sh（同一台服务器、一样的体验）
set -euo pipefail

# ===== 改成你的（与 ai-board 同一台服务器）=====
SERVER="root@69.5.21.175"        # 服务器登录：用户@公网IP（与 ai-board 相同）
REMOTE_DIR="/var/www/dsa"        # 服务器上的站点目录（与 nginx 片段里的 alias 一致）
BASE_PATH="/stock"               # 前端挂载的子路径前缀
# =============================================

cd "$(dirname "$0")/.."

echo "==> 1/4 构建前端静态产物（输出到 static/，子路径 ${BASE_PATH}）..."
cd apps/dsa-web
VITE_BASE_PATH="$BASE_PATH" npm run build
cd ../..

echo "==> 2/4 确保服务器目录存在 ..."
ssh "$SERVER" "mkdir -p '$REMOTE_DIR'"

echo "==> 3/4 上传 static/ 到 $SERVER:$REMOTE_DIR ..."
if command -v rsync >/dev/null 2>&1; then
  # 增量同步并删除服务器上多余的旧文件，保持目录干净
  rsync -avz --delete static/ "$SERVER:$REMOTE_DIR/"
else
  ssh "$SERVER" "rm -rf '$REMOTE_DIR'/*"
  scp -r static/* "$SERVER:$REMOTE_DIR/"
fi

echo "==> 4/4 注入 Nginx /stock 配置并重载 ..."
# 把 /stock 的 location 片段上传为独立文件（不含 server 块，避免与 ai-board 的
# server_name yongbo.online 冲突——同域名同端口 nginx 只认第一个 server 块）。
scp deploy/nginx.conf "$SERVER:/etc/nginx/dsa-locations.conf"

# 幂等地把 include 行插入 ai-board.conf 的第一个 server 块（即 443/HTTPS 主块）。
# 不改动 /board 的任何配置；重复执行也不会重复插入。
ssh "$SERVER" 'python3 - <<PY
p = "/etc/nginx/conf.d/ai-board.conf"
need = "include /etc/nginx/dsa-locations.conf;"
s = open(p).read()
if need in s:
    print("include 已存在，跳过注入")
else:
    idx = s.index("server {")
    si = s.index("server_name", idx)
    ei = s.index("\n", si)
    s = s[:ei+1] + "    " + need + "\n" + s[ei+1:]
    open(p, "w").write(s)
    print("已注入 include 到主 server 块")
PY'

ssh "$SERVER" "nginx -t && systemctl reload nginx"

echo "==> 完成！刷新 https://yongbo.online${BASE_PATH}/ 即可看到最新版本。"
echo "    （后端 API 需已在服务器 127.0.0.1:8000 运行；首次部署见 deploy/DEPLOY_STEPS.md）"
