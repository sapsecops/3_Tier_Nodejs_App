#!/usr/bin/env bash
# deploy-node-backend-complete.sh
# Full idempotent deployment script for 3_Tier_Nodejs_App backend (Node 16 + pm2)
# Run as root: sudo bash deploy-node-backend-complete.sh
#
set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG (edit as needed) ----------------
REPO_URL="${REPO_URL:-https://github.com/sapsecops/3_Tier_Nodejs_App.git}"
CLONE_PARENT="${CLONE_PARENT:-/home/ec2-user}"
REPO_DIR="${REPO_DIR:-3_Tier_Nodejs_App}"
BRANCH="${BRANCH:-01-Local-setup}"
APP_SUBDIR="${APP_SUBDIR:-api}"
EC2_USER="${EC2_USER:-ec2-user}"

# DB access (dbadmin used to run init script)
DB_ADMIN_HOST="${DB_ADMIN_HOST:-172.31.5.129}"
DB_ADMIN_USER="${DB_ADMIN_USER:-dbadmin}"
DB_ADMIN_PW="${DB_ADMIN_PW:-Admin@123}"
DB_NAME="${DB_NAME:-crud_app}"

# App-level DB credentials to put in .env (appuser credentials expected by app)
APP_DB_HOST="${APP_DB_HOST:-${DB_ADMIN_HOST}}"
APP_DB_USER="${APP_DB_USER:-appuser}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-P@55Word}"
APP_DB_NAME="${APP_DB_NAME:-${DB_NAME}}"
JWT_SECRET="${JWT_SECRET:-sapsecopsSuperSecretKey}"
APP_PORT="${APP_PORT:-5000}"

NODE_VERSION="${NODE_VERSION:-16}"
NVM_INSTALL_SCRIPT_URL="${NVM_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh}"
# --------------------------------------------------------

log(){ echo "==> $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo/root. Re-run as: sudo bash $0" >&2
  exit 1
fi

# sanity
if ! id -u "${EC2_USER}" >/dev/null 2>&1; then
  err "User ${EC2_USER} does not exist on this host. Edit EC2_USER if needed."
fi

REPO_PATH="${CLONE_PARENT}/${REPO_DIR}"
NVM_DIR="/home/${EC2_USER}/.nvm"
API_DIR="${REPO_PATH}/${APP_SUBDIR}"
INITSQL="${API_DIR}/initdb.sql"

log "Starting deployment. Repo: ${REPO_URL}, branch: ${BRANCH}, app dir: ${API_DIR}"

# ------------------ 1) Install git ------------------
log "Installing git (if missing)..."
if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y git
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y git
else
  err "No package manager (dnf/yum) found. Install git manually."
fi

# ------------------ 2) Fix ownership & git safe.directory ------------------
log "Ensuring ${CLONE_PARENT} ownership and Git safe.directory"
sudo mkdir -p "${CLONE_PARENT}"
sudo chown -R "${EC2_USER}:${EC2_USER}" "${CLONE_PARENT}" || true
# add safe.directory for repo path (will quietly set even if repo missing)
sudo -u "${EC2_USER}" git config --global --add safe.directory "${REPO_PATH}" || true

# ------------------ 3) nvm + Node ------------------
log "Installing nvm for ${EC2_USER} (if missing) and Node ${NODE_VERSION}"
if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
  sudo -u "${EC2_USER}" bash -lc "curl -fsSL ${NVM_INSTALL_SCRIPT_URL} | bash" || true
fi
# Install Node as ec2-user (login shell ensures nvm available)
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm install ${NODE_VERSION} >/dev/null 2>&1 || true; nvm alias default ${NODE_VERSION}; node -v; npm -v"

# ------------------ 4) Clone or update repo ------------------
log "Cloning/updating repository as ${EC2_USER}"
cd "${CLONE_PARENT}"
if [[ -d "${REPO_PATH}/.git" ]]; then
  chown -R "${EC2_USER}:${EC2_USER}" "${REPO_PATH}" || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" fetch --all --prune || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}" || true
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" pull --ff-only origin "${BRANCH}" || true
else
  sudo -u "${EC2_USER}" git clone "${REPO_URL}" "${REPO_PATH}"
  chown -R "${EC2_USER}:${EC2_USER}" "${REPO_PATH}"
  sudo -u "${EC2_USER}" git -C "${REPO_PATH}" checkout "${BRANCH}" || true
fi

# ------------------ 5) Ensure mysql client exists (Amazon Linux aware) ------------------
log "Ensuring a mysql-compatible client is installed (tries mariadb105 on AL2023)"
MYSQL_OK=0

if command -v mysql >/dev/null 2>&1; then
  log "mysql client already available at $(command -v mysql)"
  MYSQL_OK=1
else
  if command -v dnf >/dev/null 2>&1; then
    log "Attempting to install mariadb105 (Amazon Linux 2023) or mariadb package"
    if dnf install -y mariadb105 >/dev/null 2>&1; then
      log "Installed mariadb105"
      MYSQL_OK=1
    elif dnf install -y mariadb >/dev/null 2>&1; then
      log "Installed mariadb"
      MYSQL_OK=1
    else
      log "Could not install mariadb105/mariadb via dnf (packages might differ). Will try fallback package list."
      # fallback attempts
      for pkg in mariadb-server mariadb-client mariadb-connector-c; do
        if dnf install -y "${pkg}" >/dev/null 2>&1; then
          log "Installed ${pkg}"
          if command -v mysql >/dev/null 2>&1; then MYSQL_OK=1; break; fi
        fi
      done
    fi
  elif command -v yum >/dev/null 2>&1; then
    if yum install -y mariadb >/dev/null 2>&1; then
      MYSQL_OK=1
    fi
  fi
fi

if [[ "${MYSQL_OK}" -eq 0 ]]; then
  log "mysql client not available. The script will skip automatic DB import; you can run DB init manually once client is present."
fi

# ------------------ 6) Robust DB init using initdb.sql ------------------
SKIP_DB_INIT=0
if [[ "${MYSQL_OK}" -eq 0 ]]; then
  SKIP_DB_INIT=1
fi

if [[ "${SKIP_DB_INIT}" -eq 0 && -f "${INITSQL}" ]]; then
  log "Found init SQL at ${INITSQL}. Attempting to initialize DB on ${DB_ADMIN_HOST} as ${DB_ADMIN_USER}"

  # Attempt A: run SQL file directly (it contains CREATE DATABASE etc.)
  if sudo -u "${EC2_USER}" bash -lc "MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' < '${INITSQL}'"; then
    log "init SQL executed successfully (direct execution)."
  else
    log "Direct execution failed — attempting CREATE DATABASE then import."

    # Attempt to create database first (idempotent)
    if sudo -u "${EC2_USER}" bash -lc "MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' -e \"CREATE DATABASE IF NOT EXISTS \\\`${DB_NAME}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""; then
      log "Created ${DB_NAME} (or already exists). Now importing SQL into ${DB_NAME}..."
      if sudo -u "${EC2_USER}" bash -lc "MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' '${DB_NAME}' < '${INITSQL}'"; then
        log "init SQL imported successfully into ${DB_NAME}."
      else
        log "Import into ${DB_NAME} failed. Possible causes: insufficient privileges for ${DB_ADMIN_USER} or SQL needs higher privileges."
        log "Manual diagnostics suggestions:"
        log "  - Test connection and show DBs: MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' -e 'SHOW DATABASES;'"
        log "  - Show grants for dbadmin (run on DB server as root): sudo mysql -e \"SHOW GRANTS FOR '${DB_ADMIN_USER}'@'%';\""
        log "  - Create DB as root on DB server and re-run import"
      fi
    else
      log "CREATE DATABASE failed when run as ${DB_ADMIN_USER}. User may lack CREATE privilege."
      log "Manual steps you can run on DB server as root:"
      log "  sudo mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`${DB_NAME}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
      log "  sudo mysql -e \"GRANT ALL PRIVILEGES ON \\\`${DB_NAME}\\\`.* TO '${DB_ADMIN_USER}'@'%'; FLUSH PRIVILEGES;\""
      log "After that, re-run the import from this host:"
      log "  MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' '${DB_NAME}' < '${INITSQL}'"
    fi
  fi
else
  if [[ ! -f "${INITSQL}" ]]; then
    log "No init SQL found at ${INITSQL}. Skipping DB init."
  else
    log "Skipping DB init because mysql client is not installed on this host. Install a mysql client (e.g. mariadb105) and re-run import manually."
  fi
fi

# ------------------ 7) Write .env for app ------------------
if [[ -d "${API_DIR}" ]]; then
  ENV_FILE="${API_DIR}/.env"
  log "Writing .env to ${ENV_FILE} (backup if exists)"
  if [[ -f "${ENV_FILE}" ]]; then
    sudo cp -a "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%s)"
  fi
  sudo -u "${EC2_USER}" bash -lc "cat > '${ENV_FILE}' <<'EOF'
DB_HOST=${APP_DB_HOST}
DB_USER=${APP_DB_USER}
DB_PASSWORD=${APP_DB_PASSWORD}
DB_NAME=${APP_DB_NAME}
JWT_SECRET=${JWT_SECRET}
PORT=${APP_PORT}
EOF"
  sudo chown "${EC2_USER}:${EC2_USER}" "${ENV_FILE}"
  sudo chmod 600 "${ENV_FILE}"
else
  log "API dir ${API_DIR} not found; skipping .env creation."
fi

# ------------------ 8) npm install ------------------
if [[ -d "${API_DIR}" ]]; then
  log "Installing npm dependencies in ${API_DIR} as ${EC2_USER}"
  sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; cd '${API_DIR}'; nvm use ${NODE_VERSION} >/dev/null 2>&1 || nvm install ${NODE_VERSION}; npm install --unsafe-perm"
else
  log "API dir ${API_DIR} not found; cannot run npm install."
fi

# ------------------ 9) pm2 install & start ------------------
log "Installing pm2 globally (if needed) and starting the app"
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use ${NODE_VERSION} >/dev/null 2>&1 || true; npm install -g pm2 --unsafe-perm"

# detect entrypoint
APP_ENTRY="${API_DIR}/app.js"
if [[ ! -f "${APP_ENTRY}" ]]; then
  if [[ -f "${API_DIR}/index.js" ]]; then APP_ENTRY="${API_DIR}/index.js"; fi
  if [[ -f "${API_DIR}/server.js" ]]; then APP_ENTRY="${API_DIR}/server.js"; fi
fi

if [[ -f "${APP_ENTRY}" ]]; then
  log "Starting ${APP_ENTRY} with pm2 (name: backend)"
  sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; pm2 start '${APP_ENTRY}' --name backend || pm2 restart backend || true"
else
  log "No direct entry script found; attempting pm2 start via 'npm start'"
  sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; cd '${API_DIR}'; pm2 start npm --name backend -- start || pm2 restart backend || true"
fi

log "Configuring pm2 to start on boot and saving process list"
sudo -i -u "${EC2_USER}" bash -lc "export NVM_DIR='${NVM_DIR}'; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; pm2 startup systemd -u ${EC2_USER} --hp /home/${EC2_USER} | sudo bash -s"
sudo -i -u "${EC2_USER}" bash -lc "pm2 save"

log "=== Deployment finished ==="
log "App directory: ${API_DIR}"
log "pm2 processes: sudo -u ${EC2_USER} pm2 ls"
if [[ "${SKIP_DB_INIT}" -eq 1 ]]; then
  log "NOTE: DB init skipped because mysql client was not installed. To initialize DB manually once client is available, run:"
  log "  MYSQL_PWD='${DB_ADMIN_PW}' mysql -h '${DB_ADMIN_HOST}' -u '${DB_ADMIN_USER}' < '${INITSQL}'"
fi

exit 0
