#!/bin/bash
# Complete setup script for the LLM enclave

set -e

echo "=== LLM Enclave Complete Setup ==="
echo "This script will build and run the complete LLM enclave setup"
echo

# Check if we're in the right directory
if [ ! -f "scripts/build_app.sh" ] || [ ! -f "scripts/build_enclave.sh" ]; then
    echo "ERROR: Please run this script from the project root directory"
    exit 1
fi

# Install required Python dependencies system-wide
echo "Installing required Python dependencies system-wide..."
sudo pip3 install boto3 requests
echo "✓ Python dependencies installed successfully"
echo

# Step 1: Envelope encrypt the model
echo "Step 1: Envelope encrypting the model..."
if [ ! -f "scripts/envelope_encrypt_model.sh" ]; then
    echo "ERROR: scripts/envelope_encrypt_model.sh not found"
    exit 1
fi

if ! ./scripts/envelope_encrypt_model.sh; then
    echo "ERROR: Failed to envelope encrypt the model"
    exit 1
fi
echo "✓ Model envelope encrypted successfully"
echo

# Step 2: Build the Docker image
echo "Step 2: Building Docker image..."
if ! ./scripts/build_app.sh; then
    echo "ERROR: Failed to build Docker image"
    exit 1
fi
echo "✓ Docker image built successfully"
echo

# Step 3: Build the enclave
echo "Step 3: Building enclave..."
if ! ./scripts/build_enclave.sh; then
    echo "ERROR: Failed to build enclave"
    exit 1
fi
echo "✓ Enclave built successfully"
echo

# Step 4: Copy required files to client directory
echo "Step 4: Copying required files..."
if [ -f "test_images/cert.pem" ]; then
    cp test_images/cert.pem client/
    echo "✓ Copied cert.pem to client directory"
else
    echo "ERROR: cert.pem not found in test_images directory"
    exit 1
fi

if [ -f "measurements.json" ]; then
    cp measurements.json client/
    echo "✓ Copied measurements.json to client directory"
else
    echo "ERROR: measurements.json not found"
    exit 1
fi
echo

# Step 5: Install required dependencies
echo "Step 5: Installing required dependencies..."
echo "Checking if socat is installed..."
if ! command -v socat &> /dev/null; then
    echo "Installing socat..."
    sudo yum install -y socat
    echo "✓ socat installed successfully"
else
    echo "✓ socat is already installed"
fi
echo

# Step 6: Test services before launching enclave
echo "Step 6: Testing proxy services..."
if ! ./scripts/test_services.sh; then
    echo "WARNING: Some services may not be working properly"
    echo "Continuing anyway..."
fi
echo

# Step 7: Run the client
echo "Step 7: Running client..."
echo "Changing to client directory and running client.sh..."
cd client

if [ ! -f "llm-server.eif" ]; then
    echo "ERROR: llm-server.eif not found in client directory"
    exit 1
fi

echo "All files are ready. Running client.sh..."
echo "Note: This will require sudo privileges for enclave operations"

./client.sh