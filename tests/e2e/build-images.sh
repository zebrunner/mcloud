#!/bin/bash
# tests/e2e/build-images.sh <dir>: the images of the farm built from the branches of their repositories into <dir>,
# tagged as mcloud (.env.original) and mcloud-agent (defaults/main.yml) use them, so nothing is pulled from
# public.ecr.aws. E2E_REF is the branch of every repository (develop, artifacts-uploader: master), <REPOSITORY>_REF
# the one of a repository (e.g. STF_REF=fix/x, MCLOUD_AGENT_REF=feat/y); mcloud is this checkout.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:?usage: tests/e2e/build-images.sh <dir>}"
mkdir -p "$DIR"

# log <message>: a line of the build in the output of the job
log() {
  echo "[e2e] $*"
}

# ref <repository>: the branch of a repository, <REPOSITORY>_REF, E2E_REF or its default branch
ref() {
  local var
  var="$(echo "$1" | tr 'a-z-' 'A-Z_')_REF"
  if [[ -n "${!var:-}" ]]; then
    echo "${!var}"
  elif [[ "$1" == "artifacts-uploader" ]]; then
    echo "master"
  else
    echo "${E2E_REF:-develop}"
  fi
}

# clone <repository>: a shallow clone of its branch into <dir>/<repository>
clone() {
  rm -rf "${DIR:?}/$1"
  git clone --quiet --depth 1 --branch "$(ref "$1")" "https://github.com/zebrunner/$1.git" "${DIR}/$1"
  log "$1 $(ref "$1") $(git -C "${DIR}/$1" rev-parse --short HEAD)"
}

# mcloud_tag <variable>: a tag of .env.original of mcloud
mcloud_tag() {
  sed -n "s/^$1=//p" "${REPO}/.env.original"
}

# agent_tag <variable>: a version of defaults/main.yml of mcloud-agent
agent_tag() {
  sed -n "s/^$1: *//p" "${DIR}/mcloud-agent/defaults/main.yml"
}

for repository in stf mcloud-grid mcloud-device appium mcloud-ios-connector mcloud-android-connector mcloud-agent \
  artifacts-uploader; do
  clone "$repository"
done

stf_tag="$(mcloud_tag TAG_STF)"
log "stf:${stf_tag}"
make -C "${DIR}/stf" build VERSION="$stf_tag"
log "mcloud-grid:$(mcloud_tag TAG_SELENIUM_HUB)"
make -C "${DIR}/mcloud-grid" build VERSION="$(mcloud_tag TAG_SELENIUM_HUB)"

# mcloud-device is built on the stf image above: its FROM (a published tag, maybe pinned by digest) is replaced
sed -i.bak -E "s#^FROM public\.ecr\.aws/zebrunner/stf:[^ ]+#FROM public.ecr.aws/zebrunner/stf:${stf_tag}#" \
  "${DIR}/mcloud-device/Dockerfile"
log "mcloud-device:$(agent_tag DEVICE_VERSION)"
make -C "${DIR}/mcloud-device" build VERSION="$(agent_tag DEVICE_VERSION)"
log "appium:$(agent_tag APPIUM_VERSION)"
make -C "${DIR}/appium" build VERSION="$(agent_tag APPIUM_VERSION)"
log "mcloud-ios-connector:$(agent_tag IOS_CONNECTOR_VERSION)"
make -C "${DIR}/mcloud-ios-connector" build VERSION="$(agent_tag IOS_CONNECTOR_VERSION)"
log "mcloud-android-connector:$(agent_tag ANDROID_CONNECTOR_VERSION)"
make -C "${DIR}/mcloud-android-connector" build VERSION="$(agent_tag ANDROID_CONNECTOR_VERSION)"
log "uploader:$(agent_tag UPLOADER_VERSION)"
docker build --quiet --provenance=false -f "${DIR}/artifacts-uploader/linux/Dockerfile" \
  -t "public.ecr.aws/zebrunner/uploader:$(agent_tag UPLOADER_VERSION)" "${DIR}/artifacts-uploader"

docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^public.ecr.aws/zebrunner/'
