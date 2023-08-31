import json,boto3,os,logging,time
from botocore.exceptions import ClientError

logger = logging.getLogger("AKAM:S3-NS-SYNC")

def configure_logging():
    logger.setLevel(logging.DEBUG)
    # Format for our loglines
    formatter = logging.Formatter("%(name)s - %(levelname)s - %(message)s")
    # Setup console logging
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    ch.setFormatter(formatter)
    logger.addHandler(ch)
    
def addToQueue(record):
    """
    Description: add processed event to SQS Queue for processing
    Links:
        https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sqs.html#SQS.Client.send_message
    Expects: 
        record
    Returns: Bool on success or failure
    """
    sqs = boto3.client('sqs')
    
    try: 
        response = sqs.send_message(
            QueueUrl=os.environ['queueUrl'],
            DelaySeconds=0,
            MessageBody=(json.dumps(record)),
            MessageGroupId=str(int(time.time()))
        )
        logger.info ("Record added to queue: {0}".format(record))
    except Exception as e: 
        logger.error ("Error adding record '{0}' to queue: {1}".format(record,e))
        return False
    return True

def lambda_handler(event, context):
    configure_logging()
    statusCode = 200
    record_lst = []
    logger.info ("Events {0} received.".format(len(event['Records'])))
    
    for record in event['Records']:
        new_record = {
            'eventName':record['eventName'],
            'bucket':record['s3']['bucket']['name'],
            'key':record['s3']['object']['key'],   
            'etag':record['s3']['object']['eTag'],    
            'sequencer':record['s3']['object']['sequencer']
        }
        
        record_lst.append(new_record)
    if addToQueue(record_lst) is False:
        statusCode = 500        
    if len(record_lst) == 0:
        statusCode = 500
    if statusCode == 500:
        return {
        'statusCode': statusCode,
        'body': 'Error, {0}/{1} added to queue!'.format(len(record_lst),len(event['Records']))
    }

    return {
        'statusCode': statusCode,
        'body': 'Success, {0}/{1} Added to queue!'.format(len(record_lst),len(event['Records']))
    }
