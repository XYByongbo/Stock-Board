#!/usr/bin/env bash
#
# daily_stock_analysis —— 服务器一键部署脚本（后端 + 前端 + Nginx 子路径 /stock）
# ---------------------------------------------------------------------------
# 前置条件：
#   1. 服务器已装好 docker + docker compose v2 + nginx
#   2. 项目代码已在 PROJECT_DIR（默认 /opt/daily_stock_analysis）
#   3. PROJECT_DIR/.env 已存在并填好密钥（LLM_ANTHROPIC_API_KEY 等），
#      且含 WEBUI_ENABLED=true
# 用法：
#   bash server-deploy.sh                         # 常规部署（幂等，可重复跑）
#   FORCE_FRONTEND=1 bash server-deploy.sh        # 强制重建前端
#   PROJECT_DIR=/path/to/repo bash server-deploy.sh
#
# 说明：
#   - 前端不需要在宿主机装 node：脚本临时把 VITE_BASE_PATH=/stock 烘焙进
#     Dockerfile 的构建步骤（幂等，仅改一次），构建完成后从镜像抽取 /app/static
#     到 /var/www/dsa 供 nginx 直接托管。
#   - 内存 >= 4G 时自动跳过 swap；< 4G 自动建 2G swap 作为保险。
#   - 构建用 BuildKit 缓存挂载，中断后可续传。
# ---------------------------------------------------------------------------

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/daily_stock_analysis}"
cd "$PROJECT_DIR"

echo "==================================================="
echo " daily_stock_analysis 部署脚本"
echo " 项目目录 : $PROJECT_DIR"
echo " 时间     : $(date '+%F %T')"
echo "==================================================="

# ---------- 0. 前置检查 ----------
command -v docker >/dev/null 2>&1 || { echo "[ERR] 未找到 docker，请先安装"; exit 1; }
if ! docker compose version >/dev/null 2>&1; then
  echo "[ERR] 未找到 docker compose v2"; exit 1
fi
[ -f requirements.txt ] || { echo "[ERR] 请在项目根目录运行（未找到 requirements.txt）"; exit 1; }

# ---------- 1. 修正 longbridge 版本约束（公网 PyPI 0.2.x 最高 0.2.75） ----------
if grep -q "longbridge>=0.2.77" requirements.txt; then
  sed -i 's/longbridge>=0.2.77/longbridge>=0.2.75/' requirements.txt
  echo "[fix] 已将 requirements.txt 中 longbridge 约束改为 >=0.2.75"
fi

# ---------- 2. .env 检查（compose 通过 ../.env 注入） ----------
if [ ! -f .env ]; then
  echo "[ERR] 未发现 .env，后端缺少 API Key 将无法工作。"
  [ -f .env.example ] && echo "请先: cp .env.example .env  然后编辑填入 LLM_ANTHROPIC_API_KEY 等密钥"
  echo "并在 .env 中加入 WEBUI_ENABLED=true，然后重跑本脚本。"
  exit 1
fi
grep -q "WEBUI_ENABLED" .env || echo "WEBUI_ENABLED=true" >> .env

# ---------- 3. 小内存保险：RAM<4G 时建 2G swap（40G 内存可跳过） ----------
MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "${MEM_GB:-0}" -lt 4 ]; then
  if ! swapon --show 2>/dev/null | grep -q swapfile; then
    echo "[swap] 内存 ${MEM_GB}G < 4G，创建 2G swap 作为保险..."
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
else
  echo "[swap] 内存 ${MEM_GB}G >= 4G，跳过 swap（40G 内存完全够用）"
fi

# ---------- 4. 是否需要重建前端 ----------
NEED_FRONTEND=0
[ "${FORCE_FRONTEND:-0}" = "1" ] && NEED_FRONTEND=1
[ -f /var/www/dsa/index.html ] || NEED_FRONTEND=1

if [ "$NEED_FRONTEND" = "1" ]; then
  echo "[frontend] 将在镜像内构建前端（VITE_BASE_PATH=/stock）..."
  # 幂等：仅当尚未烘焙子路径时修改 Dockerfile 的 npm build 步骤
  if ! grep -q "VITE_BASE_PATH=/stock" docker/Dockerfile; then
    sed -i 's#^RUN npm run build#RUN VITE_BASE_PATH=/stock npm run build#' docker/Dockerfile
    echo "[frontend] 已就地修改 docker/Dockerfile 以烘焙 /stock 子路径"
  fi
fi

# ---------- 5. 构建镜像（BuildKit 缓存挂载，中断可续传） ----------
echo "[build] 开始构建 stock-server 镜像（视网络/机器，可能数分钟）..."
export DOCKER_BUILDKIT=1
docker compose -f docker/docker-compose.yml build server

# ---------- 6. 抽取前端静态文件到 nginx 目录 ----------
if [ "$NEED_FRONTEND" = "1" ]; then
  echo "[frontend] 从镜像抽取静态文件到 /var/www/dsa ..."
  mkdir -p /var/www/dsa
  IMG=$(docker compose -f docker/docker-compose.yml images -q server 2>/dev/null | head -1)
  [ -z "$IMG" ] && IMG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i 'daily' | head -1)
  [ -z "$IMG" ] && { echo "[ERR] 找不到构建出的镜像"; exit 1; }
  CID=$(docker create --name dsa-extract "$IMG")
  docker cp "$CID":/app/static/. /var/www/dsa/
  docker rm -f dsa-extract >/dev/null 2>&1 || true
  echo "[frontend] 已部署到 /var/www/dsa ($(ls /var/www/dsa | wc -l) 个文件)"
fi

# ---------- 7. Nginx 子路径片段 ----------
echo "[nginx] 写入 /etc/nginx/dsa-locations.conf ..."
cat > /etc/nginx/dsa-locations.conf <<'NGINX'
    # ===== 前端静态站点：子路径 /stock =====
    location /stock/ {
        alias /var/www/dsa/;
        index index.html;
        try_files $uri $uri/ /stock/index.html;
    }
    location /stock/assets/ {
        alias /var/www/dsa/assets/;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
    }
    location = /stock/index.html {
        alias /var/www/dsa/index.html;
        add_header Cache-Control "no-cache";
    }
    location ^~ /stock/api/ {
        rewrite ^/stock/(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
NGINX

# 幂等注入 include 到 yongbo.online 的 443 server 块（ai-board.conf）
CONF=/etc/nginx/conf.d/ai-board.conf
if [ -f "$CONF" ]; then
  if ! grep -q "dsa-locations.conf" "$CONF"; then
    python3 - <<'PY'
p="/etc/nginx/conf.d/ai-board.conf"
s=open(p,encoding="utf-8").read()
ins="    include /etc/nginx/dsa-locations.conf;\n"
idx=s.find("server {")
if idx != -1:
    nl=s.find("\n", idx)
    s=s[:nl+1]+ins+s[nl+1:]
    open(p,"w",encoding="utf-8").write(s)
    print("已注入 include 到", p)
else:
    print("未找到 server { ，请手动在 443 server 块内加入: include /etc/nginx/dsa-locations.conf;")
PY
  else
    echo "[nginx] include 已存在，跳过"
  fi
else
  echo "[nginx] 未找到 $CONF，请在你域名的 443 server 块内手动加入："
  echo "        include /etc/nginx/dsa-locations.conf;"
fi

nginx -t && systemctl reload nginx && echo "[nginx] 已重载配置"

# ---------- 8. 启动后端容器 ----------
echo "[backend] 启动 stock-server ..."
docker compose -f docker/docker-compose.yml up -d server
sleep 3
docker ps --format "{{.Names}}\t{{.Status}}" | grep -i stock-server || true

# ---------- 9. 健康检查 ----------
echo "[health] 等待后端就绪（最多 ~150s）..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
    echo "本地健康检查通过: http://127.0.0.1:8000/api/health"
    break
  fi
  sleep 5
done

echo "==================================================="
echo " 部署完成"
echo " 对内: http://127.0.0.1:8000/api/health"
echo " 对外: https://yongbo.online/stock/api/health"
echo "==================================================="
curl -sS -o /dev/null -w "对外 HTTPS 状态=%{http_code}\n" https://yongbo.online/stock/api/health || true
