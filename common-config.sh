# Example values for the below variables:
# ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_BASE_CONTENT_PATH}/${ECR_IMAGE_BASE}"
# ${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_BASE_CONTENT_PATH}/${ECR_PACK_BASE}"
VERTEX_VERSION="4.9.18"
AWS_ACCOUNT="103448924380" # e.g. 123456789012
ECR_BASE_CONTENT_PATH="cuff-airgap" # e.g. 103448924380.dkr.ecr.us-gov-west-1.amazonaws.com/BASE_CONTENT_PATH/spectro-images
AWS_REGION="us-gov-west-1" # YOUR AWS REGION #(e.g. us-gov-west-1)
ECR_REGISTRY=$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
ECR_IMAGE_BASE="spectro-images"
ECR_PACK_BASE=""
DOWNLOAD_USER=spectro   # optional basic auth username
DOWNLOAD_PASS="mV715z##spPSJC"    # optional basic auth password
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_DIR="${SCRIPT_DIR}/spectroairgap-${VERTEX_VERSION}"
SKIP_EXTRACTION="false"
BINARY="./airgap-vertex-v${VERTEX_VERSION}.bin" # set to true to skip extraction of the binary if it already exists
PUBLIC_KEY="spectro_public_key.pem"
PUBLIC_KEY_URL="https://artifact-studio.spectrocloud.com/spectro_public_key.pem"
