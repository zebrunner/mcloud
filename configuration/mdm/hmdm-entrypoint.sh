#!/bin/sh
# A copy of android/hmdm-entrypoint.sh of zebrunner/mcloud-mdm (change it there first), README.md#mdm.
# The entrypoint of Headwind MDM (headwindmdm/hmdm) for mcloud-mdm (README.md#android of zebrunner/mcloud-mdm): writes the context of the web
# application at every start, then runs the entrypoint of the image (it keeps an existing context):
# - base.url is HMDM_PUBLIC_URL: the https URL of the proxy (TLS is terminated there, Headwind MDM serves plain http)
# - secure.enrollment=1: the agents sign their requests with SHARED_SECRET, nobody else enrolls or reads a configuration
# Mount it and set it as the entrypoint: entrypoint: ["/bin/sh", "/hmdm-entrypoint.sh"]. The values must not contain |.
set -eu

: "${HMDM_PUBLIC_URL:?the public URL of Headwind MDM the agents reach, e.g. https://demo-mdm.zebrunner.farm}"
: "${SHARED_SECRET:?the shared secret of the agents}"
: "${SQL_PASS:?the password of the database}"
template=/opt/hmdm/templates/conf/context_template.xml
context=/usr/local/tomcat/conf/Catalina/localhost

mkdir -p "$context"
sed -e "s|_SQL_HOST_|${SQL_HOST}|g; s|_SQL_PORT_|${SQL_PORT:-5432}|g; s|_SQL_BASE_|${SQL_BASE}|g" \
  -e "s|_SQL_USER_|${SQL_USER}|g; s|_SQL_PASS_|${SQL_PASS}|g; s|_SHARED_SECRET_|${SHARED_SECRET}|g" \
  -e "s|_PROTOCOL_://_BASE_DOMAIN_|${HMDM_PUBLIC_URL%/}|g" \
  -e 's|name="secure.enrollment" *value="0"|name="secure.enrollment" value="1"|' \
  "$template" > "${context}/ROOT.xml.new"
grep -q 'name="secure.enrollment" value="1"' "${context}/ROOT.xml.new" || {
  echo "hmdm-entrypoint: secure.enrollment is not in ${template}" >&2
  exit 1
}
mv "${context}/ROOT.xml.new" "${context}/ROOT.xml"
echo "hmdm-entrypoint: base.url ${HMDM_PUBLIC_URL%/}, secure.enrollment on"
exec /docker-entrypoint.sh
