# S3 bucket name that stores model weights

S3_BUCKET_NAME=<S3_BUCKET_NAME> # YOUR S3 BUCKET FOR MODEL HERE

# Get the KMS key ID from the AWS CLI
APP_KMS_KEY_ID=$(aws kms describe-key --key-id alias/AppKmsKey --query KeyMetadata.KeyId --output text)

# Get the model weights and multimodal projection file
# Download the medgemma gguf from the specified repository
wget -O medgemma.gguf https://huggingface.co/kelkalot/medgemma-4b-it-GGUF/resolve/main/medgemma-4b-it-Q8_0.gguf?download=true

# Download the multimodal projection file for image support
wget -O mmproj-medgemma-4b-it-f16.gguf https://huggingface.co/kelkalot/medgemma-4b-it-GGUF/resolve/main/mmproj-medgemma-4b-it-Q8_0.gguf?download=true

echo "Generating data key based on AWS KMS master key"
# Generate the data key and store it in a file
aws kms generate-data-key --key-id $APP_KMS_KEY_ID --key-spec AES_128 > key.json
  

jq -r '.CiphertextBlob' key.json > app.key.enc
jq -r '.Plaintext' key.json > app.key
cat app.key | base64 --decode | xxd -p > app.hex
openssl rand -hex 16 > iv.hex
IV=$(cat iv.hex)
KEY=$(cat app.hex)

openssl enc -in ./medgemma.gguf -out ./medgemma.gguf.enc -e -aes256 -K $KEY -iv $IV
openssl enc -in ./mmproj-medgemma-4b-it-f16.gguf -out ./mmproj-medgemma-4b-it-f16.gguf.enc -e -aes256 -K $KEY -iv $IV
rm -rf app.key app.hex

# Copy encrypted model weights, mmproj file, and the encrypted data key to the publishing bucket
aws s3 cp app.key.enc s3://${S3_BUCKET_NAME}/
aws s3 cp medgemma.gguf.enc s3://${S3_BUCKET_NAME}/
aws s3 cp mmproj-medgemma-4b-it-f16.gguf.enc s3://${S3_BUCKET_NAME}/
aws s3 cp iv.hex s3://${S3_BUCKET_NAME}/