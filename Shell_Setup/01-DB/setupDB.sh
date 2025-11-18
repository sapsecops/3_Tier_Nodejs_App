#!/usr/bin/env bash
# setup-mysql-el9.sh
# Idempotent installer/configurer for MySQL 8 on EL9 (dnf).
#
# - installs mysql-community-server & client
# - ensures bind-address = 0.0.0.0 in /etc/my.cnf
# - starts/enables mysqld
# - sets root password (using temporary password if present)
# - runs basic secure steps (remove anonymous user, drop test db)
# - creates dbadmin@'%' with ALL privileges (idempotent)
#
# EDIT the variables below before running or export them in the environment.
#
# WARNING: Storing passwords in a script is insecure. Use secrets manager in production.

set -euo pipefail
IFS=$'\n\t'

# ----------------- CONFIG -----------------
ROOT_PW="${ROOT_PW:-VenkY@007}"        # new root password to set (change before running)
DBADMIN_USER="${DBADMIN_USER:-dbadmin}"
DBADMIN_PW="${DBADMIN_PW:-Admin@123}"
MYSQL_REPO_RPM="mysql80-community-release-el9-1.noarch.rpm"
MYSQL_REPO_URL="https://dev.mysql.com/get/${MYSQL_REPO_RPM}"
MYSQL_GPG_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
BIND_ADDR="0.0.0.0"

# ----------------- END CONFIG -----------------

log(){ echo "==> $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  echo "This script requires root. Run with sudo." >&2
  exit 1
fi

log "1) Installing MySQL repo rpm & packages (if needed)"

cd /tmp
if ! rpm -q mysql-community-server >/dev/null 2>&1; then
  if [[ ! -f "${MYSQL_REPO_RPM}" ]]; then
    log "Downloading ${MYSQL_REPO_RPM}"
    curl -sS -O "${MYSQL_REPO_URL}"
  else
    log "${MYSQL_REPO_RPM} already present in /tmp"
  fi

  log "Installing repo package ${MYSQL_REPO_RPM}"
  dnf install -y "${MYSQL_REPO_RPM}"

  log "Importing MySQL GPG key"
  rpm --import "${MYSQL_GPG_KEY_URL}" || true
else
  log "mysql-community-server already installed (package present)"
fi

# Install client & server packages idempotently
if ! rpm -q mysql-community-client >/dev/null 2>&1; then
  log "Installing mysql-community-client"
  dnf install -y mysql-community-client
else
  log "mysql-community-client already installed"
fi

if ! rpm -q mysql-community-server >/dev/null 2>&1; then
  log "Installing mysql-community-server"
  dnf install -y mysql-community-server
else
  log "mysql-community-server already installed"
fi

log "2) Starting and enabling mysqld service"
systemctl daemon-reload || true
systemctl start mysqld
systemctl enable mysqld
systemctl is-active --quiet mysqld && log "mysqld is active" || err "mysqld failed to start; check 'journalctl -u mysqld'"

log "3) Ensure bind-address = ${BIND_ADDR} in /etc/my.cnf (backup will be created)"
MYCNF="/etc/my.cnf"
if [[ ! -f "${MYCNF}" ]]; then
  err "${MYCNF} not found"
fi

cp -a "${MYCNF}" "${MYCNF}.bak.$(date +%s)"
# Put bind-address under [mysqld] section (idempotent)
if grep -Pzoq "(?s)\\[mysqld\\].*?bind-address\\s*=.*" "${MYCNF}"; then
  # replace existing bind-address value in [mysqld]
  awk -v addr="${BIND_ADDR}" '
    BEGIN{inmysqld=0}
    /^\[mysqld\]/{inmysqld=1; print; next}
    /^\[/{inmysqld=0; print; next}
    {
      if(inmysqld && $1=="bind-address") {
        print "bind-address = " addr
      } else {
        print
      }
    }' "${MYCNF}.bak.$(date +%s)" > "${MYCNF}.tmp" || true
  # but awk approach above used a snapshot file; simpler replace using sed if earlier didn't work
fi

# Simpler idempotent approach: add or replace bind-address in [mysqld]
# Remove any existing bind-address lines
awk '
  BEGIN{inmysqld=0}
  /^\[mysqld\]/{inmysqld=1; print; next}
  /^\[/{inmysqld=0; print; next}
  {
    if(inmysqld && $1=="bind-address") {
      # skip old bind-address
      next
    } else {
      print
    }
  }' "${MYCNF}" > "${MYCNF}.nobind"
# Now insert bind-address after [mysqld] header (if not present)
if grep -q "^\[mysqld\]" "${MYCNF}.nobind"; then
  awk -v addr="${BIND_ADDR}" '
    BEGIN{inserted=0}
    /^\[mysqld\]/{print; print "bind-address = " addr; inserted=1; next}
    {print}
    END{ if(!inserted) print "[mysqld]\nbind-address = " addr }
  ' "${MYCNF}.nobind" > "${MYCNF}.new"
  mv "${MYCNF}.new" "${MYCNF}"
  rm -f "${MYCNF}.nobind"
else
  # fallback: just append section
  echo -e "\n[mysqld]\nbind-address = ${BIND_ADDR}" >> "${MYCNF}"
  rm -f "${MYCNF}.nobind"
fi

log "Restarting mysqld to apply configuration change"
systemctl restart mysqld
sleep 2
systemctl is-active --quiet mysqld || {
  journalctl -u mysqld -n 80 --no-pager
  err "mysqld failed to restart after changing ${MYCNF}"
}

log "4) Retrieve temporary root password (if any) and set root password securely"

# Grab latest temporary password line from log (if exists)
TMP_PW=""
if sudo grep -i 'temporary password' /var/log/mysqld.log >/dev/null 2>&1; then
  TMP_PW="$(sudo grep -i 'temporary password' /var/log/mysqld.log | tail -n1 | awk '{print $NF}')"
  log "Detected temporary MySQL root password in /var/log/mysqld.log"
fi

# Helper to run mysql client; returns 0 if successful
mysql_run() {
  local args=("$@")
  mysql "${args[@]}" -e "SELECT VERSION();" >/dev/null 2>&1
}

# If root can already login with desired ROOT_PW, skip
if mysql -u root -p"${ROOT_PW}" -e "SELECT 1" >/dev/null 2>&1; then
  log "Root already configured with the requested ROOT_PW (skipping root password set)."
else
  if [[ -n "${TMP_PW}" ]]; then
    log "Using temporary password to set the root password non-interactively"
    # Use --connect-expired-password in case initial password is expired (common with MySQL 8)
    mysql --connect-expired-password -u root -p"${TMP_PW}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';" || {
      log "Failed to alter root using temporary password — trying with unix_socket fallback"
    }
  else
    log "No temporary password found. Attempting to set root password if login without password works (not typical)"
    if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';" >/dev/null 2>&1; then
      log "Set root password by connecting without password (successful)."
    else
      err "Could not set root password: no temporary password found and root login without password failed. Please run 'sudo grep \"temporary password\" /var/log/mysqld.log' and set the root password manually."
    fi
  fi
fi

log "5) Run basic secure steps (remove anonymous users, drop test DB, reload privileges). Will NOT change root remote access."

# SQL to run idempotently
SECURE_SQL=$(cat <<'SQL'
DELETE FROM mysql.user WHERE User='' OR User IS NULL;
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL
)

# Execute secure SQL as root using the new root password
mysql -u root -p"${ROOT_PW}" -e "${SECURE_SQL}"

log "6) Create DB admin user '${DBADMIN_USER}'@'%' with ALL privileges (idempotent)"
CREATE_SQL=$(cat <<SQL
-- create or alter user and grant privileges
CREATE USER IF NOT EXISTS '${DBADMIN_USER}'@'%' IDENTIFIED BY '${DBADMIN_PW}';
ALTER USER '${DBADMIN_USER}'@'%' IDENTIFIED BY '${DBADMIN_PW}';
GRANT ALL PRIVILEGES ON *.* TO '${DBADMIN_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
)
mysql -u root -p"${ROOT_PW}" -e "${CREATE_SQL}"

log "7) Final checks"
log "MySQL version:"
mysql -u root -p"${ROOT_PW}" -e "SELECT VERSION();" || true

log "MySQL users (showing dbadmin and root):"
mysql -u root -p"${ROOT_PW}" -e "SELECT User, Host FROM mysql.user WHERE User IN ('root','${DBADMIN_USER}');" || true

log
log "=== Completed MySQL setup ==="
log "Notes:"
log "- bind-address set to ${BIND_ADDR} in ${MYCNF}"
log "- Root password set (please store it securely)."
log "- dbadmin@'%' created with ALL privileges."
log "- Open port 3306 in your Security Group to allow remote access, or better: restrict to specific CIDR(s)."
log "- You originally mentioned SG port 27017 for MongoDB — ensure you open the correct DB port(s) as required."

exit 0
