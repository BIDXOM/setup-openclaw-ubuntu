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
echo "下一步执行："
echo ""
echo "  source ~/.bashrc"
echo "  cd ~/openclaw"
echo "  openclaw onboard --install-daemon"
echo ""
echo "如果 openclaw 命令不可用，就用："
echo ""
echo "  cd ~/openclaw"
echo "  pnpm openclaw onboard --install-daemon"
echo ""
echo "Onboarding 推荐选择："
echo ""
echo "  Setup mode: Manual setup"
echo "  Gateway port: 18789"
echo "  Gateway bind: Loopback / 127.0.0.1"
echo "  Gateway protection: Token"
echo "  Tailscale exposure: Off"
echo "  Telegram DM policy: Allowlist"
echo "  Telegram allowFrom: 你的 Telegram 数字 ID"
echo "  Web search: Skip for now 或 DuckDuckGo"
echo "  Optional plugins: Skip for now"
echo "  Hooks: Skip for now"
echo "============================================================"
echo "❗ 重要：Onboarding 完成后，务必执行以下步骤："
echo ""
echo "  # 1. 启用 admin-http-rpc（平台 Admin RPC 连接必需）"
echo "  openclaw plugins enable admin-http-rpc"
echo ""
echo "  # 2. 启用 OpenAI 兼容 API（平台 /v1/chat/completions 必需）"
echo '  openclaw config patch --raw '"'"'{"gateway":{"http":{"endpoints":{"chatCompletions":{"enabled":true}}}}}"'"'"''
echo ""
echo "  # 3. 重启 gateway 生效"
echo "  openclaw gateway restart"
echo ""
echo "============================================================"
echo ""

echo ""
echo "常用命令："
echo ""
echo "  openclaw gateway status"
echo "  openclaw gateway restart"
echo "  openclaw config validate"
echo "  openclaw configure"
echo "  openclaw chat"
echo ""
echo "如果你后面修改源码，建议："
echo ""
echo "  cd ~/openclaw"
echo "  git status"
echo "  pnpm ui:build"
echo "  openclaw gateway restart"
echo ""
echo "注意：本脚本默认不执行 pnpm build。"
echo "如果机器内存升级到 8G/16G 后，可以手动尝试："
echo ""
echo "  cd ~/openclaw"
echo "  NODE_OPTIONS=\"--max-old-space-size=12288\" pnpm build"
echo ""
echo "============================================================"
