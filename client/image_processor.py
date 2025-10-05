#!/usr/bin/env python3
"""
SQS Image Processor for MedGemma Enclave
Listens to SQS queue for base64 encoded images and processes them through llama.cpp server
"""

import json
import base64
import time
import logging
import sys
import threading

# Check for required dependencies
try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError
except ImportError as e:
    print(f"ERROR: Missing required dependency: {e}")
    print("Please install boto3: pip3 install boto3 --user")
    print("Or run: ./install_dependencies.sh")
    sys.exit(1)

try:
    import requests
except ImportError:
    print("ERROR: Missing required dependency: requests")
    print("Please install requests: pip3 install requests --user")
    print("Or run: ./install_dependencies.sh")
    sys.exit(1)

# Additional imports for DynamoDB logging
import uuid
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
SQS_QUEUE_URL = "<SQS_QUEUE_URL>" # YOUR SQS QUEUE URL HERE
LLAMA_SERVER_URL = "http://localhost:11434/v1/chat/completions"
TABLE_NAME = "<TABLE_NAME>" # YOUR DYNAMODB TABLE NAME HERE
REGION="<REGION>" # YOUR AWS REGION HERE
POLL_INTERVAL = 5  # seconds between SQS polls
MAX_MESSAGES = 1   # process one message at a time

class DynamoDBLogger:
    """Simple DynamoDB logger for LLM message history tracking"""
    def __init__(self, table_name=TABLE_NAME):
        """Initialize DynamoDB client and table name"""
        self.table_name = table_name
        self.dynamodb = boto3.resource('dynamodb', region_name=REGION)
        self.table = self.dynamodb.Table(table_name)
    
    def log_message(self, prompt, response):
        """
        Log a prompt and response to DynamoDB
        
        Args:
            prompt (str): The user prompt/question
            response (str): The model's response
        """
        try:
            # Generate unique ID and timestamp
            message_id = str(uuid.uuid4())
            timestamp = datetime.utcnow().isoformat() + 'Z'
            
            # Create the item
            item = {
                'ID': message_id,
                'Timestamp': timestamp,
                'Prompt': prompt,
                'Response': response
            }
            
            # Put item in DynamoDB
            self.table.put_item(Item=item)
            logger.info(f"✓ Logged message to DynamoDB: {message_id}")
            return message_id
            
        except Exception as e:
            logger.error(f"✗ Failed to log to DynamoDB: {e}")
            return None

class LoadingIndicator:
    """Simple loading spinner for console output"""
    def __init__(self, message="Processing"):
        self.message = message
        self.spinning = False
        self.spinner_chars = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
        self.thread = None
    
    def _spin(self):
        """Internal method to display the spinner"""
        i = 0
        while self.spinning:
            print(f"\r{self.message} {self.spinner_chars[i % len(self.spinner_chars)]}", end='', flush=True)
            time.sleep(0.1)
            i += 1
    
    def start(self):
        """Start the loading indicator"""
        self.spinning = True
        self.thread = threading.Thread(target=self._spin)
        self.thread.daemon = True
        self.thread.start()
    
    def stop(self):
        """Stop the loading indicator"""
        self.spinning = False
        if self.thread:
            self.thread.join(timeout=0.2)
        print("\r" + " " * (len(self.message) + 2) + "\r", end='', flush=True)  # Clear the line

class SQSImageProcessor:
    def __init__(self):
        """Initialize the SQS client and validate configuration"""
        try:
            self.sqs = boto3.client('sqs', region_name=REGION)
            self.db_logger = DynamoDBLogger()
            logger.info("SQS client initialized successfully")
        except NoCredentialsError:
            logger.error("AWS credentials not found. Make sure IAM role is properly configured.")
            sys.exit(1)
        except Exception as e:
            logger.error(f"Failed to initialize SQS client: {e}")
            sys.exit(1)
    
    def wait_for_llama_server(self, max_retries=30, retry_interval=2):
        """Wait for llama-server to be ready before starting SQS processing"""
        logger.info("Waiting for llama-server to be ready...")
        
        for attempt in range(max_retries):
            try:
                response = requests.get("http://localhost:11434/health", timeout=5)
                if response.status_code == 200:
                    logger.info("llama-server is ready!")
                    return True
            except requests.exceptions.RequestException:
                pass
            
            logger.info(f"Waiting for llama-server... ({attempt + 1}/{max_retries})")
            time.sleep(retry_interval)
        
        logger.error("llama-server did not become ready within the timeout period")
        return False
    
    def validate_base64_image(self, base64_string):
        """Validate that the base64 string is a valid image"""
        try:
            # Remove data URL prefix if present
            if base64_string.startswith('data:image/'):
                base64_string = base64_string.split(',', 1)[1]
            
            # Decode to verify it's valid base64
            image_data = base64.b64decode(base64_string)
            
            # Basic validation - check for common image file signatures
            if image_data.startswith(b'\xff\xd8\xff'):  # JPEG
                return True, "jpeg"
            elif image_data.startswith(b'\x89PNG\r\n\x1a\n'):  # PNG
                return True, "png"
            elif image_data.startswith(b'GIF87a') or image_data.startswith(b'GIF89a'):  # GIF
                return True, "gif"
            else:
                logger.warning("Unknown image format, but proceeding anyway")
                return True, "unknown"
                
        except Exception as e:
            logger.error(f"Invalid base64 image data: {e}")
            return False, None
    
    def process_image_with_llama(self, base64_image):
        """Send image to llama.cpp server for analysis"""
        try:
            # Prepare the request payload
            payload = {
                "model": "medgemma",
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text", 
                                "text": 
                                    """You are a medical imaging AI with advanced accuracy, built to assist radiologists.
                                    Analyze the input medical image (“the scan”) and produce a clinically useful description. Identify anatomical structures, patterns, abnormalities, and possible diagnostic considerations. Do not invent or infer findings not present in the scan.
                                    
                                    Focus on:
                                    - The location and characteristics of any abnormalities
                                    - Signs of common pathologies (fractures, infiltrates, masses, lesions)
                                    - Whether the scan appears normal or requires further review
                                    
                                    Use precise, formal clinical language. Mention uncertainty only when findings cannot be determined. If the image quality is inadequate, state this explicitly.
                                    Structure your response with a brief summary first, followed by a detailed explanation when appropriate."""
                            },
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:image/jpeg;base64,{base64_image}"
                                }
                            }
                        ]
                    }
                ],
                "max_tokens": 300,
                "stream": False
            }
            
            # Send request to llama.cpp server with loading indicator
            logger.info("Sending image to model for analysis...")
            
            # Start loading indicator
            loader = LoadingIndicator("🔬 Analyzing medical image")
            loader.start()
            
            try:
                response = requests.post(
                    LLAMA_SERVER_URL,
                    headers={"Content-Type": "application/json"},
                    json=payload,
                )
            finally:
                # Always stop the loader, even if request fails
                loader.stop()
            
            if response.status_code == 200:
                result = response.json()
                content = result.get('choices', [{}])[0].get('message', {}).get('content', '')
                logger.info(f"✓ Analysis complete. Response: {content}")
                
                # Log to DynamoDB
                prompt = "You are a medical assistant helping a doctor. What is in this image?"
                self.db_logger.log_message(prompt, content)
                
                # Also log to a separate file for easy retrieval
                with open('/tmp/medgemma_analysis.log', 'a') as f:
                    f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - Analysis: {content}\n")
                
                return content
            else:
                logger.error(f"llama-server returned error: {response.status_code} - {response.text}")
                return None
                
        except requests.exceptions.ConnectionError:
            logger.error("Connection error - llama-server may not be running")
            return None
        except Exception as e:
            logger.error(f"Error processing image with llama-server: {e}")
            return None
    
    def process_sqs_message(self, message):
        """Process a single SQS message containing base64 image data"""
        try:
            # Parse message body
            body = message.get('Body', '')
            logger.info(f"Processing message: {message.get('MessageId', 'unknown')}")
            
            # The message body should contain the base64 image string
            # It might be JSON or just the raw base64 string
            try:
                # Try parsing as JSON first
                message_data = json.loads(body)
                if isinstance(message_data, dict):
                    # Look for common keys that might contain the image
                    base64_image = (message_data.get('image') or 
                                  message_data.get('base64') or 
                                  message_data.get('data') or
                                  message_data.get('content'))
                else:
                    base64_image = message_data
            except json.JSONDecodeError:
                # If not JSON, treat the entire body as the base64 string
                base64_image = body.strip()
            
            if not base64_image:
                logger.error("No base64 image data found in message")
                return False
            
            # Validate the base64 image
            is_valid, image_type = self.validate_base64_image(base64_image)
            if not is_valid:
                logger.error("Invalid base64 image data in message")
                return False
            
            logger.info(f"Valid {image_type} image detected, processing...")
            
            # Process the image with llama.cpp
            analysis_result = self.process_image_with_llama(base64_image)
            
            if analysis_result:
                # Don't log again here since it was already logged in process_image_with_llama
                return True
            else:
                logger.error("Failed to analyze image")
                return False
                
        except Exception as e:
            logger.error(f"Error processing SQS message: {e}")
            return False
    
    def delete_message(self, receipt_handle):
        """Delete processed message from SQS queue"""
        try:
            self.sqs.delete_message(
                QueueUrl=SQS_QUEUE_URL,
                ReceiptHandle=receipt_handle
            )
            logger.info("Message deleted from queue")
        except Exception as e:
            logger.error(f"Failed to delete message from queue: {e}")
    
    def poll_sqs_queue(self):
        """Main loop to poll SQS queue for messages"""
        logger.info(f"Starting SQS polling for queue: {SQS_QUEUE_URL}")
        
        while True:
            try:
                # Poll for messages
                response = self.sqs.receive_message(
                    QueueUrl=SQS_QUEUE_URL,
                    MaxNumberOfMessages=MAX_MESSAGES,
                    WaitTimeSeconds=20,  # Long polling
                    VisibilityTimeout=300  # 5 minutes to process
                )
                
                messages = response.get('Messages', [])
                
                if not messages:
                    logger.debug("No messages received, continuing to poll...")
                    continue
                
                for message in messages:
                    logger.info(f"Received message: {message.get('MessageId', 'unknown')}")
                    
                    # Process the message
                    success = self.process_sqs_message(message)
                    
                    if success:
                        # Delete the message from queue if processing was successful
                        self.delete_message(message['ReceiptHandle'])
                    else:
                        logger.warning("Message processing failed, leaving in queue for retry")
                
            except ClientError as e:
                error_code = e.response['Error']['Code']
                if error_code == 'QueueDoesNotExist':
                    logger.error(f"SQS queue does not exist: {SQS_QUEUE_URL}")
                    break
                elif error_code == 'AccessDenied':
                    logger.error("Access denied to SQS queue. Check IAM permissions.")
                    break
                else:
                    logger.error(f"SQS error: {e}")
                    time.sleep(POLL_INTERVAL)
                    
            except KeyboardInterrupt:
                logger.info("Received interrupt signal, shutting down...")
                break
                
            except Exception as e:
                logger.error(f"Unexpected error: {e}")
                time.sleep(POLL_INTERVAL)
    
    def run(self):
        """Main entry point"""
        # Wait for llama-server to be ready
        if not self.wait_for_llama_server():
            logger.error("llama-server is not ready, exiting")
            sys.exit(1)
        
        # Test the server with a simple request to make sure it's working
        logger.info("Testing llama-server connectivity...")
        try:
            test_payload = {
                "model": "medgemma",
                "messages": [{"role": "user", "content": "Hello"}],
                "max_tokens": 10,
                "stream": False
            }
            response = requests.post(LLAMA_SERVER_URL, json=test_payload, timeout=30)
            if response.status_code == 200:
                logger.info("✓ llama-server connectivity test passed")
            else:
                logger.warning(f"llama-server test returned status {response.status_code}")
        except Exception as e:
            logger.warning(f"llama-server connectivity test failed: {e}")
        
        # Start polling SQS queue
        self.poll_sqs_queue()

def main():
    """Main function"""
    logger.info("Starting SQS Image Processor for MedGemma Enclave")
    
    processor = SQSImageProcessor()
    processor.run()

if __name__ == "__main__":
    main()