#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="PAAAAAAA335"
PRIVATE_REPO="paje-vps-toolkit"
FULL_REPO="${OWNER}/${PRIVATE_REPO}"
KEY="/root/.ssh/paje_github_readonly"
WORK="/opt/paje-vps-toolkit"
TMP="${WORK}.new.$$"

log(){ printf '\033[1;32m[PAJE] %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
cleanup_tmp(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup_tmp EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
[[ -r /etc/os-release ]] || die "缺少 /etc/os-release"
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "当前仅支持 Debian 11/12/13。"
case "${VERSION_ID:-}" in 11|12|13) ;; *) die "当前仅支持 Debian 11/12/13，检测到 ${VERSION_ID:-unknown}";; esac

log "准备基础依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git openssh-client python3

if ! command -v gh >/dev/null 2>&1; then
  log "安装 GitHub CLI..."
  if ! apt-get install -y gh; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -y
    apt-get install -y gh
  fi
fi

install -d -m 0700 /root/.ssh
if [[ ! -s "${KEY}" || ! -s "${KEY}.pub" ]]; then
  log "为本机生成 PAJE 专用只读 SSH Key..."
  rm -f "${KEY}" "${KEY}.pub"
  ssh-keygen -q -t ed25519 -f "${KEY}" -N '' -C "paje-readonly@$(hostname)"
  chmod 600 "${KEY}"
  chmod 644 "${KEY}.pub"
fi

log "写入 GitHub 官方 SSH 主机公钥..."
tmp_hosts="$(mktemp)"
curl -fsSL https://api.github.com/meta | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("github.com "+k) for k in d.get("ssh_keys",[]) ]' > "$tmp_hosts"
[[ -s "$tmp_hosts" ]] || die "无法取得 GitHub SSH 主机公钥。"
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
sed -i '/^github\.com[ ,]/d' /root/.ssh/known_hosts || true
cat "$tmp_hosts" >> /root/.ssh/known_hosts
rm -f "$tmp_hosts"

export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

if ! git ls-remote "git@github.com:${FULL_REPO}.git" HEAD >/dev/null 2>&1; then
  log "首次授权：请按终端提示，在浏览器确认一次 GitHub 登录。"
  had_auth=0
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    had_auth=1
  else
    gh auth login --hostname github.com --web --git-protocol https --scopes repo
  fi

  login="$(gh api user --jq .login 2>/dev/null || true)"
  [[ "$login" == "$OWNER" ]] || die "当前 GitHub 登录账号为 ${login:-unknown}，需要 ${OWNER}。"

  pub="$(cat "${KEY}.pub")"
  title="PAJE-$(hostname)-$(date +%Y%m%d%H%M%S)"
  if ! gh api --method POST "repos/${FULL_REPO}/keys" -f title="$title" -f key="$pub" -F read_only=true >/dev/null 2>&1; then
    warn "Deploy Key 注册接口未返回成功，正在直接验证是否已经存在。"
  fi

  sleep 2
  git ls-remote "git@github.com:${FULL_REPO}.git" HEAD >/dev/null 2>&1 || die "Private Repo 只读授权失败。"

  if [[ "$had_auth" -eq 0 ]]; then
    gh auth logout --hostname github.com --user "$OWNER" >/dev/null 2>&1 || true
    log "临时 GitHub CLI 本地登录已移除；VPS 仅保留本仓库只读 Deploy Key。"
  fi
fi

rm -rf "$TMP"
log "拉取 PAJE 私有仓库..."
git clone --filter=blob:none "git@github.com:${FULL_REPO}.git" "$TMP"
cd "$TMP"

git fetch --tags --force >/dev/null 2>&1 || true
latest_tag="$(git tag --list 'v*' --sort=-v:refname | head -n1 || true)"
if [[ -n "$latest_tag" ]]; then
  log "使用已发布版本：$latest_tag"
  git checkout --detach "$latest_tag"
else
  warn "当前尚无正式 Release Tag，使用 main 测试通道。"
  git checkout main
fi

log "还原并校验 PAJE 大型源码..."
python3 scripts/materialize_packed.py

log "执行安装前完整静态检查..."
bash tests/run.sh

rm -rf "${WORK}.old"
if [[ -d "$WORK" ]]; then mv "$WORK" "${WORK}.old"; fi
mv "$TMP" "$WORK"
trap - EXIT
cd "$WORK"

log "安装 PAJE..."
if bash install.sh; then
  rm -rf "${WORK}.old" 2>/dev/null || true
else
  rc=$?
  warn "PAJE 安装失败，恢复 /opt 下上一版本。"
  rm -rf "$WORK" 2>/dev/null || true
  [[ -d "${WORK}.old" ]] && mv "${WORK}.old" "$WORK" || true
  exit "$rc"
fi

printf '\n'
log "完成。以后直接输入：paje"
printf '\n'
exec paje
