#! /bin/bash
# Usage: ./push2ecr.sh <version>
# Example: ./push2ecr.sh 4.9.18
set -euo pipefail
source ./common-config.sh
source ./common-functions.sh
validateVar VERTEX_VERSION
touch push2ecr-$VERTEX_VERSION.log
exec > >(tee -a push2ecr-$VERTEX_VERSION.log) 2>&1
date

#Step 1: Validate Variables
###########################
print_boxed "Step #1: Validating Variables needed for this script"
validateVar VERTEX_VERSION
validateVar AWS_ACCOUNT
validateVar AWS_REGION
validateVar ECR_BASE_CONTENT_PATH warn || true
validateVar ECR_IMAGE_BASE warn || true
validateVar ECR_PACK_BASE warn || true
validateVar ECR_REGISTRY
validateVar DOWNLOAD_USER warn || true
validateVar DOWNLOAD_PASS warn || true
validateVar SCRIPT_DIR
validateVar AIRGAP_DIR
validateVar BINARY


#Step 2: Authenticate to ECR
############################
print_boxed "Step #2: Authenticating ORAS and Docker to ECR"
ecrLogin
#aws ecr get-login-password --region $AWS_REGION | oras login --username AWS --password-stdin $ECR_REGISTRY
#aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY


#Step 3: Setup Env and extract the binary
#########################################

print_boxed "Step #3: Extracting the binary and setting up env vars"
# exporting variables for the binary to use
export ECR_IMAGE_REGISTRY=${ECR_REGISTRY}
export ECR_IMAGE_BASE="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_IMAGE_BASE#/}"
export ECR_IMAGE_REGISTRY_REGION=${AWS_REGION}
export ECR_PACK_REGISTRY=${ECR_REGISTRY}
export ECR_PACK_BASE="${ECR_BASE_CONTENT_PATH:+${ECR_BASE_CONTENT_PATH%/}/}${ECR_PACK_BASE#/}"
export ECR_PACK_REGISTRY_REGION=${AWS_REGION}
export SCRIPT_DIR="${SCRIPT_DIR}"
export AIRGAP_DIR="${AIRGAP_DIR}"
export BINARY="./airgap-vertex-v${VERTEX_VERSION}.bin"
echo "ECR configuration:"
echo "  ECR_IMAGE_REGISTRY=${ECR_IMAGE_REGISTRY}"
echo "  ECR_IMAGE_BASE=${ECR_IMAGE_BASE}"
echo "  ECR_IMAGE_REGISTRY_REGION=${ECR_IMAGE_REGISTRY_REGION}"
echo "  ECR_PACK_REGISTRY=${ECR_PACK_REGISTRY}"
echo "  ECR_PACK_BASE=${ECR_PACK_BASE}"
echo "  ECR_PACK_REGISTRY_REGION=${ECR_PACK_REGISTRY_REGION}"

ensureVertexBinary "$VERTEX_VERSION"

# Checking for the binary and extracting it if needed
if [[ "${SKIP_EXTRACTION}" == "false" ]]; then
  if [[ ! -f "${BINARY}" ]]; then
    fail "Binary not found: ${BINARY}"
  fi

extract_binary "${BINARY}" "${AIRGAP_DIR}"

else
  echo "Skipping binary extraction."

  if [[ ! -d "${AIRGAP_DIR}" ]]; then
    fail "Airgap directory not found: ${AIRGAP_DIR}. Cannot use --skip-extraction unless it already exists."
  fi
fi


if [ ! -x "$BINARY" ]; then
  echo "Binary is not executable. Fixing..."
  chmod +x "$BINARY"
fi

patch_functions_file "${AIRGAP_DIR}"

echo "Starting airgap push for version: ${VERTEX_VERSION}"
echo "Binary: ${BINARY}"
echo "Registry: ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_BASE_CONTENT_PATH}"
echo ""

# --- Run the binary, capture output, auto-create any missing repos, retry ---
pushd "${AIRGAP_DIR}" >/dev/null

run_apply_script_with_repo_retry "apply_pack.sh"
run_apply_script_with_repo_retry "apply_patch.sh"

popd >/dev/null

if [[ "${SKIP_EXTRACTION}" == "false" ]]; then
  echo "Removing extracted directory: ${AIRGAP_DIR}"
  rm -rf "${AIRGAP_DIR}"
else
  echo "Preserving extracted directory because --skip-extraction was used: ${AIRGAP_DIR}"
fi

echo "Airgap push completed successfully."


# while true; do
#   tmp_output="$(mktemp)"

#   set +e
#   "$BINARY" 2>&1 | tee "$tmp_output" >&2
#   binary_status="${PIPESTATUS[0]}"
#   set -e

#   OUTPUT="$(cat "$tmp_output")"
#   rm -f "$tmp_output"

#   MISSING_REPOS="$(extract_missing_repos "$OUTPUT")"

#   if [[ -z "$MISSING_REPOS" ]]; then
#     if [[ "$binary_status" -eq 0 ]]; then
#       echo ""
#       echo "Done — no more missing repos."
#       break
#     else
#       echo ""
#       echo "Binary failed, but no missing ECR repos were detected in the output." >&2
#       exit "$binary_status"
#     fi
#   fi

#   echo ""
#   echo "Auto-creating missing repos..."

#   while IFS= read -r repo; do
#     echo "$repo"
#     [[ -z "$repo" ]] && continue
#     create_ecr_repo "$repo"
#   done <<< "$MISSING_REPOS"

#   echo ""
#   echo "Retrying binary..."
# done

# while true; do
#   OUTPUT=$("$BINARY" 2>&1 | tee /dev/stderr)

#   # Check for missing repo errors
#   MISSING=$(echo "$OUTPUT" | grep -oP "(?<=archive/)[^']+(?= does not exist)" | sort -u)

#   if [ -z "$MISSING" ]; then
#     echo ""
#     echo "Done — no more missing repos."
#     break
#   fi

#   echo ""
#   echo "Auto-creating missing repos..."
#   while IFS= read -r PACK; do
#     echo "  Creating: ${ECR_BASE_CONTENT_PATH}/spectro-packs/archive/${PACK}"
#     aws ecr create-repository \
#       --repository-name "${ECR_BASE_CONTENT_PATH}/spectro-packs/archive/${PACK}" \
#       --region "${AWS_REGION}" 2>/dev/null \
#       && echo "    ✓ Created" || echo "    ↩ Already exists"
#   done <<< "$MISSING"

#   echo ""
#   echo "Retrying binary..."
# done

#IDEABOARD: 
# export cluster profile and create script to parse, download packs, and push to ECR.
# take copy all urls command from artifact studio, download packs and push to ECR.

