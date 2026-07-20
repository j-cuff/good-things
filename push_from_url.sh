#!/bin/bash
# download and push bundles
# Usage: ./push-bundles.sh <bundle-dir> <ecr-account-id> <region> <base-path>
# Example: ./push-bundles.sh ./bundles 103448924380 us-gov-west-1 cuff-airgap/spectro-packs
# Build a bundle, copy urls to file, then download and push to ECR using this script.
set -uo pipefail
source ./common-config.sh
source ./common-functions.sh

ECR_PACK_BASE="spectro-packs"
validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY
validateVar DOWNLOAD_USER
validateVar DOWNLOAD_PASS

export BUNDLE_DIR="${1:?Usage: $0 <bundle-dir>}" || echo "Bundle Directory: ${BUNDLE_DIR}"
export BUNDLE_URL_FILE="zst_urls.txt" || echo "Bundle URL File: ${BUNDLE_URL_FILE}"
#check for urls.txt file validation
export BASE_PATH="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_PACK_BASE#/}" || echo "Base Content Path: ${BASE_PATH}"


echo "==> Downloading all .zst bundles from ${BUNDLE_URL_FILE} to ${BUNDLE_DIR}"

if [[ ! -f "$BUNDLE_URL_FILE" ]]; then
  echo "Error: File '$BUNDLE_URL_FILE' not found."
  exit 1
fi

echo "Reading URLs from: $BUNDLE_URL_FILE"
echo ""

while IFS= read -r url; do
  # Skip empty lines and lines starting with #
  [[ -z "$url" || "$url" == \#* ]] && continue

  filename="${url##*/}"
  mkdir -p "${BUNDLE_DIR}/downloads"
  dest="${BUNDLE_DIR}/downloads/${filename}"

  # ── Skip if file already exists ──────────────────────────────────────────────
  if [[ -f "$dest" ]]; then
    echo "SKIP  $filename (already exists) in ${BUNDLE_DIR})"
    echo ""
    continue
  fi

  echo "Downloading: $filename"
  echo "  From: $url"
  echo "  To:   $dest"
  curl -L -u "${DOWNLOAD_USER}:${DOWNLOAD_PASS}" -o "$dest" "$url"
  echo ""
done < "$BUNDLE_URL_FILE"

echo "All downloads complete!"

echo "Validating downloaded files in ${BUNDLE_DIR}..."
PUBLIC_KEY_PATH="${BUNDLE_DIR}/downloads/${PUBLIC_KEY}"
if [[ ! -f "${PUBLIC_KEY_PATH}" ]]; then
  echo "Public key not found. Downloading..."
  curl -fL "$PUBLIC_KEY_URL" -o "${PUBLIC_KEY_PATH}"

  if [[ ! -f "${PUBLIC_KEY_PATH}" ]]; then
    echo "Error: Failed to download '${PUBLIC_KEY}'. Cannot verify signatures."
    exit 1
  fi

  chmod 644 "${PUBLIC_KEY_PATH}"

  echo "Public key saved: ${PUBLIC_KEY_PATH}"
else
  echo "Public key already exists: ${PUBLIC_KEY_PATH}"
fi

echo ""

echo "Verifying signatures..."
echo ""

passed=0
failed=0

while IFS= read -r url; do
  [[ -z "$url" || "$url" == \#* ]] && continue

  filename="${url##*/}"

  # Only process .zst files; find the matching .sig.bin
  if [[ "$filename" == *.zst ]]; then
    sigfile="${filename%.zst}.sig.bin"

    if [[ ! -f "$filename" ]]; then
      echo "SKIP  $filename (file not found locally)"
      continue
    fi

    if [[ ! -f "$sigfile" ]]; then
      echo "SKIP  $filename (sig file '$sigfile' not found)"
      continue
    fi

    result=$(openssl dgst -sha256 -verify "${BUNDLE_DIR}/downloads/${PUBLIC_KEY}" -signature "$sigfile" "$filename" 2>&1)

    if [[ "$result" == "Verified OK" ]]; then
      echo "OK    $filename"
      passed=$((passed + 1))
      
    else
      echo "FAIL  $filename  ($result)"
      failed=$((failed + 1))
    fi
  fi
done < "$BUNDLE_URL_FILE"

echo ""
echo "Results: $passed passed, $failed failed"
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
unset BUNDLE_DIR
unset BUNDLE_URL_FILE
unset BASE_PATH