#!/usr/bin/env bash
#
# deploy-frontend-with-nginx.sh
# Deploy React frontend from repo and install nginx.conf (inject backend IP).
# - replaces relative "mime.types" include with absolute path for temp test
# - validates nginx config with nginx -t -c <tmp> before replacing live config
# - idempotent: safe to run multiple times
#
set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG - edit if necessary ----------------
REPO_URL="${REPO_URL:-https://github.com/sapsecops/3_Tier_Nodejs_App.git}"
CLONE_PARENT="${CLONE_PARENT:-/home/ec2-user}"
REPO_DIR="${REPO_DIR:-3_Tier_Nodejs_App}"
BRANCH="${BRANCH:-01-Local-setup}"
EC2_USER="${EC2_USER:-ec2-user}"
NODE_VERSION="${NODE_VERSION:-16}"
CLIENT_SUBDIR="${CLIENT_SUBDIR:-client}"
FRONTEND_ROOT="${FRONTEND_ROOT:-/var/www/frontend}"
NVM_INSTALL_SCRIPT_URL="${NVM_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh}"
# repository nginx.conf placeholders that will be replaced by BACKEND_IP
PLACEHOLDER_A="<Backend-Private-IP>"
PLACEHOLDER_B="BACKEND_IP_PLACEHOLDER"
# -----------------------------------------------------------

log(){ echo "==> $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# Accept backend IP as first arg or via BACKEND_IP env
BACKEND_IP="${1:-${BACKEND_IP:-}}"
if [[ -z "${BACKEND_IP}" ]]; then
  echo "Usage: sudo $0 <backend-private-ip>   OR   sudo BACKEND_IP=1.2.3.4 $0"
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "This script requires sudo/root. Run with sudo." >&2
  exit 1
fi

# Ensure ec2 user exists
if ! id -u "${EC2_USER}" >/dev/null 2>&1; then
  err "User ${EC2_USER} not found on this host. Edit EC2_USER variable if needed."
fi

log "Deploy frontend from ${REPO_URL} (branch ${BRANCH}) and configure nginx to proxy to ${BACKEND_IP}"

# --- 1) Install git ---
log "Installing git (yum/dnf)..."
if command -v yum >/dev/null 2>&1; then
  yum install -y git
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y git
else
  err "Neither yum nor dnf found; install git manually."
fi

# --- 2) Install nginx ---
log "Installing nginx if missing..."
if ! command -v nginx >/dev/null 2>&1; then
  if command -v yum >/dev/null 2>&1; then
    yum install -y nginx
  else
    dnf install -y nginx
  fi
else
  log "nginx already installed"
fi

log "Enabling and starting nginx"
systemctl daemon-reload || true
systemctl enable nginx || true
systemctl start nginx

# --- 3) Ensure frontend root exists ---
log "Creating frontend root ${FRONTEND_ROOT}"
mkdir -p "${FRONTEND_ROOT}"
chmod -R 755 "${FRONTEND_ROOT}"
chown -R "${EC2_USER}:${EC2_USER}" "${FRONTEND_ROOT}"

# --- 4) Install nvm + Node for ec2-user (idempotent) ---
NVM_DIR="/home/${EC2_USER}/.nvm"
NVM_SCRIPT="${NVM_DIR}/nvm.sh"

if [[ ! -s "${NVM_SCRIPT}" ]]; then
  log "Installing nvm for ${EC2_USER}"
  sudo -u "${EC2_USER}" bash -lc "curl -fsSL ${NVM_INSTALL_SCRIPT_URL} | bash" || true
else
  log "nvm already present for ${EC2_USER}"
fi

log "Installing/ensuring Node ${NODE_VERSION} for ${EC2_USER}"
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm install ${NODE_VERSION} >/dev/null 2>&1 || true; nvm alias default ${NODE_VERSION}; node -v; npm -v"

# --- 5) Clone or update repo as ec2-user ---
mkdir -p "${CLONE_PARENT}"
cd "${CLONE_PARENT}" || err "Cannot cd to ${CLONE_PARENT}"

REPO_PATH="${CLONE_PARENT}/${REPO_DIR}"

if [[ -d "${REPO_PATH}/.git" ]]; then
  log "Repository exists at ${REPO_PATH} — fetching updates"
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" fetch --all --prune || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}" || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" pull --ff-only origin "${BRANCH}" || true
else
  log "Cloning ${REPO_URL} into ${REPO_PATH}"
  sudo -u "${EC2_USER}" git clone "${REPO_URL}" "${REPO_PATH}"
  # attempt to checkout branch
  if sudo -u "${EC2_USER}" git -C "${REPO_PATH}" rev-parse --verify "${BRANCH}" >/dev/null 2>&1; then
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}"
  else
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" fetch origin "${BRANCH}" || true
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout -b "${BRANCH}" "origin/${BRANCH}" || true
  fi
fi

# ensure ownership
chown -R "${EC2_USER}:${EC2_USER}" "${REPO_PATH}"

# --- 6) Prepare nginx config from repo and inject BACKEND_IP ---
REPO_NGINX_CONF="${REPO_PATH}/${CLIENT_SUBDIR}/nginx.conf"
SYSTEM_NGINX_CONF="/etc/nginx/nginx.conf"
TIMESTAMP="$(date +%s)"
BACKUP="${SYSTEM_NGINX_CONF}.bak.${TIMESTAMP}"
TMP_CONF="/tmp/nginx.conf.${TIMESTAMP}"
NGINX_TEST_OUTPUT="/tmp/nginx-test.${TIMESTAMP}.out"

if [[ -f "${REPO_NGINX_CONF}" ]]; then
  log "Found repo nginx.conf at ${REPO_NGINX_CONF}. Backing up current nginx.conf -> ${BACKUP}"
  if [[ -f "${SYSTEM_NGINX_CONF}" ]]; then
    cp -a "${SYSTEM_NGINX_CONF}" "${BACKUP}"
  fi

  log "Copying and injecting backend IP into nginx config (temporary file ${TMP_CONF})"
  cp -a "${REPO_NGINX_CONF}" "${TMP_CONF}"

  # Replace common relative includes with absolute paths so nginx -t -c <tmp> can find them
  sed -i -E "s|include[[:space:]]+mime.types;|include /etc/nginx/mime.types;|g" "${TMP_CONF}" || true
  sed -i -E "s|include[[:space:]]+/usr/share/nginx/modules/\*\.conf;|include /usr/share/nginx/modules/*.conf;|g" "${TMP_CONF}" || true
  sed -i -E "s|include[[:space:]]+/etc/nginx/conf.d/\*\.conf;|include /etc/nginx/conf.d/*.conf;|g" "${TMP_CONF}" || true

  # Replace backend placeholders with provided BACKEND_IP (multiple variants)
  sed -i "s|${PLACEHOLDER_A}|${BACKEND_IP}|g" "${TMP_CONF}" || true
  sed -i "s|${PLACEHOLDER_B}|${BACKEND_IP}|g" "${TMP_CONF}" || true
  sed -i "s|BACKEND_IP|${BACKEND_IP}|g" "${TMP_CONF}" || true

  # show a short diff for debugging if system config existed
  if [[ -f "${SYSTEM_NGINX_CONF}" ]]; then
    log "Diff between backup and new config (if any):"
    diff -u "${BACKUP}" "${TMP_CONF}" || true
  fi

  # Validate the temporary config with nginx -t -c <tmp>
  log "Testing nginx configuration using temporary file"
  if nginx -t -c "${TMP_CONF}" > "${NGINX_TEST_OUTPUT}" 2>&1; then
    log "nginx test OK — installing new config"
    mv "${TMP_CONF}" "${SYSTEM_NGINX_CONF}"
    chmod 644 "${SYSTEM_NGINX_CONF}"
  else
    echo "==== nginx test failed for temporary config. Output follows: ===="
    sed -n '1,200p' "${NGINX_TEST_OUTPUT}" || true
    err "nginx -t failed for the prepared config. Aborting without replacing /etc/nginx/nginx.conf"
  fi
else
  log "No nginx.conf found in repo at ${REPO_NGINX_CONF}. Skipping config replacement."
fi

# --- 7) Restart nginx now that config is installed (or unchanged) ---
log "Reloading nginx"
systemctl restart nginx
sleep 1
if ! systemctl is-active --quiet nginx; then
  journalctl -u nginx -n 80 --no-pager || true
  err "nginx failed to start after installing config"
fi

# --- 8) Build frontend (npm install && npm run build) as ec2-user ---
CLIENT_DIR="${REPO_PATH}/${CLIENT_SUBDIR}"
if [[ ! -d "${CLIENT_DIR}" ]]; then
  err "Client directory not found at ${CLIENT_DIR}"
fi

log "Installing frontend dependencies and building (as ${EC2_USER})"
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR:-/home/${EC2_USER}/.nvm}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; cd '${CLIENT_DIR}'; nvm use ${NODE_VERSION} >/dev/null 2>&1 || nvm install ${NODE_VERSION}; npm install --unsafe-perm; npm run build"

BUILD_DIR="${CLIENT_DIR}/build"
if [[ ! -d "${BUILD_DIR}" ]]; then
  err "Build directory ${BUILD_DIR} not found. 'npm run build' likely failed."
fi

# --- 9) Deploy build/ to FRONTEND_ROOT ---
log "Deploying built static files to ${FRONTEND_ROOT}"
rm -rf "${FRONTEND_ROOT:?}"/* || true
cp -a "${BUILD_DIR}/." "${FRONTEND_ROOT}/"
chown -R "${EC2_USER}:${EC2_USER}" "${FRONTEND_ROOT}"
chmod -R 755 "${FRONTEND_ROOT}"

# --- 10) Final nginx restart to serve files ---
log "Restarting nginx to serve the new frontend files"
systemctl restart nginx
sleep 1
if ! systemctl is-active --quiet nginx; then
  journalctl -u nginx -n 80 --no-pager || true
  err "nginx failed after deploying frontend"
fi

log "=== Frontend deployment successful ==="
log "Frontend files: ${FRONTEND_ROOT}"
log "Nginx config: ${SYSTEM_NGINX_CONF}"
log "Backend proxied to: ${BACKEND_IP}"
log "Make sure EC2 Security Group allows inbound TCP/HTTP (80) to this instance."

exit 0
