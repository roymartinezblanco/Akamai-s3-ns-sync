import json, os, logging, sys,time, boto3

from akamai.netstorage import Netstorage, NetstorageError


REGION_NAME = os.environ['REGION']
QUEUE_URL = os.environ['QUEUE_URL']
CPCODE = os.environ['CPCODE']
S3_BUCKET = os.environ['BUCKET']
NS_SECRET = os.environ['NS_SECRET']

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
  

def readQueue():

    """
    Description: Reads SQS Queue for processing
    Links:
        https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sqs.html#SQS.Client.receive_message
    Expects: 
        Nothing
    Returns: message array, each in JSON
    """
    sqs = boto3.client('sqs',region_name=REGION_NAME)
    
    resp = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        AttributeNames=['All'],
        MaxNumberOfMessages=5,
        VisibilityTimeout=30,
        WaitTimeSeconds=0
    )
    try:
        messages = resp['Messages']
        logger.info('{0} Messages on the queue!'.format(len(messages)))
        
    except KeyError:
        logger.info('No messages on the queue!')
        messages = []
    return messages

def upload(CPCODE,path): 
    
    """
    Description: uploads to netstorage.
    Links:
        https://learn.akamai.com/en-us/webhelp/netstorage/netstorage-http-api-developer-guide/GUID-C9CEE090-B272-4E47-ACD9-853D80C747BC.html
        https://github.com/akamai/NetStorageKit-Python
    Expects: 
        Cpcode
        path: s3 object key
    Returns: Bool based on task success.
    """
    NS_USER = json.loads(NS_SECRET)['NS_USER']
    NS_KEY = json.loads(NS_SECRET)['NS_KEY']
    NS_HOSTNAME = json.loads(NS_SECRET)['NS_HOSTNAME']
    
    ns = Netstorage(NS_HOSTNAME, NS_USER, NS_KEY, ssl=False)
 
    netstorage_destination = "/{0}/{1}".format(CPCODE,path)

    logger.info("Upload Location: '{0}'.".format(netstorage_destination))
    ok, _ = ns.upload(path, netstorage_destination)
    if ok: 
        logger.info("File: uploaded.")
        return True
    else:
        logger.info("File: upload failed.")
        return False

def removeObject(path):
    """
    Description: Remove objects from NS
    Links:
        https://learn.akamai.com/en-us/webhelp/netstorage/netstorage-http-api-developer-guide/GUID-C9CEE090-B272-4E47-ACD9-853D80C747BC.html
        https://github.com/akamai/NetStorageKit-Python
    Expects: 
        path: Path to be deleted in NS.
    Returns: Bool based on task success.
    """
    NS_USER = json.loads(NS_SECRET)['NS_USER']
    NS_KEY = json.loads(NS_SECRET)['NS_KEY']
    NS_HOSTNAME = json.loads(NS_SECRET)['NS_HOSTNAME']
    
    ns = Netstorage(NS_HOSTNAME, NS_USER, NS_KEY, ssl=False)
    netstorage_destination = "/{0}/{1}".format(CPCODE,path)
    ok, response =ns.delete(netstorage_destination)
    if ok:
        logger.info("File {0} deleted.".format(path)) 
    else:
        logger.error("File {0} not deleted: {1}".format(path,response.status_code)) 
        return response.status_code
    return response.status_code        
def fetchS3Object(s3_key):
    logger.info("Downloading file: {0}".format(s3_key))
    try:
        s3 = boto3.client('s3')

        path = os.path.dirname(s3_key)
        logger.info("File directory : {0}".format(path))
        os.makedirs(path, exist_ok=True)

        s3.download_file(S3_BUCKET,s3_key,s3_key)
        success = os.path.isfile(s3_key)
        logger.info ("File Downloaded: {0}".format(str(success)))
        return success
    except Exception as e:
        logger.error ("Error downloading file: {0}".format(e))
def popQueue(receipt_handle):
    """
    Description: POPs Msg from SQS fifo queue
    Links:
        https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sqs.html#SQS.Client.delete_message
    Expects: 
        receipt_handle (string) -- The SQS Message's receipt_handle identifier.
    Returns: Nothing
    """

    sqs = boto3.client('sqs',region_name=REGION_NAME)

    sqs.delete_message(
        QueueUrl=QUEUE_URL,

        ReceiptHandle=receipt_handle
    )
    logger.info ("Event removed from queue: {0}".format(receipt_handle))
    return

def cleanLocal(key):
    """
    Description: Removes object downloaded from s3 after proccessed.

    Expects: 
        key (string) -- Objects path/filename
    Returns: Nothing
    """
    try:
        os.remove(key)
        logger.info ("Deleted {0} locally".format(key))
        
    except Exception as e:
        logger.error ("Error to delete file {0}: {1}".format(key,e))

def processQueue():
    """
    Description: Runs Functions to read Queue and update Netstorage.

    Expects: 
        Nothing
    Returns: Bool
    """
    try:     
        queue = readQueue()
        if queue != []:
            for msg in queue:
                event = json.loads(msg['Body'])
                success = True
                for o in event:
                    if 'ObjectRemoved' in o['eventName']:
                        response = removeObject(o['key'])
                        if response == 404:
                            logger.warning ("Error deleting file {0} was not found in Netstorage.".format(o['key']))
                            success = True

                    else:
                        if fetchS3Object(o['key']):
                            success = upload(CPCODE,o['key'])
                if success:
                    popQueue(msg['ReceiptHandle'])
                    if not 'ObjectRemoved' in o['eventName']:
                        cleanLocal(o['key'])
            time.sleep(20)
            processQueue()
        else:
            return True
    except Exception as e:
        logger.error ("Error processing the queue: {0}".format(e))
        return False
    return True
        
if __name__ == "__main__":
    configure_logging()
    logger.info("AWS S3 - Akamai NetStorage Sync Started.")
    
    processQueue()
    logger.info("Exiting..")
    sys.exit(0)
            



