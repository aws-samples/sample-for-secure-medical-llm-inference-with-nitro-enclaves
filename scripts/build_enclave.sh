#!/bin/bash
# Script to build the enclave image from the Docker image

set -e

echo "Building enclave image from Docker image..."

# Check if Docker image exists
if ! docker image inspect llm-server:latest &>/dev/null; then
    echo "Error: Docker image 'llm-server:latest' not found."
    echo "Please run scripts/build_app.sh first."
    exit 1
fi

# create test directory
mkdir -p test_images

# Generate signing certificate
openssl ecparam -name secp384r1 -genkey -out test_images/key.pem
openssl req -new -key test_images/key.pem -sha384 -nodes -subj '/CN=AWS/C=US/ST=WA/L=Seattle/O=Amazon/OU=AWS' -out test_images/csr.pem
openssl x509 -req -days 20  -in test_images/csr.pem -out test_images/cert.pem -sha384 -signkey test_images/key.pem


# Build Signed EIF
nitro-cli build-enclave \
    --docker-uri llm-server:latest \
    --output-file client/llm-server.eif \
    --private-key test_images/key.pem \
    --signing-certificate test_images/cert.pem > measurements.json

echo "Enclave image built successfully!"
echo "Image file: client/llm-server.eif"