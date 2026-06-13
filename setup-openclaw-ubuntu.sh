#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw Ubuntu 原生源码部署脚本
# 默认用户：ubuntu
# 不使用 Docker
# 不创建自定义分支
# 适合后续自己修改源码
#
# 部署目录：
#   /home/ubuntu/openclaw
#
# 配置目录：
#   /home/ubuntu/.openclaw
#
# 注意：
#   本脚本默认不执行 pnpm build
#   因为 4G 内存机器容易 JavaScript heap out of memory
#   先使用 pnpm openclaw / wrapper 方式运行
# ============================================================

REPO_URL="${REPO_URL:-https://github.com/openclaw/openclaw.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw}"
SWAP_SIZE="${SWAP_SIZE:-12G}"
NODE_OPTIONS_VALUE="${NODE_OPTIONS_VALUE:---max-old-space-size=12288}"

echo "============================================================"
echo "OpenClaw Ubuntu 源码部署"
echo "============================================================"
echo "当前用户: $(whoami)"
echo "HOME: $HOME"
echo "仓库地址: $REPO_URL"
echo "安装目录: $INSTALL_DIR"
echo "Swap 大小: $SWAP_SIZE"
echo "Node 内存参数: $NODE_OPTIONS_VALUE"
echo "============================================================"

if [ "$(id -u)" -eq 0 ]; then
  echo "错误：不要用 root 直接运行此脚本。"
  echo "请使用 ubuntu 用户运行："
  echo "  su - ubuntu"
  exit 1
fi

if [ "$(whoami)" != "ubuntu" ]; then
  echo "警告：当前用户不是 ubuntu，而是 $(whoami)。"
  echo "如果你确定要用当前用户部署，可以继续。"
  echo "5 秒后继续，按 Ctrl+C 可取消。"
  sleep 5
fi

echo ""
echo "==> 1. 刷新 sudo 权限"
echo "如果这里要求输入密码，第一次需要输入 ubuntu 用户密码。"
sudo -v

echo ""
echo "==> 2. 配置当前用户免密 sudo"
echo "$(whoami) ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$(whoami)" >/dev/null
sudo chmod 440 "/etc/sudoers.d/$(whoami)"
sudo visudo -cf "/etc/sudoers.d/$(whoami)"

echo ""
echo "==> 3. 更新系统并安装基础依赖"
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  curl \
  git \
  ca-certificates \
  gnupg \
  build-essential \
  unzip \
  python3 \
  python3-pip \
  jq \
  nano \
  htop \
  lsof

echo ""
echo "==> 4. 配置 swap，避免源码构建内存不足"

if swapon --show | grep -q "/swapfile"; then
  echo "检测到 /swapfile 已存在，跳过创建。"
else
  echo "创建 $SWAP_SIZE swapfile..."
  sudo fallocate -l "$SWAP_SIZE" /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=12288 status=progress
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
fi

if ! grep -q "^/swapfile " /etc/fstab; then
  echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
fi

free -h

echo ""
echo "==> 5. 安装 Node.js 24"
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

echo "Node 版本:"
node -v

echo "npm 版本:"
npm -v

echo ""
echo "==> 6. 启用 corepack / pnpm"

sudo corepack enable || true
corepack prepare pnpm@latest --activate || sudo corepack prepare pnpm@latest --activate

echo ""
echo "==> 7. 配置 pnpm 路径"

mkdir -p "$HOME/.local/share/pnpm/bin"
mkdir -p "$HOME/.local/bin"

pnpm config set global-bin-dir "$HOME/.local/share/pnpm/bin"

if ! grep -q 'PNPM_HOME="$HOME/.local/share/pnpm/bin"' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# pnpm global bin
export PNPM_HOME="$HOME/.local/share/pnpm/bin"
export PATH="$PNPM_HOME:$HOME/.local/bin:$PATH"
EOF
fi

export PNPM_HOME="$HOME/.local/share/pnpm/bin"
export PATH="$PNPM_HOME:$HOME/.local/bin:$PATH"

echo "pnpm 版本:"
pnpm -v

echo ""
echo "==> 8. 配置 Node 编译内存参数"

if ! grep -q 'NODE_OPTIONS=' "$HOME/.bashrc"; then
  echo "export NODE_OPTIONS=\"$NODE_OPTIONS_VALUE\"" >> "$HOME/.bashrc"
fi

export NODE_OPTIONS="$NODE_OPTIONS_VALUE"

echo "NODE_OPTIONS=$NODE_OPTIONS"

echo ""
echo "==> 9. 下载 OpenClaw 源码"

cd "$HOME"

if [ ! -d "$INSTALL_DIR/.git" ]; then
  git clone "$REPO_URL" "$INSTALL_DIR"
else
  echo "目录 $INSTALL_DIR 已存在，跳过 clone。"
fi

cd "$INSTALL_DIR"

echo ""
echo "==> 10. 保持当前仓库默认分支"

echo "当前分支:"
git branch --show-current

echo "当前 remote:"
git remote -v

echo ""
echo "==> 11. 安装依赖"

pnpm install

echo ""
echo "==> 12. 构建控制台 UI"

pnpm ui:build

echo ""
echo "==> 13. 创建 openclaw 全局 wrapper 命令"

cat > "$HOME/.local/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
cd "$HOME/openclaw" || exit 1
exec pnpm openclaw "$@"
EOF

chmod +x "$HOME/.local/bin/openclaw"

echo ""
echo "==> 14. 验证 openclaw 命令"

hash -r || true

if command -v openclaw >/dev/null 2>&1; then
  which openclaw
  openclaw --version || true
else
  echo "openclaw 命令暂时不在 PATH 中。"
  echo "当前会话执行："
  echo "  source ~/.bashrc"
  echo "然后再试："
  echo "  openclaw --version"
fi

echo ""
echo "==> 15. 显示系统资源"

free -h
df -h "$HOME"

echo ""
echo "============================================================"
echo "OpenClaw 源码环境准备完成"
echo "============================================================"
echo ""
echo "==> 16. 运行 Onboarding（非交互式）"

# 读取 DeepSeek API Key（如果没设，gateway 先起，稍后配置）
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-}"
if [ -z "$DEEPSEEK_KEY" ]; then
  echo "  未设置 DEEPSEEK_API_KEY，跳过模型配置。"
  echo "  之后可运行: openclaw configure --deepseek-api-key <你的key>"
  echo ""
fi

# 生成随机 Token
GW_TOKEN=$(openssl rand -hex 24 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(24))")
echo "  生成的 Gateway Token: $GW_TOKEN"

echo ""
echo "  执行 openclaw onboard（跳过模型、渠道、搜索等交互配置）..."
echo "  如需添加 AI 模型提供方，之后可运行: openclaw configure"
echo ""

# 跳过已存在的本地会话确认
export OPENCLAW_SUPPRESS_LOCAL_TERM_CHECK=1

openclaw onboard \
  --non-interactive --accept-risk \
  --flow manual \
  --mode local \
  ${DEEPSEEK_KEY:+--deepseek-api-key "$DEEPSEEK_KEY"} \
  --gateway-auth token \
  --gateway-token "$GW_TOKEN" \
  --gateway-port 18789 \
  --gateway-bind lan \
  --install-daemon \
  --skip-channels \
  --skip-search \
  --skip-skills \
  --skip-hooks \
  --skip-ui 2>&1 || {
    echo ""
    echo "  ⚠️  非交互式 Onboarding 遇到问题，尝试常规方式..."
    echo "  请在终端手动执行："
    echo "    source ~/.bashrc"
    echo "    cd ~/openclaw"
    echo "    openclaw onboard --install-daemon"
    echo ""
    echo "  完成后再执行："
    echo "    bash $0 --post-onboard"
    echo ""
    exit 1
  }

echo ""
echo "==> 17. 启用平台连接所需设置"

echo "  启用 admin-http-rpc 插件..."
openclaw plugins enable admin-http-rpc 2>/dev/null || echo "  ⚠️  启用 admin-http-rpc 失败"

echo "  启用 OpenAI 兼容 API..."
python3 << 'PYEOF'
import json, os
path = os.path.expanduser(os.environ.get('HOME','')) + '/.openclaw/openclaw.json'
if os.path.exists(path):
    with open(path, 'r') as f:
        cfg = json.load(f)
    gw = cfg.setdefault('gateway', {})
    http = gw.setdefault('http', {})
    eps = http.setdefault('endpoints', {})
    cc = eps.setdefault('chatCompletions', {})
    cc['enabled'] = True
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print('  配置文件已更新')
else:
    print('  配置文件不存在，跳过')
    exit(1)
PYEOF

echo "  修复 bundled 渠道依赖..."
openclaw doctor --fix 2>/dev/null || echo "  ⚠️  doctor 修复失败，可手动执行 openclaw doctor --fix"

echo ""
echo "==> 18. 重启 gateway"
openclaw gateway restart 2>/dev/null || {
  echo "  ⚠️  重启失败，尝试手动启动..."
  sudo systemctl restart openclaw-gateway 2>/dev/null || echo "  ⚠️  请稍后手动重启 gateway"
}

echo ""
echo "============================================================"
echo "✅ 部署完成！"
echo "============================================================"
echo ""

# 提取网关 token（从配置文件中读取）
GW_TOKEN_DISPLAY=""
GW_CFG="$HOME/.openclaw/openclaw.json"
if [ -f "$GW_CFG" ]; then
  GW_TOKEN_DISPLAY=*** -c "
import json
with open('$GW_CFG') as f:
    cfg = json.load(f)
print(cfg.get('gateway',{}).get('auth',{}).get('token','（未找到）'))
" 2>/dev/null || GW_TOKEN_DISPLAY="$GW_TOKEN"
else
  GW_TOKEN_DISPLAY="$GW_TOKEN"
fi

# 获取内部 IP
INT_IP=$(hostname -I | awk '{print $1}')
if [ -z "$INT_IP" ]; then
  INT_IP=$(ip route get 1 | awk '{print $7; exit}' 2>/dev/null || echo "unknown")
fi

echo "============================================================"
echo "📋 平台注册信息"
echo "============================================================"
echo ""
echo "  服务器内部 IP:     $INT_IP"
echo "  OpenClaw Base URL: http://$INT_IP:18789"
echo "  Gateway URL:       http://$INT_IP:18789"
echo "  Gateway Token:     $GW_TOKEN_DISPLAY"
echo ""
echo "  在平台创建智能体时填入以上信息。"
echo "  如果使用域名，请将 Gateway URL 改为 https://你的域名"
echo "============================================================"
echo ""
echo "常用命令："
echo ""
echo "  openclaw gateway status      查看网关状态"
echo "  openclaw gateway restart     重启网关"
echo "  openclaw configure           配置模型、渠道等"
echo "  openclaw chat                命令行对话"
echo ""
echo "注意：本脚本未配置 AI 模型提供方。"
echo "如需添加，请执行: openclaw configure"
echo "============================================================"
