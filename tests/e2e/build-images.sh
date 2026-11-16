#!/bin/bash
# tests/e2e/build-images.sh <dir>: the images of the farm with an Android device of the branches of their repositories
# cloned into <dir>, tagged as mcloud (.env.original) and mcloud-agent (versions.yml) use them.
# E2E_REF is the branch of every repository (develop), <REPOSITORY>_REF the one of a repository (e.g. STF_REF=fix/x,
# MCLOUD_AGENT_REF=feat/y), also as the words of E2E_REFS ("STF_REF=fix/x MCLOUD_AGENT_REF=feat/y"); mcloud is this
# checkout. A repository on develop gives the image its CI published for the commit (<VERSION>-develop-<sha>) or, while
# the CI of the commit still runs, the one of the commit before (<VERSION>-develop-latest); the other branches are
# built. The uploader is pulled: artifacts-uploader is private.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:?usage: tests/e2e/build-images.sh <dir>}"
mkdir -p "$DIR"

# log <message>: a line of the build in the output of the job
log() {
  echo "[e2e] $*"
}

# ref <repository>: the branch of a repository, <REPOSITORY>_REF of E2E_REFS or of the environment, E2E_REF or develop
ref() {
  local var
  local word
  local words
  var="$(echo "$1" | tr 'a-z-' 'A-Z_')_REF"
  read -ra words <<< "${E2E_REFS:-}"
  for word in "${words[@]}"; do
    if [[ "$word" == "${var}="* ]]; then
      echo "${word#*=}"
      return
    fi
  done
  if [[ -n "${!var:-}" ]]; then
    echo "${!var}"
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

# build <repository> <tag>: make build of the repository, once more after a failure (the downloads of the builds)
build() {
  make -C "${DIR}/$1" build VERSION="$2" || {
    log "$1: the build failed, once more"
    make -C "${DIR}/$1" build VERSION="$2"
  }
}

# image <repository> <tag>: the image of the repository tagged <tag>, the published one of develop when it is on
# develop, built otherwise; BUILT is true when it was built
image() {
  local published
  local sha
  local version
  BUILT=true
  if [[ "$(ref "$1")" == develop ]]; then
    sha="$(git -C "${DIR}/$1" rev-parse HEAD | cut -c 1-7)"
    version="$(tr -d '[:space:]' < "${DIR}/$1/VERSION")"
    for published in "${version}-develop-${sha}" "${version}-develop-latest"; do
      published="public.ecr.aws/zebrunner/$1:${published}"
      if docker pull --quiet "$published" > /dev/null 2>&1; then
        docker tag "$published" "public.ecr.aws/zebrunner/$1:$2"
        if [[ "$published" == *-latest ]]; then
          log "$1:$2 is ${published}: ${sha} of develop is not published yet, an earlier commit"
        else
          log "$1:$2 is ${published}"
        fi
        BUILT=false
        return
      fi
    done
    log "$1: develop is not published"
  fi
  log "$1:$2 is built"
  build "$1" "$2"
}

# mcloud_tag <variable>: a tag of .env.original of mcloud
mcloud_tag() {
  sed -n "s/^$1=//p" "${REPO}/.env.original"
}

# agent_tag <variable>: a version of versions.yml of mcloud-agent
agent_tag() {
  sed -n "s/^$1: *//p" "${DIR}/mcloud-agent/versions.yml"
}

for repository in stf mcloud-grid mcloud-device appium mcloud-android-connector mcloud-agent; do
  clone "$repository"
done

stf_tag="$(mcloud_tag TAG_STF)"
image stf "$stf_tag"
stf_built="$BUILT"
image mcloud-grid "$(mcloud_tag TAG_SELENIUM_HUB)"

# a build of mcloud-device is on the stf image above: its FROM (a published tag, maybe pinned by digest) is replaced;
# the published mcloud-device of develop is on the stf of develop, so it is built when stf is
sed -i.bak -E "s#^FROM public\.ecr\.aws/zebrunner/stf:[^ ]+#FROM public.ecr.aws/zebrunner/stf:${stf_tag}#" \
  "${DIR}/mcloud-device/Dockerfile"
if [[ "$stf_built" == true ]]; then
  log "mcloud-device:$(agent_tag DEVICE_VERSION) is built on the built stf"
  build mcloud-device "$(agent_tag DEVICE_VERSION)"
else
  image mcloud-device "$(agent_tag DEVICE_VERSION)"
fi
image appium "$(agent_tag APPIUM_VERSION)"
image mcloud-android-connector "$(agent_tag ANDROID_CONNECTOR_VERSION)"
log "uploader:$(agent_tag UPLOADER_VERSION)"
docker pull --quiet "public.ecr.aws/zebrunner/uploader:$(agent_tag UPLOADER_VERSION)"

docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^public.ecr.aws/zebrunner/'
