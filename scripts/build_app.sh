#!/bin/bash
# Script to build the Docker image for the llm server

set -e

echo "Building llm server Docker image..."
cd "$(dirname "$0")/../server"

# Build the Docker image
docker build -f Dockerfile.base -t enclave_base .
docker build -t llm-server:latest .

echo "Docker image built successfully!"
echo "Image name: llm-server:latest"