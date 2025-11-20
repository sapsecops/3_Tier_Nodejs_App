#!/usr/bin/env bash
# setup-mysql-el9-fixed.sh
# Fixed idempotent installer for MySQL 8 on EL9 (dnf).
# Use: sudo bash setup-mysql-el9-fixed.sh

set -euo pipefail
IFS=$'\n\t'

# -------- CONFIG: edit or export before running ----------
ROOT_PW="${ROOT_PW:-VenkY@007}"
DBADMIN_USER="${DBADMIN_USER:-dbadmin}"
DBADMIN_PW="${DBADMIN_PW:-Admin@123}"
MYSQL_REPO_RPM="mysql80-community-release-el9-1.noarch.rpm"
MYSQL_REPO_URL="https://dev.mysql.com/get/${MYSQL_REPO_RPM}"
MYSQL_GPG_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
BIND_ADDR="0.0.0.0"
TMP_DIR="/tmp"
RPM_PATH="${TMP_DIR}/${MYSQL_REPO_RPM}"
# --------------------------------------------------------

log(){ echo "==> $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  err "Please run with sudo or as root: sudo bash $0"
fi

log "Ensuring curl is present"
if ! command -v curl >/dev/null 2>&1; then
  dnf install -y curl
fi

log "Downloading repo RPM to ${RPM_PATH} (will re-download if missing or size suspicious)"
# download with -f (fail on http error) and -L (follow redirects)
curl -fL --retry 3 --retry-delay 2 -o "${RPM_PATH}.partial" "${MYSQL_REPO_URL}" || {
  rm -f "${RPM_PATH}.partial"
  err "Failed to download ${MYSQL_REPO_URL}. Check network or URL."
}
mv -f "${RPM_PATH}.partial" "${RPM_PATH}"
chmod 0644 "${RPM_PATH}"

# quick sanity check: file size > 4 KB
if [[ ! -s "${RPM_PATH}" || $(stat -c%s "${RPM_PATH}") -lt 4096 ]]; then
  err "Downloaded RPM looks too small or empty: ${RPM_PATH}"
fi

log "Importing GPG key"
rpm --import "${MYSQL_GPG_KEY_URL}" || log "Warning: rpm --import failed (maybe already imported)."

log "Installing repo rpm package from absolute path: ${RPM_PATH}"
dnf install -y "${RPM_PATH}"

log "Installing mysql client & server packages"
dnf install -y mysql-community-client mysql-community-server

log "Starting & enabling mysqld"
systemctl daemon-reload || true
systemctl start mysqld
systemctl enable mysqld
if ! systemctl is-active --quiet mysqld; then
  journalctl -u mysqld -n 50 --no-pager
  err "mysqld did not start successfully; check journalctl output above."
fi

log "Configuring bind-address in /etc/my.cnf (backup made)"
MYCNF="/etc/my.cnf"
if [[ -f "${MYCNF}" ]]; then
  cp -a "${MYCNF}" "${MYCNF}.bak.$(date +%s)"
else
  touch "${MYCNF}"
  cp -a "${MYCNF}" "${MYCNF}.bak.$(date +%s)"
fi

# remove any existing bind-address in [mysqld] and add correct line
awk -v addr="${BIND_ADDR}" '
  BEGIN{inmysqld=0}
  /^\[mysqld\]/{print; inmysqld=1; next}
  /^\[/{ if(inmysqld){ print "bind-address = " addr; inmysqld=0 } print; next}
  { if(inmysqld && $1=="bind-address") next; print }
  END{ if(inmysqld){ print "bind-address = " addr } }
' "${MYCNF}.bak.$(date +%s)" > "${MYCNF}.new" || true
mv -f "${MYCNF}.new" "${MYCNF}"
chmod 0644 "${MYCNF}"

log "Restarting mysqld to apply bind-address"
systemctl restart mysqld
sleep 2
if ! systemctl is-active --quiet mysqld; then
  journalctl -u mysqld -n 80 --no-pager
  err "mysqld failed to restart after changing ${MYCNF}"
fi

# find temporary root password if present
TMP_PW=""
if grep -i 'temporary password' /var/log/mysqld.log >/dev/null 2>&1; then
  TMP_PW="$(grep -i 'temporary password' /var/log/mysqld.log | tail -n1 | awk '{print $NF}')"
  log "Detected temporary MySQL root password in /var/log/mysqld.log"
fi

# try to set root password
log "Setting root password (non-interactive where possible)"
if mysql -u root -p"${ROOT_PW}" -e "SELECT 1" >/dev/null 2>&1; then
  log "Root already has the desired password; skipping password set."
else
  if [[ -n "${TMP_PW}" ]]; then
    log "Altering root using temporary password"
    mysql --connect-expired-password -u root -p"${TMP_PW}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';" || log "Failed to change root with temporary pw; continuing"
  else
    # try unix_socket login (some distros allow local socket)
    if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
      mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';"
    else
      log "No temporary pw and cannot connect as root without password. You may need to run 'sudo grep \"temporary password\" /var/log/mysqld.log' and set root password manually."
    fi
  fi
fi

# secure steps
log "Running basic secure steps (remove anonymous, drop test database)"
mysql -u root -p"${ROOT_PW}" -e "DELETE FROM mysql.user WHERE User='' OR User IS NULL; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\\_%'; FLUSH PRIVILEGES;" || log "Secure steps may have failed; check root credentials."

# create dbadmin user
log "Creating/altering ${DBADMIN_USER}@'%' and granting privileges"
mysql -u root -p"${ROOT_PW}" -e "CREATE USER IF NOT EXISTS '${DBADMIN_USER}'@'%' IDENTIFIED BY '${DBADMIN_PW}'; ALTER USER '${DBADMIN_USER}'@'%' IDENTIFIED BY '${DBADMIN_PW}'; GRANT ALL PRIVILEGES ON *.* TO '${DBADMIN_USER}'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" || err "Failed to create ${DBADMIN_USER}"

log "Final checks:"
mysql -u root -p"${ROOT_PW}" -e "SELECT VERSION();" || true
mysql -u root -p"${ROOT_PW}" -e "SELECT User,Host FROM mysql.user WHERE User IN ('root','${DBADMIN_USER}');" || true

echo
echo "=== Done ==="
echo "- If you still get RPM open errors, remove /tmp/${MYSQL_REPO_RPM} and re-run the script to force fresh download."
echo "- Run this script with: sudo bash setup-mysql-el9-fixed.sh"
exit 0
