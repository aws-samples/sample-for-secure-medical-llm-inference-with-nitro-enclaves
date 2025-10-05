#!/bin/sh
set -euxo pipefail

# === ENCLAVE STARTUP SCRIPT (patched) ===
# Purpose: start services inside enclave, download and decrypt model, run llama.cpp server,
#          and keep the enclave alive while monitoring failures.
#
# Notes: - This script initializes PID vars so "set -u" does not cause unbound variable errors.
#        - Uses llama.cpp server (llama-server) to serve the MedGemma model via HTTP API

# Add console output for debugging
exec > >(tee -a /tmp/enclave_startup.log)
exec 2>&1

echo "=== ENCLAVE STARTUP LOG ==="
echo "Timestamp: $(date)"
echo "Starting enclave initialization..."

# Trap to catch exits and provide debugging info
trap 'echo "ERROR: Script exiting at line $LINENO with exit code $?"; cleanup; exit 1' ERR
trap 'echo "Script interrupted"; cleanup; exit 1' INT TERM
trap 'echo "Normal exit"; cleanup' EXIT

# Initialize PID and important variables to avoid "unbound variable" with set -u
LLAMA_SERVER_PID=""
LLAMA_MODEL_PID=""
IMDSV2_PROXY_PID=""
S3_PROXY_PID=""
LLAMA_PROXY_PID=""
KMS_PROXY_PID=""

S3_BUCKET_NAME=${S3_BUCKET_NAME:-<S3_BUCKET_NAME>} # YOUR S3 BUCKET FOR MODEL HERE BESIDE DASH (-)
APP_DIR=${APP_DIR:-/app}
MODEL_NAME=${MODEL_NAME:-medgemma}
MODEL_FILE_PATH=${MODEL_FILE_PATH:-${APP_DIR}/medgemma.gguf}
MODFILE_PATH=${MODFILE_PATH:-${APP_DIR}/Modelfile}

cleanup() {
    echo "Running cleanup..."
    # Kill background proxies and services if they were started
    [ -n "${IMDSV2_PROXY_PID:-}" ] && { echo "Killing IMDSV2 proxy PID $IMDSV2_PROXY_PID"; kill "$IMDSV2_PROXY_PID" 2>/dev/null || true; }
    [ -n "${S3_PROXY_PID:-}" ] && { echo "Killing S3 proxy PID $S3_PROXY_PID"; kill "$S3_PROXY_PID" 2>/dev/null || true; }
    [ -n "${KMS_PROXY_PID:-}" ] && { echo "Killing KMS proxy PID $KMS_PROXY_PID"; kill "$KMS_PROXY_PID" 2>/dev/null || true; }
    [ -n "${LLAMA_PROXY_PID:-}" ] && { echo "Killing llama-server proxy PID $LLAMA_PROXY_PID"; kill "$LLAMA_PROXY_PID" 2>/dev/null || true; }
    [ -n "${LLAMA_MODEL_PID:-}" ] && { echo "Killing llama-server model worker PID $LLAMA_MODEL_PID"; kill "$LLAMA_MODEL_PID" 2>/dev/null || true; }
    [ -n "${LLAMA_SERVER_PID:-}" ] && { echo "Killing llama-server PID $LLAMA_SERVER_PID"; kill "$LLAMA_SERVER_PID" 2>/dev/null || true; }

    echo "Collecting dmesg tail for diagnostics..."
    dmesg | tail -n 200 || true

    echo "Cleanup finished."
}

echo "CHECKPOINT 1: Setting up network interfaces..."
# Assign additional loopback addresses (if already present this will error, use || true if desired)
ip addr add 127.0.0.1/32 dev lo || true
ip addr add 127.0.0.2/32 dev lo || true
ip addr add 169.254.0.0/16 dev lo || true
ip link set dev lo up || true

echo "CHECKPOINT 2: Network setup complete, setting up environment..."
# ensure libnsm exists (touch is harmless)
touch "${APP_DIR}/libnsm.so" || true

export HF_DATASETS_OFFLINE=1 
export TRANSFORMERS_OFFLINE=1 

echo "CHECKPOINT 3: Starting proxy services..."
# Socat proxy for exposing IMDSV2 into enclave
echo "About to start a socat bridge from 80 to vsock 8010 for IMDSV2"
socat tcp-listen:80,fork,bind=169.254.169.254,reuseaddr,su=nobody VSOCK-CONNECT:3:8010 &
IMDSV2_PROXY_PID=$!
echo "IMDSV2 proxy started with PID ${IMDSV2_PROXY_PID}"

# Wait a moment for the proxy to start
sleep 2

echo "CHECKPOINT 4: Getting AWS credentials..."
# Get the IMDSV2 token
echo "About to get IMDSV2 token"
TOKEN=$(curl --silent -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

if [ -z "${TOKEN:-}" ]; then
  echo "WARNING: IMDSV2 token empty; IMDSV2 proxy or host access may be misconfigured"
fi

# Get the connected AWS region
echo "About to get IMDSV2 region using token"
AWS_REGION=$(curl --silent -H "X-aws-ec2-metadata-token: ${TOKEN:-}" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region || true)
echo "Region retrieved from IMDSV2 is ${AWS_REGION:-unknown}"

# Add a hosts record, pointing target site calls to local loopback (if we have a region)
if [ -n "${AWS_REGION:-}" ]; then
  echo "127.0.0.2   ${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com" >> /etc/hosts || true
  echo "Added /etc/hosts entry for S3 proxy"
else
  echo "No AWS region retrieved; skipping hosts entry addition"
fi

# Socat proxy for exposing S3 into enclave
echo "About to start a socat bridge from 443 to vsock 8020 for Amazon S3"
socat tcp-listen:443,fork,bind=127.0.0.2,reuseaddr,su=nobody VSOCK-CONNECT:3:8020 &
S3_PROXY_PID=$!
echo "S3 proxy started with PID ${S3_PROXY_PID}"

# Wait a moment for the proxy to start
sleep 2

# Socat proxy for exposing llama-server api endpoint out of enclave
echo "About to start a socat bridge from vsock 8000 to localhost:11434"
socat VSOCK-LISTEN:8000,fork,reuseaddr tcp-connect:localhost:11434 &
LLAMA_PROXY_PID=$!
echo "llama-server proxy started with PID ${LLAMA_PROXY_PID}"

echo "Getting IAM role from IMDSV2"
ROLE=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN:-}" http://169.254.169.254/latest/meta-data/iam/security-credentials || true)
if [ -z "${ROLE:-}" ]; then
    echo "ERROR: Failed to get IAM role from IMDSV2"
    cleanup
    exit 1
fi
echo "IAM Role: $ROLE"

# Get IAM credentials for KMS enclave CLI tool
echo "Getting IAM credentials from IMDSV2"
CREDS=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN:-}" http://169.254.169.254/latest/meta-data/iam/security-credentials/"${ROLE}" || true)
if [ -z "${CREDS:-}" ]; then
    echo "ERROR: Failed to get IAM credentials from IMDSV2"
    cleanup
    exit 1
fi

AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Token')

if [ "${AWS_ACCESS_KEY_ID:-}" = "null" ] || [ "${AWS_SECRET_ACCESS_KEY:-}" = "null" ] || [ "${AWS_SESSION_TOKEN:-}" = "null" ]; then
    echo "ERROR: Failed to parse IAM credentials"
    echo "Credentials response: $CREDS"
    cleanup
    exit 1
fi

echo "Successfully retrieved AWS credentials"

echo "CHECKPOINT 5: Downloading encrypted files from S3..."
cd "${APP_DIR}" || { echo "Cannot cd to ${APP_DIR}"; cleanup; exit 1; }

# Copy the gguf parts bundle, iv and encrypted data key from S3 bucket
echo "Downloading encrypted model and keys from S3 bucket: ${S3_BUCKET_NAME}"

echo "About to download the gguf file"
if ! aws s3 cp "s3://${S3_BUCKET_NAME}/medgemma.gguf.enc" medgemma.gguf.enc; then
    echo "ERROR: Failed to download medgemma.gguf.enc from S3"
    cleanup
    exit 1
fi

echo "About to download the iv hex file"
if ! aws s3 cp "s3://${S3_BUCKET_NAME}/iv.hex" iv.hex; then
    echo "ERROR: Failed to download iv.hex from S3"
    cleanup
    exit 1
fi

echo "About to download the encrypted data key"
if ! aws s3 cp "s3://${S3_BUCKET_NAME}/app.key.enc" app.key.enc; then
    echo "ERROR: Failed to download app.key.enc from S3"
    cleanup
    exit 1
fi

echo "Successfully downloaded all required files from S3"

echo "CHECKPOINT 6: Starting KMS decryption..."

CIPHER_TEXT=$(cat app.key.enc || true)
# debug assist
ls -l
echo "CIPHER_TEXT (truncated): $(echo "${CIPHER_TEXT:-}" | head -c 200)"

# Check if kmstool_enclave_cli exists
if [ ! -f "${APP_DIR}/kmstool_enclave_cli" ]; then
    echo "ERROR: kmstool_enclave_cli not found at ${APP_DIR}/kmstool_enclave_cli"
    cleanup
    exit 1
fi

# Make sure it's executable
chmod +x "${APP_DIR}/kmstool_enclave_cli" || true

# Start KMS proxy in background
echo "Starting KMS proxy on port 8015"
socat tcp-listen:8015,fork,bind=127.0.0.1,reuseaddr,su=nobody VSOCK-CONNECT:3:8015 &
KMS_PROXY_PID=$!
echo "KMS proxy started with PID ${KMS_PROXY_PID}"

# Wait a moment for the proxy to start
sleep 2

# decrypt the app.key.enc using kmstool enclave cli
echo "using kmstool enclave cli to decrypt the app data key"
echo "KMS command: ${APP_DIR}/kmstool_enclave_cli decrypt --region ${AWS_REGION:-} --proxy-port 8015"

if ! "${APP_DIR}/kmstool_enclave_cli" decrypt --region "${AWS_REGION:-}" --proxy-port "8015" --aws-access-key-id "${AWS_ACCESS_KEY_ID}" --aws-secret-access-key "${AWS_SECRET_ACCESS_KEY}" --aws-session-token "${AWS_SESSION_TOKEN}" --ciphertext "${CIPHER_TEXT}" > kms.resp; then
    echo "ERROR: KMS decryption failed"
    cat kms.resp || true
    cleanup
    exit 1
fi

echo "Here is the kms response: $(cat kms.resp)"
cat kms.resp | cut -c 12- > app.key
echo "Here is the app key (truncated): $(head -c 60 app.key || true)"
cat app.key | base64 --decode | xxd -p > app.hex
ls -l

echo "using openssl to decrypt the model weights using plaintext data key"
# decrypt app bundle
KEY=$(cat app.hex || true)
IV=$(cat iv.hex || true)

if [ -z "${KEY:-}" ] || [ -z "${IV:-}" ]; then
    echo "ERROR: Key or IV is empty"
    echo "Key length: ${#KEY}"
    echo "IV length: ${#IV}"
    cleanup
    exit 1
fi

echo "Decrypting model file with OpenSSL"
if ! openssl enc -in ./medgemma.gguf.enc -out ./medgemma.gguf -d -aes256 -K "$KEY" -iv "$IV"; then
    echo "ERROR: Failed to decrypt model file"
    cleanup
    exit 1
fi

echo "Done with decrypting model files"
rm -f medgemma.gguf.enc || true

# Verify the decrypted file exists and has reasonable size
if [ ! -f "./medgemma.gguf" ]; then
    echo "ERROR: Decrypted model file not found"
    cleanup
    exit 1
fi

MODEL_SIZE=$(stat -c%s "./medgemma.gguf" || echo 0)
echo "Decrypted model file size: $MODEL_SIZE bytes"

if [ "${MODEL_SIZE:-0}" -lt 1000000 ]; then
    echo "ERROR: Decrypted model file seems too small (less than 1MB)"
    cleanup
    exit 1
fi

echo "CHECKPOINT 7: Starting llama.cpp server..."

ls -l
export HOME="${APP_DIR}/"

# Check if llama-server binary exists and is executable
if ! command -v llama-server &> /dev/null; then
    echo "ERROR: llama-server command not found"
    cleanup
    exit 1
fi

echo "llama-server found, starting server..."

# Download the mmproj file for multimodal support
echo "Downloading mmproj file for multimodal support..."
if ! aws s3 cp "s3://${S3_BUCKET_NAME}/mmproj-medgemma-4b-it-f16.gguf.enc" mmproj-medgemma-4b-it-f16.gguf.enc; then
    echo "WARNING: Failed to download mmproj file, continuing without multimodal support"
    MMPROJ_FILE=""
else
    echo "Decrypting mmproj file..."
    if ! openssl enc -in ./mmproj-medgemma-4b-it-f16.gguf.enc -out ./mmproj-medgemma-4b-it-f16.gguf -d -aes256 -K "$KEY" -iv "$IV"; then
        echo "WARNING: Failed to decrypt mmproj file, continuing without multimodal support"
        MMPROJ_FILE=""
    else
        MMPROJ_FILE="--mmproj ${APP_DIR}/mmproj-medgemma-4b-it-f16.gguf"
        echo "mmproj file ready for multimodal support"
    fi
fi

# Start llama-server in background
echo "Starting llama-server with model: ${MODEL_FILE_PATH}"
llama-server -m "${MODEL_FILE_PATH}" ${MMPROJ_FILE} -c 2048 --port 11434 --host 0.0.0.0 &
LLAMA_SERVER_PID=$!

# Wait a bit for llama-server to start
sleep 5

# Check if llama-server is still running
if ! kill -0 "$LLAMA_SERVER_PID" 2>/dev/null; then
    echo "ERROR: llama-server failed to start"
    cleanup
    exit 1
fi

echo "llama-server started successfully with PID ${LLAMA_SERVER_PID}"

# Wait for llama-server to be ready
echo "Waiting for llama-server to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:11434/health >/dev/null 2>&1; then
        echo "llama-server is ready!"
        break
    fi
    echo "Waiting for llama-server... ($i/30)"
    sleep 2
done

# Check if llama-server is responding
if ! curl -s http://localhost:11434/health >/dev/null 2>&1; then
    echo "ERROR: llama-server is not responding after 60 seconds"
    cleanup
    exit 1
fi

echo "CHECKPOINT 8: Model loaded in llama-server..."
# llama.cpp loads the model directly, no separate model creation step needed
echo "Model file: ${MODEL_FILE_PATH}"
echo "Model loaded and ready for inference"

# Test the server with a simple request
echo "Testing llama-server with a simple health check..."
if curl -s http://localhost:11434/health | grep -q "ok\|ready\|healthy"; then
    echo "llama-server health check passed"
else
    echo "WARNING: llama-server health check failed, but continuing..."
fi

# No separate model worker PID needed for llama.cpp
LLAMA_MODEL_PID=""

echo "CHECKPOINT 9: Final status"
echo "llama-server PID: ${LLAMA_SERVER_PID:-}"
echo "llama-server model worker PID: ${LLAMA_MODEL_PID:-}"

# New diagnostics: capture kernel log tail to help find OOM/panic messages if service dies
echo "------- dmesg tail (pre-wait) -------"
dmesg | tail -n 100 || true
echo "------- end dmesg -------"

echo "CHECKPOINT 10: llama.cpp with MedGemma GGUF loaded successfully."
echo "If the model or server crashes shortly after this, examine dmesg and /tmp/enclave_startup.log for OOM or kernel messages."

# Keep the script running so the enclave stays alive
# Wait for LLAMA_SERVER_PID (llama-server) - but only if it's non-empty
if [ -n "${LLAMA_SERVER_PID:-}" ]; then
  echo "Entering wait on llama-server PID ${LLAMA_SERVER_PID}..."
  wait "${LLAMA_SERVER_PID}"
else
  echo "No llama-server PID to wait on; sleeping to keep enclave alive."
  # Sleep loop — keep the enclave alive but periodically log status
  while true; do
    echo "Heartbeat: $(date) - llama-server PID: ${LLAMA_SERVER_PID:-}, model worker PID: ${LLAMA_MODEL_PID:-}"
    sleep 60
  done
fi

# end of script
