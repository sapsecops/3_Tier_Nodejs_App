#!/usr/bin/env bash
#
# deploy-node-backend.sh
# Idempotent deploy script for the 3_Tier_Nodejs_App backend (Node 16 + pm2)
#
# Usage:
#  sudo ./deploy-node-backend.sh
#
set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG (edit as needed) ----------------
REPO_URL="${REPO_URL:-https://github.com/sapsecops/3_Tier_Nodejs_App.git}"
CLONE_PARENT="${CLONE_PARENT:-/home/ec2-user}"
REPO_DIR="${REPO_DIR:-3_Tier_Nodejs_App}"
BRANCH="${BRANCH:-01-Local-setup}"
APP_SUBDIR="${APP_SUBDIR:-api}"   # the backend folder where package.json & initdb.sql exist
EC2_USER="${EC2_USER:-ec2-user}"

# DB admin used to run initdb.sql (must have privileges to create DB/tables)
DB_ADMIN_HOST="${DB_ADMIN_HOST:-172.31.16.207}"   # DB private IP
DB_ADMIN_USER="${DB_ADMIN_USER:-dbadmin}"
DB_ADMIN_PW="${DB_ADMIN_PW:-Admin@123}"
DB_NAME="${DB_NAME:-crud_app}"

# application .env values (app will use these)
APP_DB_HOST="${APP_DB_HOST:-${DB_ADMIN_HOST}}"
APP_DB_USER="${APP_DB_USER:-appuser}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-P@55Word}"
APP_DB_NAME="${APP_DB_NAME:-${DB_NAME}}"
JWT_SECRET="${JWT_SECRET:-sapsecopsSuperSecretKey}"
APP_PORT="${APP_PORT:-5000}"

# Node version via nvm
NODE_VERSION="${NODE_VERSION:-16}"

# ---------------- END CONFIG ----------------

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  echo "It's recommended to run as root or with sudo. The script uses sudo internally." >&2
fi

# Ensure EC2 user exists
if ! id -u "${EC2_USER}" >/dev/null 2>&1; then
  err "User ${EC2_USER} does not exist on this machine. Adjust EC2_USER variable."
fi

# 1) Install git (idempotent)
log "Installing git..."
if command -v yum >/dev/null 2>&1; then
  sudo yum install -y git
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y git
else
  err "Neither yum nor dnf found - install git manually."
fi

# 2) Install nvm + Node.js for ec2-user if not present
NVM_DIR="/home/${EC2_USER}/.nvm"
NVM_SCRIPT="${NVM_DIR}/nvm.sh"

log "Ensuring nvm and Node ${NODE_VERSION} are installed for ${EC2_USER}..."

if [[ -s "${NVM_SCRIPT}" ]]; then
  log "nvm already installed at ${NVM_DIR}"
else
  log "Installing nvm for ${EC2_USER}..."
  # install as ec2-user (creates ~/.nvm and shell profile lines)
  sudo -u "${EC2_USER}" bash -lc "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash"
  # note: script updates user's rc files; don't fail if network errors occur
fi

# Ensure nvm is loaded for the upcoming commands executed as ec2-user. We'll run node installs inside a login shell.
log "Installing Node ${NODE_VERSION} (via nvm) for ${EC2_USER} (if missing)..."
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR=\"${NVM_DIR}\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; if ! nvm ls ${NODE_VERSION} >/dev/null 2>&1; then nvm install ${NODE_VERSION}; fi; nvm alias default ${NODE_VERSION}; node -v; npm -v"

# 3) Clone or update repo as ec2-user
mkdir -p "${CLONE_PARENT}"
cd "${CLONE_PARENT}"

REPO_PATH="${CLONE_PARENT}/${REPO_DIR}"

if [[ -d "${REPO_PATH}/.git" ]]; then
  log "Repository already exists at ${REPO_PATH} — fetching updates..."
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" fetch --all --prune || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}" || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" pull --ff-only origin "${BRANCH}" || true
else
  log "Cloning ${REPO_URL} into ${CLONE_PARENT} as ${EC2_USER}..."
  sudo -u "${EC2_USER}" git clone "${REPO_URL}" "${REPO_PATH}"
  if sudo -u "${EC2_USER}" git -C "${REPO_PATH}" rev-parse --verify "${BRANCH}" >/dev/null 2>&1; then
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}"
  else
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" fetch origin "${BRANCH}" || true
    sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout -b "${BRANCH}" "origin/${BRANCH}" || true
  fi
fi

# Ensure ownership is ec2-user for the repo
sudo chown -R "${EC2_USER}:${EC2_USER}" "${REPO_PATH}"

# 4) Install MySQL client tools
log "Installing MySQL client (mysql)..."
if command -v dnf >/dev/null 2>&1; then
  sudo dnf update -y
  sudo dnf install -y mysql-community-client || sudo dnf install -y mysql
elif command -v yum >/dev/null 2>&1; then
  sudo yum update -y
  sudo yum install -y mysql-community-client || sudo yum install -y mysql
else
  err "Neither dnf nor yum found - cannot install mysql client automatically."
fi

if ! command -v mysql >/dev/null 2>&1; then
  err "mysql client not available after install. Aborting."
fi

# 5) Run initdb.sql if present in api folder (as DB_ADMIN)
API_DIR="${REPO_PATH}/${APP_SUBDIR}"
INITSQL="${API_DIR}/initdb.sql"
if [[ -f "${INITSQL}" ]]; then
  log "Found init SQL at ${INITSQL}. Executing as ${DB_ADMIN_USER}@${DB_ADMIN_HOST}..."
  # Use MYSQL_PWD env var for non-interactive password passing (safer than embedding in cmdline)
  sudo -u "${EC2_USER}" bash -lc "MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' '${DB_NAME}' < '${INITSQL}'" || {
    log "Init DB script returned non-zero exit. Try running manually or check DB connectivity."
  }
else
  log "No initdb.sql found at ${INITSQL}. Skipping DB initialization."
fi

# 6) Create .env in api folder (overwrite backup)
ENV_FILE="${API_DIR}/.env"
log "Writing environment file ${ENV_FILE} (backup if exists)"
if [[ -f "${ENV_FILE}" ]]; then
  sudo cp -a "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%s)"
fi

sudo -u "${EC2_USER}" bash -lc "cat > '${ENV_FILE}'" <<EOF
DB_HOST=${APP_DB_HOST}
DB_USER=${APP_DB_USER}
DB_PASSWORD=${APP_DB_PASSWORD}
DB_NAME=${APP_DB_NAME}
JWT_SECRET=${JWT_SECRET}
PORT=${APP_PORT}
EOF

sudo chown "${EC2_USER}:${EC2_USER}" "${ENV_FILE}"
sudo chmod 600 "${ENV_FILE}"

# 7) Install node deps (npm install) as ec2-user (ensure nvm is loaded)
log "Installing npm dependencies in ${API_DIR} as ${EC2_USER}..."
sudo -i -u "${EC2_USER}" bash -lc "cd '${API_DIR}' && export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || nvm install ${NODE_VERSION}; npm install --unsafe-perm"

# 8) Install pm2 globally and start the app (as ec2-user)
log "Ensuring pm2 is installed and starting the app as 'backend'..."
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || true; npm install -g pm2 --unsafe-perm"

# Start app via pm2 (idempotent)
# We assume app entrypoint is app.js (per your instructions). Adjust if different.
APP_ENTRY="${APP_DIR}/app.js"
if [[ ! -f "${APP_ENTRY}" ]]; then
  # try common alternatives
  if [[ -f "${API_DIR}/index.js" ]]; then APP_ENTRY="${API_DIR}/index.js"; fi
  if [[ -f "${API_DIR}/server.js" ]]; then APP_ENTRY="${API_DIR}/server.js"; fi
fi

if [[ ! -f "${APP_ENTRY}" ]]; then
  log "Cannot locate app entry (app.js|index.js|server.js) in ${API_DIR}. The pm2 start step will use 'npm start' instead."
  sudo -i -u "${EC2_USER}" bash -lc "cd '${API_DIR}'; export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || true; pm2 start npm --name backend -- start"
else
  log "Starting ${APP_ENTRY} with pm2 as 'backend'"
  sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || true; pm2 start '${APP_ENTRY}' --name backend || pm2 restart backend || true"
fi

# Persist pm2 to system startup and save process list
log "Configuring pm2 to start on system boot and saving process list..."
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || true; pm2 startup systemd -u ${EC2_USER} --hp /home/${EC2_USER} | sudo bash -s"
sudo -i -u "${EC2_USER}" bash -lc "pm2 save"

log
log "=== Deployment complete ==="
log "App directory: ${API_DIR}"
log "To inspect pm2 processes: sudo -u ${EC2_USER} pm2 ls"
log "To view logs: sudo -u ${EC2_USER} pm2 logs backend"
log "App should be reachable on port ${APP_PORT} (ensure Security Group allows inbound TCP ${APP_PORT})"
log "If you want the instance launched automatically (t2.micro) and SG rules applied, I can provide a user-data / AWS CLI snippet next."

exit 0
