#!/bin/bash
# Test script to verify proxy services are working

echo "=== Testing Proxy Services ==="
echo

# Test IMDSV2 proxy
echo "1. Testing IMDSV2 proxy service..."
if systemctl is-active --quiet imdsv2-socat-proxy; then
    echo "✅ IMDSV2 proxy service is running"
    
    # Test if we can get a token through the proxy
    echo "   Testing IMDSV2 token retrieval..."
    if timeout 10 curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" > /dev/null; then
        echo "✅ IMDSV2 token retrieval works"
    else
        echo "❌ IMDSV2 token retrieval failed"
    fi
else
    echo "❌ IMDSV2 proxy service is not running"
    systemctl status imdsv2-socat-proxy --no-pager
fi
echo

# Test KMS proxy
echo "2. Testing KMS proxy service..."
if systemctl is-active --quiet kms-vsock-proxy; then
    echo "✅ KMS proxy service is running"
else
    echo "❌ KMS proxy service is not running"
    systemctl status kms-vsock-proxy --no-pager
fi
echo

# Test S3 proxy
echo "3. Testing S3 proxy service..."
if systemctl is-active --quiet s3-vsock-proxy; then
    echo "✅ S3 proxy service is running"
else
    echo "❌ S3 proxy service is not running"
    systemctl status s3-vsock-proxy --no-pager
fi
echo

# Test LLM proxy
echo "4. Testing LLM proxy service..."
if systemctl is-active --quiet llm-socat-proxy; then
    echo "✅ LLM proxy service is running"
    
    # Test if the port is listening
    if netstat -ln | grep -q ":11434"; then
        echo "✅ Port 11434 is listening"
    else
        echo "❌ Port 11434 is not listening"
    fi
else
    echo "❌ LLM proxy service is not running"
    systemctl status llm-socat-proxy --no-pager
fi
echo

# Test Nitro Enclaves allocator
echo "5. Testing Nitro Enclaves allocator..."
if systemctl is-active --quiet nitro-enclaves-allocator; then
    echo "✅ Nitro Enclaves allocator is running"
    
    # Show current allocation
    echo "   Current allocator config:"
    cat /etc/nitro_enclaves/allocator.yaml 2>/dev/null || echo "   Config file not found"
else
    echo "❌ Nitro Enclaves allocator is not running"
    systemctl status nitro-enclaves-allocator --no-pager
fi
echo

# Show current enclave status
echo "6. Current enclave status:"
nitro-cli describe-enclaves
echo

echo "=== Service Test Complete ==="