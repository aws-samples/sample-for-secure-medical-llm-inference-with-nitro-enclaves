import boto3
import base64

s3 = boto3.client('s3')
sqs = boto3.client('sqs')

SQS_QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/406166172533/llm_enclave_medgemma_queue'

def lambda_handler(s3_event, context):
    for record in s3_event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        # Download the image from S3 into memory
        s3_object = s3.get_object(Bucket=bucket, Key=key)
        image_bytes = s3_object['Body'].read()

        # Convert to Base64
        image_b64 = base64.b64encode(image_bytes).decode('utf-8')

        # Push Base64 + metadata to SQS
        response = sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            DelaySeconds=0,
            MessageBody=image_b64,   # message body = base64 image
            MessageAttributes={
                'bucket': {
                    'DataType': 'String',
                    'StringValue': bucket
                },
                'key': {
                    'DataType': 'String',
                    'StringValue': key
                }
            }
        )

        print(f"Pushed {key} from {bucket} to SQS: {response['MessageId']}")
