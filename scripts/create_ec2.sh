#!/bin/bash
# Script to create an EC2 instance with Nitro Enclaves and TPM enabled

set -e

# Configuration
INSTANCE_TYPE="c7i.12xlarge"
AMI_ID="$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023*-kernel-*-x86_64" "Name=state,Values=available" --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)"
KEY_NAME="nitro-enclave-key"
SECURITY_GROUP_NAME="nitro-enclave-sg"
ENCLAVE_OPTIONS="true"

# Create key pair if it doesn't exist
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    echo "Creating key pair $KEY_NAME..."
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query "KeyMaterial" --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
    echo "Key pair created and saved to ${KEY_NAME}.pem"
fi

# Create security group if it doesn't exist
if ! aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" &>/dev/null 2>&1; then
    echo "Creating security group $SECURITY_GROUP_NAME..."
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Security group for Nitro Enclave" --query "GroupId" --output text)
    
    # Allow SSH access
    aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
    echo "Security group created with ID: $SECURITY_GROUP_ID"
else
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text)
    echo "Using existing security group with ID: $SECURITY_GROUP_ID"
fi

# Create user data script to configure Nitro Enclaves
USER_DATA=$(cat <<'EOF'
#!/bin/bash
# Install Nitro Enclaves CLI and dependencies
dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel

# Configure allocator for Nitro Enclaves (allocate 50% of memory and 2 CPUs)
cat > /etc/nitro_enclaves/allocator.yaml <<EOT
---
memory_mib: $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 2048 ))
cpu_count: 2
EOT

# Enable and start nitro-enclaves service
systemctl enable --now nitro-enclaves-allocator.service
systemctl enable --now docker

# Install development tools
dnf install -y git python3 python3-pip docker
EOF
)

# Launch the EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --user-data "$USER_DATA" \
    --enclave-options "Enabled=$ENCLAVE_OPTIONS" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=150,VolumeType=gp3}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=MedGemmaNitroEnclaveDemo}]" \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get public IP address
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "EC2 instance created successfully!"
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Connect using: ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP"
echo "After connecting, clone the repository and run the build scripts."