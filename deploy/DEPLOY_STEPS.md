# 股票分析系统 Web 工作台 — 部署教程

> 目标：把本项目部署到与 ai-board **同一台服务器** `69.5.21.175`，通过
> **同一个域名** `http://yongbo.online/stock/` 访问。
>
> 思路（对齐 ai-board 的极简风格）：
> - **前端**：本地 `npm run build` 后，用 `rsync` 把 `static/`（vite 输出目录）上传到服务器 `/var/www/dsa`，由原生 Nginx 托管（子路径 `/stock`）。
> - **后端**：用项目自带的 Docker（`docker compose up -d server`）在服务器跑 FastAPI，只绑本机 `127.0.0.1:8000`，由 Nginx 反向代理 `/stock/api/` 对外。
>
> 本文每步标了执行位置：
> - 【本地终端】= 你自己的 Mac 上执行
> - 【服务器】= 先 `ssh` 登录服务器后再执行

---

## 准备清单（开始前确认）

- [ ] 服务器公网 IP = `69.5.21.175`，系统是 Linux（Ubuntu 建议）
- [ ] 域名 `yongbo.online` 已解析到该 IP（ai-board 已配好，**无需再改 DNS**；`/stock` 只是路径，不是新域名）
- [ ] 本地已能 `ssh root@69.5.21.175` 免密登录（若未配，见步骤 2）
- [ ] 以下文件已就位（本仓库已提供，一般无需改）：
  - `deploy/deploy.sh` → 已填 `SERVER="root@69.5.21.175"`、`REMOTE_DIR="/var/www/dsa"`、`BASE_PATH="/stock"`
  - `deploy/nginx.conf` → 是 `/stock` 的 **location 片段（不含 server 块）**，由 deploy.sh 注入 ai-board 的 443 主 server 块（含后端 API 反代）
- [ ] 服务器已装 Nginx（未装见步骤 1）；后端走 Docker，需服务器能跑 Docker（步骤 5 顺便装）

---

## 步骤 0（建议）：先确认能连上服务器

【本地终端】

```bash
ssh root@69.5.21.175
```

能进到命令行就说明网络和账号 OK，输入 `exit` 退出。

---

## 步骤 1：服务器安装 Nginx（如未装）

【服务器】

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y nginx
nginx -v   # 看到 nginx version 即成功
```

---

## 步骤 2：配置 SSH 免密（只需做一次）

【本地终端】

```bash
ssh-keygen -t ed25519                       # 一路回车
ssh-copy-id root@69.5.21.175               # 输一次服务器密码
ssh root@69.5.21.175                       # 不需密码直接进 = 成功
```

免密后，`deploy.sh` 自动上传不会反复要密码。

---

## 步骤 3：上传 Nginx 配置并生效

> 重要：服务器上 `ai-board.conf` 已经用 `server_name yongbo.online` 占用了 443 主 server 块
> （并强制 HTTP→HTTPS）。如果再用独立 `server { server_name yongbo.online }` 块，nginx 只会认第一个，
> 导致 `/stock` 被忽略。
>
> 因此本项目的 `deploy/nginx.conf` **只含 `/stock` 的 location 片段（不含 server 块）**，
> 由 `deploy/deploy.sh` 自动把它 `include` 进 ai-board 的 443 主 server 块。手动操作如下：

【本地终端】

```bash
# 1) 把 /stock 片段传到服务器（独立文件，不含 server 块）
scp deploy/nginx.conf root@69.5.21.175:/etc/nginx/dsa-locations.conf

# 2) 幂等注入 include 到 ai-board.conf 的第一个（443）server 块
ssh root@69.5.21.175 'python3 - <<PY
p = "/etc/nginx/conf.d/ai-board.conf"
need = "include /etc/nginx/dsa-locations.conf;"
s = open(p).read()
if need not in s:
    idx = s.index("server {")
    si = s.index("server_name", idx)
    ei = s.index("\n", si)
    s = s[:ei+1] + "    " + need + "\n" + s[ei+1:]
    open(p, "w").write(s)
PY'

# 3) 测试配置语法并重载 nginx
ssh root@69.5.21.175 "nginx -t && systemctl reload nginx"
```

看到 `test is successful` 和 `Reloading nginx` 即成功。

> 说明：`/board` 与 `/stock` 现在共处同一个 443 server 块，按路径分别匹配，互不冲突。
> 重复执行步骤 2 不会重复注入（已做幂等判断）。

---

## 步骤 4：把后端项目传到服务器并跑起来（关键）

前端是静态页面，真正的数据来自后端 API，所以**后端必须先在服务器运行**。

### 4.1 把代码传到服务器（首次）

【本地终端】把整个项目（排除本地大目录）同步到服务器 `/opt/daily_stock_analysis`：

```bash
rsync -avz --delete \
  --exclude node_modules --exclude .git --exclude '*/dist' \
  --exclude __pycache__ --exclude .venv --exclude .workbuddy \
  --exclude data --exclude logs --exclude reports \
  /Users/xyb/Documents/workspace/daily_stock_analysis/ \
  root@69.5.21.175:/opt/daily_stock_analysis/
```

以后只改了后端代码，重跑这条即可更新服务器后端。

### 4.2 服务器安装 Docker（如未装）

【服务器】

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker -v   # 看到版本即成功
```

### 4.3 配置后端环境变量（按需填写）

【服务器】

```bash
cd /opt/daily_stock_analysis
cp .env.example .env
vim .env        # 填写 API Key、数据源配置、STOCK_LIST 等（敏感信息，不要明文发到群里）
```

### 4.4 启动后端（只跑 API，绑本机 8000，由 Nginx 反代）

【服务器】

```bash
cd /opt/daily_stock_analysis
API_PORT=8000 docker compose -f docker/docker-compose.yml up -d server

# 验证后端活着（返回健康信息即 OK）
curl -fsS http://127.0.0.1:8000/api/health
```

> 端口已绑定 `127.0.0.1`，公网无法直接访问 `8000`，只能经 Nginx 的 `/stock/api/` 访问，更安全。
> 查看日志：`docker compose -f docker/docker-compose.yml logs -f server`

---

## 步骤 5：一键部署前端（核心！以后每次发版只跑这一条）

【本地终端】进入项目根目录执行：

```bash
cd /Users/xyb/Documents/workspace/daily_stock_analysis
bash deploy/deploy.sh
```

脚本自动做三件事：
1. `VITE_BASE_PATH=/stock npm run build` → 本地生成 `static/`（项目根目录，vite `outDir` 配置），资源路径为 `/stock/assets/...`
2. SSH 连服务器，确保目录 `/var/www/dsa` 存在
3. `rsync` 把 `static/` 增量同步到 `/var/www/dsa`

看到结尾 `完成！刷新 ... 即可看到最新版本。` 即部署好。

---

## 步骤 6：访问验证

打开浏览器（服务器强制 HTTPS，HTTP 会自动跳转）：

```
https://yongbo.online/stock/
```

> ⚠️ 一定要带末尾斜杠 `/stock/`，否则样式可能加载不出来。
> 登录后能正常拉取数据、跑分析 = 部署成功 🎉

---

## 步骤 7（可选）：上 HTTPS 加密

【服务器】

```bash
ssh root@69.5.21.175
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yongbo.online
```

完成后访问 `https://yongbo.online/stock/`（证书 90 天自动续期）。

> 注：`69.5.x.x` 是境外 IP，域名无需备案，HTTP/HTTPS 都能直接用。

---

## 常见问题排错

**① 打开 `/stock/` 显示 404 / 样式错乱**
- 确认 Nginx 配置已上传并重载（步骤 3），且访问地址带 `/stock/`（含末尾斜杠）。
- 登录服务器看目录是否有文件：`ssh root@69.5.21.175 "ls /var/www/dsa"`。
- 资源路径不对：确认 `deploy.sh` 里 `VITE_BASE_PATH="/stock"` 已生效，重跑 `bash deploy/deploy.sh`。

**② 页面能打开，但登录后拉不到数据 / 接口 502**
- 后端没起来。在服务器执行 `curl -fsS http://127.0.0.1:8000/api/health` 验证。
- 没起就重跑步骤 4.4；查看日志 `docker compose -f docker/docker-compose.yml logs -f server`。
- 确认 Nginx 反代配置里 `proxy_pass http://127.0.0.1:8000;` 与后端端口一致。

**③ SSH 连接被拒绝 / 超时**
- 检查服务器安全组是否放行 **22**（SSH）、**80**（HTTP）、**443**（HTTPS）。
- 确认 nginx 在运行：`ssh root@69.5.21.175 "systemctl status nginx"`。

**④ 部署时提示 `rsync: command not found`（服务器上）**
- 服务器装一下：`ssh root@69.5.21.175 "sudo apt install -y rsync"`（脚本会自动退回到 scp）。

**⑤ 部署脚本卡住要输密码**
- 没配免密，回去重做步骤 2（`ssh-copy-id`）。

---

## 以后每次更新代码的流程

1. 在本地改好代码（前端在 `apps/dsa-web/`，后端在仓库根 / `src/` 等）。
2. 【本地终端】`cd /Users/xyb/Documents/workspace/daily_stock_analysis && bash deploy/deploy.sh`
   - 只改了前端：这一条就够。
   - 改了后端：先在服务器 `rsync` 更新代码（步骤 4.1），再 `docker compose ... up -d server` 重启后端。
3. 刷新 `http://yongbo.online/stock/` 即可看到新版。
