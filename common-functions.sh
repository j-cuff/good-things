#!/bin/bash
#######################################################################################
# Script Name: common-functions.sh
# Description:
# Author: Jason Cuff
#######################################################################################

validateVar() {
  # Usage:
  #   validateVar <variablename>             # exits on missing var
  #   validateVar <variablename> fatal       # exits on missing var
  #   validateVar <variablename> warn        # continues on missing var

  local var_name="${1:-}"
  local mode="${2:-fatal}"
  local value="${!var_name:-}"

  if [[ -z "$var_name" ]]; then
    echo "❌ Error: validateVar requires a variable name" >&2
    [[ "$mode" == "fatal" ]] && exit 1
    return 1
  fi

  if [[ -z "$value" ]]; then
    echo "❌ Error: variable '$var_name' is not set or is empty" >&2

    if [[ "$mode" == "fatal" ]]; then
      exit 1
    else
      return 1
    fi
  else
    echo "✅ $var_name: $value"
    return 0
  fi
}
# function validateVar () { #Usage: validateVar <variablename>
#   local var_name="$1"
#   local value="${!var_name}"
#   if [[ -z "$value" ]]; then
#     echo "❌ Error: variable '$var_name' is not set or is empty" >&2
#     exit 1
#   else
#     echo "✅ $var_name: $value"
#   fi
# }

function print_boxed () { #Usage: print_boxed <message>
  local message="$1"
  local len=${#message}
  local border
  border=$(printf '%*s' $((len + 4)) '' | tr ' ' '#')
  echo -e "\n$border"
  echo -e "# $message #"
  echo -e "$border\n"
}

function warn() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${msg}"
}

function fail() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${msg}"
  exit 1
}

function extract_binary() {
  local binary="$1"
  local airgap_dir="$2"

  if [[ -d "${airgap_dir}" ]]; then
    fail "Extraction target already exists: ${airgap_dir}. Use --skip-extraction to reuse it, or remove it first."
  fi

  make_executable_if_needed "${binary}"

  echo "Extracting ${binary} to ${airgap_dir}"

  "${binary}" --noexec --target "${airgap_dir}"

  if [[ ! -d "${airgap_dir}" ]]; then
    fail "Extraction completed but expected directory was not created: ${airgap_dir}"
  fi

  echo "Extraction completed: ${airgap_dir}"
}

function make_executable_if_needed() {
  local file="$1"

  if [[ ! -f "${file}" ]]; then
    fail "Expected file not found: ${file}"
  fi

  if [[ ! -x "${file}" ]]; then
    echo "File is not executable. Running chmod +x: ${file}"
    chmod +x "${file}" || fail "Failed to chmod +x ${file}"
  fi
}

function patch_functions_file() {
  local airgap_dir="$1"
  local functions_file="${airgap_dir}/bin/functions.sh"

  if [[ ! -f "${functions_file}" ]]; then
    warn "functions.sh not found at ${functions_file}; skipping ecr-public -> ecr replacement."
    return
  fi

  if [[ ! -w "${functions_file}" ]]; then
    fail "functions.sh exists but is not writable: ${functions_file}"
  fi

  echo "Patching ${functions_file}: replacing ecr-public with ecr"
  sed -i "s/ecr-public/ecr/g" "${functions_file}"
}

function create_ecr_repo() {
  local repo_name="$1"

  repo_name="${repo_name#/}"
  repo_name="${repo_name%/}"

  echo "  Creating: ${repo_name}"

  if aws ecr describe-repositories \
    --repository-names "${repo_name}" \
    --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    ↩ Already exists"
    return 0
  fi

  aws ecr create-repository \
    --repository-name "${repo_name}" \
    --region "${AWS_REGION}" >/dev/null

  echo "    ✓ Created"
}

function extract_missing_repos() {
  local output="$1"

  {
    # Matches missing pack repos like:
    # spectro-packs/archive/generic-byoi does not exist
    printf '%s\n' "$output" |
      sed -nE "s#.*archive/([^'\"[:space:]]+) does not exist.*#${ECR_PACK_BASE%/}/archive/\1#p"

    # Matches missing image repos like:
    # spectro-images/some-image does not exist
    printf '%s\n' "$output" |
      sed -nE "s#.*spectro-images/([^'\"[:space:]]+) does not exist.*#${ECR_IMAGE_BASE%/}/\1#p"
  } | sed -E 's#@sha256:[a-fA-F0-9]+$##; s#:[^/]+$##' | sort -u
}

run_apply_script_with_repo_retry() {
  local script_path="$1"
  local script_name
  script_name="$(basename "${script_path}")"

  if [[ ! -f "${script_path}" ]]; then
    warn "${script_name} not found. Skipping."
    return
  fi

  make_executable_if_needed "${script_path}"

  local attempt=1
  local max_attempts=20

  while true; do
    echo "Running ${script_name}, attempt ${attempt}/${max_attempts}"

    local attempt_log
    attempt_log="$(mktemp "/tmp/${script_name}.attempt.${attempt}.XXXXXX.log")"

    set +e

    # Stream output live to screen and LOG_FILE, while also saving this attempt's output.
    "./${script_name}" 2>&1 | tee "${attempt_log}"

    local rc=${PIPESTATUS[0]}
    set -e

    if [[ ${rc} -eq 0 ]]; then
      echo "${script_name} completed successfully."
      rm -f "${attempt_log}"
      break
    fi

    warn "${script_name} exited with code ${rc}"

    local output
    output="$(cat "${attempt_log}")"

    if create_missing_pack_repos "${output}"; then
      rm -f "${attempt_log}"

      if [[ ${attempt} -ge ${max_attempts} ]]; then
        fail "${script_name} still failing after ${max_attempts} attempts."
      fi

      echo "Missing repos were created. Retrying ${script_name}."
      attempt=$((attempt + 1))
      continue
    fi

    cat "${attempt_log}"
    rm -f "${attempt_log}"

    fail "${script_name} failed and no missing repo pattern was detected."
  done
}

function download_file() { #1=version
  local version="$1"

  if [[ -z "$version" ]]; then
    echo "Usage: download_file <version>"
    return 1
  fi

  local username="spectro"
  local password=""
  local base_url="https://software-private.spectrocloud.com/airgap-vertex"
  local filename="airgap-vertex-v${version}.bin"
  local url="${base_url}/${version}/${filename}"

  curl -fL \
    --user "${username}:${password}" \
    --connect-timeout 10 \
    --retry 3 \
    --retry-delay 5 \
    -o "${filename}" \
    "${url}"
}

function ecrLogin() {
  # Usage: ecrLogin
  # Requires: AWS_REGION, ECR_REGISTRY

  validateVar AWS_REGION
  validateVar ECR_REGISTRY

  echo "Logging into ECR with oras: ${ECR_REGISTRY}"

  if ! aws ecr get-login-password --region "${AWS_REGION}" |
    oras login --username AWS --password-stdin "${ECR_REGISTRY}"; then
    echo "❌ Error: oras login failed for ${ECR_REGISTRY}" >&2
    exit 1
  fi

  echo "✅ oras login succeeded"

  echo "Logging into ECR with docker: ${ECR_REGISTRY}"

  if ! aws ecr get-login-password --region "${AWS_REGION}" |
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"; then
    echo "❌ Error: docker login failed for ${ECR_REGISTRY}" >&2
    exit 1
  fi

  echo "✅ docker login succeeded"
}
function ensureVertexBinary() {
  # Usage:
  #   ensureVertexBinary <version>
  #
  # Optional env vars:
  #   DOWNLOAD_BINARY=true    # skip prompt and download automatically
  #   DOWNLOAD_USER=spectro   # optional basic auth username
  #   DOWNLOAD_PASS=xxxxx     # optional basic auth password

  local version="${1:-${VERSION:-${VERTEX_VERSION:-}}}"

  if [[ -z "$version" ]]; then
    echo "❌ Error: version is required" >&2
    echo "Usage: ensureVertexBinary <version>" >&2
    exit 1
  fi

  local binary="./airgap-vertex-v${version}.bin"
  local base_url="https://software-private.spectrocloud.com/airgap-vertex"
  local filename="airgap-vertex-v${version}.bin"
  local url="${base_url}/${version}/${filename}"

  if [[ -f "$binary" ]]; then
    echo "✅ Binary found: ${binary}"

    if [[ ! -x "$binary" ]]; then
      echo "Binary is not executable. Fixing..."
      chmod +x "$binary"
    fi

    return 0
  fi

  echo "❌ Error: Binary not found: ${binary}" >&2
  echo "Download URL: ${url}"
  echo ""

  local answer=""

  if [[ "${DOWNLOAD_BINARY:-false}" == "true" ]]; then
    answer="y"
  else
    read -r -p "Would you like to download it now? [y/N]: " answer
  fi

  case "$answer" in
    y|Y|yes|YES)
      echo "Downloading ${filename}..."

      local curl_args=(
        -fL
        --connect-timeout 10
        --retry 3
        --retry-delay 5
        -o "$binary"
      )

      if [[ -n "${DOWNLOAD_USER:-}" && -n "${DOWNLOAD_PASS:-}" ]]; then
        curl_args+=(--user "${DOWNLOAD_USER}:${DOWNLOAD_PASS}")
      fi

      if ! curl "${curl_args[@]}" "$url"; then
        echo "❌ Error: failed to download binary from ${url}" >&2
        rm -f "$binary"
        exit 1
      fi

      chmod +x "$binary"
      echo "✅ Downloaded and made executable: ${binary}"
      ;;
    *)
      echo "❌ Binary is required. Exiting." >&2
      exit 1
      ;;
  esac
}

function executeCMDv2 () { #1=cmd, #2=message
  local cmd="$1"
  local message="${2:-Running command...}"
  local output
  local exit_code
  echo "▶️  $message"
  # capture both stdout and stderr
  if output=$(eval "$cmd" 2>&1); then
    exit_code=0
  else
    exit_code=$?
  fi
  if (( exit_code == 0 )); then
    echo "✅  $message Succeeded!"
  else
    echo "❌  $message Failed! (exit code $exit_code)"
  fi
  # always show whatever came back
  echo -e "CMD Output:\n\n$output\n"
  return $exit_code
}
function setResultToVar () { #1=cmd,2=var_name
  local cmd="$1"
  local var_name="$2"
  if [[ -z "$cmd" || -z "$var_name" ]]; then
    echo "Usage: setResultToVar \"<command>\" <var_name>"
    return 1
  fi
  local result
  result=$(eval "$cmd")
  # Assign to named variable using eval
  eval "$var_name=\"\$result\""
}
function verifyCMDOutput () { # 1=cmd 2=what2look4 3=operator (equals | notequal) 4=message
  local cmd="$1"
  local query="$2"
  local operator="$3"
  local message="$4"
  echo -e "\n▶️ $message"
  echo "Command: $cmd"
  echo "Query: $query"
  output=$(eval "$cmd")
  echo -e "Output: \n$output"
  case "$operator" in
  equals)
    if [[ "$output" == *"$query"* ]]; then
      echo -e "\r✅ $message :: Command Output Matches Query!\n"
      return 0
    else
      echo -e "\r❌ $message :: Command Output Does NOT Match Query!\n"
      exit 1
    fi
    ;;
  notequal)
    if [[ "$output" != *"$query"* ]]; then
      echo -e "\r✅ $message CMD Output Does NOT Match Query!\n"
      return 0
    else
      echo -e "\r❌ $message CMD Output Matches Query!\n"
      exit 1
    fi
    ;;
  esac
}  
function getSecret () { #Usage: getSecret <filename>
  local file="$1" line
  # Read just the first line (strips trailing newline)
  IFS= read -r line < "$file"
  # Assign into the caller’s variable
  echo "$line"
}