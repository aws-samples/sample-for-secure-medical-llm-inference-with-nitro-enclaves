#!/bin/sh
set -e 

OVERRIDE_ENCLAVE_CONFIG=true
OVERRIDE_ENCLAVE_MEMORY_SIZE=30720
OVERRIDE_ENCLAVE_CPU_SIZE=6

# Check if required binaries exist first
echo 'Checking if required binaries exist...'
if ! command -v socat &> /dev/null; then
    echo "ERROR: socat not found. Installing..."
    sudo yum install -y socat
    echo "✓ socat installed successfully"
fi

echo "describe and verify EIF signature"

# Check if required files exist
if [ ! -f "llm-server.eif" ]; then
    echo "ERROR: llm-server.eif not found in current directory"
    exit 1
fi

if [ ! -f "cert.pem" ]; then
    echo "ERROR: cert.pem not found in current directory"
    exit 1
fi

if [ ! -f "measurements.json" ]; then
    echo "ERROR: measurements.json not found in current directory"
    exit 1
fi

# Verify the EIF file signature
nitro-cli describe-eif --eif-path llm-server.eif
EIF_PCR8=$(nitro-cli pcr --signing-certificate cert.pem | jq -r ".PCR8")

echo "Retrieve published PCR8 if any"
# PCR8 published in measurements
PUB_PCR8=$(cat measurements.json | jq -r ".Measurements.PCR8")

echo "EIF PCR8: $EIF_PCR8"
echo "Published PCR8: $PUB_PCR8"

echo "Compare EIF signatures to be equal before proceeding further"
# Return error if enclave does not boots up
if [[ "$EIF_PCR8" != "$PUB_PCR8" ]]; then
    echo "ERROR: Enclave file signature does not match"
    echo "EIF PCR8: $EIF_PCR8"
    echo "Published PCR8: $PUB_PCR8"
    exit 127
fi

echo "✓ EIF signature verification passed"

# disabling and stopping allocator service to claim back cpu, ram
echo 'Going to stop nitro-enclaves-allocator service'
# restart nitro enclaves allocator service and enable start on reboot
sudo systemctl stop nitro-enclaves-allocator.service && sudo systemctl disable nitro-enclaves-allocator.service

echo 'Going to stop IMDSV2 socat proxy service'
IMDSV2_PROXY_STATUS=$(systemctl is-active imdsv2-socat-proxy >/dev/null 2>&1 && echo true || echo false)
if [ "$IMDSV2_PROXY_STATUS" = true ] ; then
    echo 'Going to stop IMDSV2 socat proxy service'
    sudo systemctl stop imdsv2-socat-proxy.service
fi

echo 'Going to stop KMS proxy service'
KMS_PROXY_STATUS=$(systemctl is-active kms-vsock-proxy >/dev/null 2>&1 && echo true || echo false)
if [ "$KMS_PROXY_STATUS" = true ] ; then
    echo 'Going to stop KMS proxy service'
    sudo systemctl stop kms-vsock-proxy.service
fi

echo 'Going to stop S3 proxy service'
S3_PROXY_STATUS=$(systemctl is-active s3-vsock-proxy >/dev/null 2>&1 && echo true || echo false)
if [ "$S3_PROXY_STATUS" = true ] ; then
    echo 'Going to stop S3 proxy service'
    sudo systemctl stop s3-vsock-proxy.service
fi

echo 'Going to stop LLM proxy service'
LLM_PROXY_STATUS=$(systemctl is-active llm-socat-proxy >/dev/null 2>&1 && echo true || echo false)
if [ "$LLM_PROXY_STATUS" = true ] ; then
    echo 'Going to stop LLM proxy service'
    sudo systemctl stop llm-socat-proxy.service
fi

sudo cp -rf kms-vsock-proxy.service /usr/lib/systemd/system/kms-vsock-proxy.service
sudo cp -rf s3-vsock-proxy.service /usr/lib/systemd/system/s3-vsock-proxy.service
sudo cp -rf imdsv2-socat-proxy.service /usr/lib/systemd/system/imdsv2-socat-proxy.service
sudo cp -rf llm-socat-proxy.service /usr/lib/systemd/system/llm-socat-proxy.service


# Get the IMDSV2 token
echo "About to get IMDSV2 token"
TOKEN=$(curl --silent -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Get the connected AWS region
echo "About to get IMDSV2 region using token"
AWS_REGION=$(curl --silent -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo "Region retrieved from IMDSV2 is $AWS_REGION"

cat > vsock-proxy.yaml<< EOF
allowlist:
- {address: s3.$AWS_REGION.amazonaws.com, port: 443}
- {address: kms.$AWS_REGION.amazonaws.com, port: 443}
EOF


sudo mv /etc/nitro_enclaves/vsock-proxy.yaml /etc/nitro_enclaves/vsock-proxy.yaml.bkp
sudo cp -rf vsock-proxy.yaml /etc/nitro_enclaves/vsock-proxy.yaml

echo 'Going to stop/start IMDSV2 socat proxy service'
# restart instance credential retriever proxy service to pickup new config
sudo systemctl enable imdsv2-socat-proxy.service
sudo systemctl daemon-reload
sudo systemctl stop imdsv2-socat-proxy.service || true
sleep 2
sudo systemctl start imdsv2-socat-proxy.service
sudo systemctl status imdsv2-socat-proxy.service --no-pager

echo 'Going to stop/start KMS proxy service'
# restart KMS proxy service to pickup new config
sudo systemctl enable kms-vsock-proxy.service
sudo systemctl daemon-reload
sudo systemctl stop kms-vsock-proxy.service || true
sleep 2
sudo systemctl start kms-vsock-proxy.service
sudo systemctl status kms-vsock-proxy.service --no-pager

echo 'Going to stop/start S3 proxy service'
# restart S3 proxy service to pickup new config
sudo systemctl enable s3-vsock-proxy.service
sudo systemctl daemon-reload
sudo systemctl stop s3-vsock-proxy.service || true
sleep 2
sudo systemctl start s3-vsock-proxy.service
sudo systemctl status s3-vsock-proxy.service --no-pager


echo 'Going to terminate any existing enclaves'
# Terminate any existing enclaves
nitro-cli terminate-enclave --all

echo 'Calculating the minimum memory required based on EIF size'
# calculate the enclave memory needed
EIF_SIZE=$(du -b --block-size=1M "llm-server.eif" | cut -f 1)
ENCLAVE_MEMORY_SIZE=$(((($EIF_SIZE * 4 + 1024 - 1)/1024) * 1024))

echo 'Going to update allocator config'
# Set the allocator memory mib config> 
NE_ALLOCATOR=$(cat <<EOT
---
memory_mib: $OVERRIDE_ENCLAVE_MEMORY_SIZE
cpu_count: $OVERRIDE_ENCLAVE_CPU_SIZE
EOT
)
echo "$NE_ALLOCATOR" | sudo tee /etc/nitro_enclaves/allocator.yaml > /dev/null

# Start LLM socat proxy service from parent to enclave to expose the LLM api endpoint
echo 'Going to stop/start LLM socat proxy service'
sudo systemctl enable llm-socat-proxy.service
sudo systemctl daemon-reload
sudo systemctl stop llm-socat-proxy.service || true
sleep 2
sudo systemctl start llm-socat-proxy.service
sudo systemctl status llm-socat-proxy.service --no-pager


echo 'Going to restart nitro-enclaves-allocator service'
# restart nitro enclaves allocator service and enable start on reboot
sudo systemctl reload-or-restart nitro-enclaves-allocator.service && sudo systemctl enable nitro-enclaves-allocator.service

echo 'Checking if vsock-proxy exists...'

if ! command -v vsock-proxy &> /dev/null; then
    echo "ERROR: vsock-proxy not found. This should be installed with nitro-enclaves-cli"
    echo "Checking if it exists in other locations..."
    find /usr -name "vsock-proxy" 2>/dev/null || echo "vsock-proxy not found anywhere"
fi

echo 'Verifying all proxy services are running...'
FAILED_SERVICES=""

for service in imdsv2-socat-proxy kms-vsock-proxy s3-vsock-proxy llm-socat-proxy; do
    if ! systemctl is-active --quiet $service; then
        echo "ERROR: Service $service is not running"
        FAILED_SERVICES="$FAILED_SERVICES $service"
        echo "Service logs for $service:"
        journalctl -u $service --no-pager -n 10
        echo "---"
    else
        echo "✓ Service $service is running"
    fi
done

if [ -n "$FAILED_SERVICES" ]; then
    echo "ERROR: The following services failed to start:$FAILED_SERVICES"
    echo "Attempting to fix and retry..."
    
    # Try to fix common issues
    sudo systemctl daemon-reload
    
    for service in $FAILED_SERVICES; do
        echo "Retrying $service..."
        sudo systemctl stop $service 2>/dev/null || true
        sleep 1
        sudo systemctl start $service
        sleep 2
        if systemctl is-active --quiet $service; then
            echo "✓ $service is now running"
        else
            echo "✗ $service still failing"
            journalctl -u $service --no-pager -n 5
        fi
    done
fi

echo "Final service status check..."
for service in imdsv2-socat-proxy kms-vsock-proxy s3-vsock-proxy llm-socat-proxy; do
    if systemctl is-active --quiet $service; then
        echo "✓ $service: running"
    else
        echo "✗ $service: failed"
    fi
done


# Launch the enclave
echo "Launching enclave with CPU: $OVERRIDE_ENCLAVE_CPU_SIZE, Memory: $OVERRIDE_ENCLAVE_MEMORY_SIZE MB"
echo "Available memory before launch:"
free -m
echo "Current allocator config:"
cat /etc/nitro_enclaves/allocator.yaml

echo "Running nitro-cli run-enclave command..."
if ! nitro-cli run-enclave --enclave-cid 16 --cpu-count $OVERRIDE_ENCLAVE_CPU_SIZE --memory $OVERRIDE_ENCLAVE_MEMORY_SIZE --eif-path llm-server.eif --attach-console --debug-mode; then
    echo "ERROR: Failed to run enclave"
    exit 1
fi

# Wait a moment for enclave to initialize
sleep 3

echo "Checking enclave status..."
nitro-cli describe-enclaves

ENCLAVE_NAME=$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveName // "null"')
if [ "$ENCLAVE_NAME" = "null" ] || [ -z "$ENCLAVE_NAME" ]; then
    echo "ERROR: Enclave launch failed or enclave not found"
    echo "Checking enclave logs..."
    # Try to get some logs if available
    if [ -d "/var/log/nitro_enclaves" ]; then
        echo "Recent enclave logs:"
        ls -la /var/log/nitro_enclaves/
        # Show the most recent error log if it exists
        LATEST_LOG=$(ls -t /var/log/nitro_enclaves/err*.log 2>/dev/null | head -1)
        if [ -n "$LATEST_LOG" ]; then
            echo "Latest error log ($LATEST_LOG):"
            cat "$LATEST_LOG"
        fi
    fi
    exit 1
fi

echo "✓ Enclave launched successfully with name: $ENCLAVE_NAME"

# Monitor enclave for a few seconds to make sure it stays running
echo "Monitoring enclave stability..."
for i in {1..10}; do
    sleep 2
    CURRENT_STATE=$(nitro-cli describe-enclaves | jq -r '.[0].State // "null"')
    if [ "$CURRENT_STATE" = "null" ] || [ "$CURRENT_STATE" != "RUNNING" ]; then
        echo "ERROR: Enclave stopped running (state: $CURRENT_STATE)"
        exit 1
    fi
    echo "Enclave check $i/10: State = $CURRENT_STATE"
done

echo "✓ Enclave is running stably"

# Install Python dependencies for SQS processor
echo "Installing Python dependencies for SQS processor..."

# Check if pip3 is available, if not install it
if ! command -v pip3 &> /dev/null; then
    echo "pip3 not found, installing..."
    sudo yum install -y python3-pip
fi

# Install dependencies with more verbose output for debugging
echo "Installing boto3 and requests..."
if pip3 install boto3 requests --user; then
    echo "✓ Python dependencies installed successfully"
else
    echo "Failed to install with --user flag, trying system-wide installation..."
    sudo pip3 install boto3 requests
    echo "✓ Python dependencies installed system-wide"
fi

# Verify installation
echo "Verifying boto3 installation..."
if python3 -c "import boto3; print('boto3 version:', boto3.__version__)" 2>/dev/null; then
    echo "✓ boto3 is properly installed"
else
    echo "ERROR: boto3 installation failed"
    exit 1
fi

# Start SQS image processor
echo "Starting SQS image processor..."
if [ -f "image_processor.py" ]; then
    echo "Found SQS image processor script, starting..."
    chmod +x image_processor.py
    python3 image_processor.py &
    SQS_PROCESSOR_PID=$!
    echo "✓ SQS image processor started with PID: $SQS_PROCESSOR_PID"
    
    # Save PID for cleanup if needed
    echo $SQS_PROCESSOR_PID > /tmp/sqs_processor.pid
    
    echo "System is now ready to process images from SQS queue"
else
    echo "WARNING: SQS image processor script not found, skipping..."
fi

exit 0
