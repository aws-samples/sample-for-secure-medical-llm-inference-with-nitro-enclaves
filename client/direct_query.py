#!/usr/bin/env python3
"""
Wrapper for cURL requests to llama server with DynamoDB logging
Usage: python3 curl_with_logging.py "Your prompt here"
"""

import sys
import json
import requests
import boto3
import uuid
import time
import logging
import threading
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

TABLE_NAME = "<TABLE_NAME>" # YOUR DYNAMODB TABLE NAME HERE
REGION = "<REGION>" # YOUR AWS REGION HERE

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

def send_request_and_log(prompt):
    """Send request to llama server and log to DynamoDB"""
    
    # Prepare the request payload with medical assistant system prompt
    payload = {
        "model": "medgemma",
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": 
                            """You are a medical AI assistant with advanced accuracy, built to assist healthcare professionals.
                            Analyze the input query and provide a clinically useful response. Focus on evidence-based information and do not invent or infer information not supported by medical knowledge.
                            
                            Focus on:
                            - Providing accurate, evidence-based medical information
                            - Using precise, formal clinical language
                            - Identifying key clinical considerations
                            - Mentioning uncertainty only when information cannot be determined
                            
                            Structure your response with a brief summary first, followed by a detailed explanation when appropriate."""
                    },
                    {
                        "type": "text",
                        "text": prompt
                    }
                ]
            }
        ],
        "stream": False
    }
    
    try:
        # Send request to llama server with loading indicator
        logger.info("Sending query to MedGemma for processing...")
        
        # Start loading indicator
        loader = LoadingIndicator("🤖 Processing query")
        loader.start()
        
        try:
            response = requests.post(
                "http://localhost:11434/v1/chat/completions",
                headers={"Content-Type": "application/json"},
                json=payload
            )
        finally:
            # Always stop the loader, even if request fails
            loader.stop()
        
        if response.status_code == 200:
            result = response.json()
            model_response = result.get('choices', [{}])[0].get('message', {}).get('content', '')
            
            logger.info(f"✓ Query processing complete. Response: {model_response}")
            
            # Print the response (like jq -r '.choices[0].message.content')
            print(model_response)
            
            # Log to DynamoDB
            db_logger = DynamoDBLogger()
            db_logger.log_message(prompt, model_response)
            
        else:
            logger.error(f"llama-server returned error: {response.status_code} - {response.text}")
            sys.exit(1)
            
    except requests.exceptions.ConnectionError:
        logger.error("Connection error - llama-server may not be running")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Error processing query with llama-server: {e}")
        sys.exit(1)

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 direct_query.py \"Your prompt here\"")
        sys.exit(1)
    
    prompt = sys.argv[1]
    logger.info("Starting direct query to MedGemma Enclave")
    send_request_and_log(prompt)

if __name__ == "__main__":
    main()