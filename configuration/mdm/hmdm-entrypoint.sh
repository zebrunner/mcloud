#!/bin/sh
# A copy of android/hmdm-entrypoint.sh of zebrunner/mcloud-mdm (change it there first), README.md#mdm.
# The entrypoint of Headwind MDM (headwindmdm/hmdm) for mcloud-mdm (README.md#android of zebrunner/mcloud-mdm): writes the context of the web
# application at every start, then runs the entrypoint of the image (it keeps an existing context):
# - base.url is HMDM_PUBLIC_URL: the https URL of the proxy (TLS is terminated there, Headwind MDM serves plain http)
# - secure.enrollment=1: the agents sign their requests with SHARED_SECRET, nobody else enrolls or reads a configuration
# - mqtt.auth=1 with mqtt.admin.password=HMDM_MQTT_ADMIN_PASSWORD: the MQTT broker of Headwind MDM has two users, the
#   agents (hmdm, a password derived from SHARED_SECRET: they read their pushes) and admin (Headwind MDM itself: it
#   publishes them); without the parameter the admin password is the default one built into Headwind MDM, the same in
#   every installation, and whoever reaches the broker could publish pushes (commands) to every agent
# Mount it and set it as the entrypoint: entrypoint: ["/bin/sh", "/hmdm-entrypoint.sh"]. The values must not contain |.
set -eu

: "${HMDM_PUBLIC_URL:?the public URL of Headwind MDM the agents reach, e.g. https://demo-mdm.zebrunner.farm}"
: "${SHARED_SECRET:?the shared secret of the agents}"
: "${SQL_PASS:?the password of the database}"
: "${HMDM_MQTT_ADMIN_PASSWORD:?the password of the admin of the MQTT broker of Headwind MDM, 16+ letters and digits}"
# the paths of the image; the tests of zebrunner/mcloud-mdm (internal/headwind/entrypoint_test.go) set their own
template="${HMDM_ENTRYPOINT_TEMPLATE:-/opt/hmdm/templates/conf/context_template.xml}"
context="${HMDM_ENTRYPOINT_CONTEXT:-/usr/local/tomcat/conf/Catalina/localhost}"

# letters and digits only: it goes into an XML attribute and a sed replacement
case "$HMDM_MQTT_ADMIN_PASSWORD" in
*[!A-Za-z0-9]*)
  echo "hmdm-entrypoint: HMDM_MQTT_ADMIN_PASSWORD has characters other than letters and digits" >&2
  exit 1
  ;;
esac
if test "${#HMDM_MQTT_ADMIN_PASSWORD}" -lt 16; then
  echo "hmdm-entrypoint: HMDM_MQTT_ADMIN_PASSWORD is shorter than 16 characters" >&2
  exit 1
fi

mkdir -p "$context"
sed -e "s|_SQL_HOST_|${SQL_HOST}|g; s|_SQL_PORT_|${SQL_PORT:-5432}|g; s|_SQL_BASE_|${SQL_BASE}|g" \
  -e "s|_SQL_USER_|${SQL_USER}|g; s|_SQL_PASS_|${SQL_PASS}|g; s|_SHARED_SECRET_|${SHARED_SECRET}|g" \
  -e "s|_PROTOCOL_://_BASE_DOMAIN_|${HMDM_PUBLIC_URL%/}|g" \
  -e 's|name="secure.enrollment" *value="0"|name="secure.enrollment" value="1"|' \
  -e '/name="mqtt.admin.password"/d' \
  -e "s|<Parameter  *name=\"mqtt.auth\"  *value=\"[^\"]*\" */>|<Parameter name=\"mqtt.auth\" value=\"1\"/><Parameter name=\"mqtt.admin.password\" value=\"${HMDM_MQTT_ADMIN_PASSWORD}\"/>|" \
  "$template" > "${context}/ROOT.xml.new"
grep -q 'name="secure.enrollment" value="1"' "${context}/ROOT.xml.new" || {
  echo "hmdm-entrypoint: secure.enrollment is not in ${template}" >&2
  exit 1
}
# fail closed: no context with the default admin password of the broker
grep -q "name=\"mqtt.auth\" value=\"1\"/><Parameter name=\"mqtt.admin.password\" value=\"${HMDM_MQTT_ADMIN_PASSWORD}\"" \
  "${context}/ROOT.xml.new" || {
  echo "hmdm-entrypoint: mqtt.auth is not in ${template}, the MQTT broker would keep its default admin password" >&2
  exit 1
}
mv "${context}/ROOT.xml.new" "${context}/ROOT.xml"
echo "hmdm-entrypoint: base.url ${HMDM_PUBLIC_URL%/}, secure.enrollment on, MQTT authentication on with its own admin password"
exec "${HMDM_ENTRYPOINT_NEXT:-/docker-entrypoint.sh}"
