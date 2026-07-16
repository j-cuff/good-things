#!/bin/bash
# push-bundles.sh
# Usage: ./push-bundles.sh <bundle-dir> <ecr-account-id> <region> <base-path>
# Example: ./push-bundles.sh ./bundles 103448924380 us-gov-west-1 cuff-airgap/spectro-packs
# Build a bundle, copy urls to file, then download and push to ECR using this script.
set -euo pipefail
source ./common-config.sh
source ./common-functions.sh

validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY

BUNDLE_DIR="${1:?Usage: $0 <bundle-dir>}" || echo "Bundle Directory: ${BUNDLE_DIR}"
BASE_PATH="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_PACK_BASE#/}" || echo "Base Content Path: ${BASE_PATH}"

echo "==> Authenticating to ECR..."

palette content registry-login \
  --registry ${ECR_REGISTRY} \
  --username AWS \
  --password "$(aws ecr get-login-password \
  --region ${AWS_REGION})"

echo "==> Pushing all .zst bundles from ${BUNDLE_DIR} to ${ECR_REGISTRY}/${BASE_PATH}"

for bundle in "${BUNDLE_DIR}"/*.zst; do
  [[ -f "$bundle" ]] || { echo "No .zst files found in ${BUNDLE_DIR}"; exit 1; }
  echo "--> Pushing: ${bundle}"
  palette content push \
    --file "${bundle}" \
    --registry "${ECR_REGISTRY}/${BASE_PATH}" \
    --insecure
done

echo "==> All bundles pushed successfully."
