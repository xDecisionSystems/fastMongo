#!/bin/bash
set -e

# Set variables here
API_VERSION="v1.0"
MONGO_VERSION="v1.0"
API_REPO="adclab/fastmongo-api"
MONGO_REPO="adclab/fastmongo-mongo"

build_and_push() {
  local repo="$1"
  local version="$2"
  local context="$3"

  docker build \
    -t "${repo}:${version}" \
    -t "${repo}:latest" \
    "${context}"

  docker push "${repo}:${version}"
  docker push "${repo}:latest"
}

# Build and push both images
build_and_push "${API_REPO}" "${API_VERSION}" "./api"
build_and_push "${MONGO_REPO}" "${MONGO_VERSION}" "./mongo"
