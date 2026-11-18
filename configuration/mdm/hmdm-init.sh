#!/bin/sh
# A copy of android/hmdm-init.sh of zebrunner/mcloud-mdm (change it there first), README.md#mdm.
# Sets the password of the admin of Headwind MDM to HMDM_PASSWORD and clears the reset Headwind MDM asks for at its
# first start, so mcloud-mdm logs in (README.md#android of zebrunner/mcloud-mdm). A one-shot service on the postgres image (psql, md5sum,
# sha1sum), next to the postgres of Headwind MDM: PGHOST, PGUSER, PGPASSWORD, PGDATABASE, HMDM_LOGIN, HMDM_PASSWORD.
# With HMDM_PUBLIC_URL, the URLs of the files of the applications (written with the internal http URL at the first
# start) point to it. With HMDM_INTERNAL_URL (http://<hmdm>:8080) it waits for the web application of Headwind MDM:
# its first start runs its init.sql (the admin with a pending reset, the files) after the tables exist.
set -eu

: "${HMDM_PASSWORD:?the password of the admin of Headwind MDM}"
login="${HMDM_LOGIN:-admin}"
# the salt of PasswordUtil of Headwind MDM: the stored hash is SHA1(MD5 in upper case hex + salt)
salt=5YdSYHyg2U

md5="$(printf '%s' "$HMDM_PASSWORD" | md5sum | cut -d' ' -f1 | tr 'a-f' 'A-F')"
hash="$(printf '%s%s' "$md5" "$salt" | sha1sum | cut -d' ' -f1)"

# Headwind MDM creates its tables and its admin at its first start
tries=0
until psql -qtAc "select 1 from users where login = '${login}'" 2> /dev/null | grep -q 1; do
  tries=$((tries + 1))
  if test "$tries" -gt 120; then
    echo "hmdm-init: no user ${login} in Headwind MDM after 10 minutes" >&2
    exit 1
  fi
  sleep 5
done
if test -n "${HMDM_INTERNAL_URL:-}"; then
  tries=0
  until wget -q -O /dev/null "${HMDM_INTERNAL_URL%/}/" 2> /dev/null; do
    tries=$((tries + 1))
    if test "$tries" -gt 120; then
      echo "hmdm-init: ${HMDM_INTERNAL_URL} does not answer after 10 minutes" >&2
      exit 1
    fi
    sleep 5
  done
fi

# apply: the password (the login refuses the user with a pending reset; a new authtoken invalidates the old sessions)
# and the public URLs of the files
apply() {
  psql -qtA -v ON_ERROR_STOP=1 -v hash="$hash" -v login="$login" << 'SQL'
update users set password = :'hash', passwordreset = false, passwordresettoken = null, authtoken = null
  where login = :'login' and (password <> :'hash' or passwordreset);
SQL
  if test -n "${HMDM_PUBLIC_URL:-}"; then
    psql -qtA -v ON_ERROR_STOP=1 -v base="${HMDM_PUBLIC_URL%/}" << 'SQL'
update applicationversions set url = regexp_replace(url, '^https?://[^/]+', :'base')
  where url ~ '^https?://[^/]+/files/' and url not like :'base' || '/%';
SQL
  fi
}
apply
echo "hmdm-init: the password of ${login} is HMDM_PASSWORD${HMDM_PUBLIC_URL:+, the files of the applications are on ${HMDM_PUBLIC_URL%/}}"

# the init.sql of a first start may still come: the reset is applied again for a minute
checks=0
while test "$checks" -lt 12; do
  checks=$((checks + 1))
  sleep 5
  if psql -qtAc "select 1 from users where login = '${login}' and (passwordreset or password <> '${hash}')" | grep -q 1; then
    apply
    echo "hmdm-init: the reset of the first start came after the password: applied again"
  fi
done
