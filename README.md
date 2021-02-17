# AWS S3 event based replication to Akamai NetStorage

![Diagram](https://raw.githubusercontent.com/roymartinezblanco/Akamai-s3-ns-sync/master/etc/diagram.png)

# Terraform

Functionality:
- Creates AWS infrastructure:
    * IAM Roles
    * IAM Policy Attachments
    * VPC Subnets
    * Security Group
    * Secret (Secret Manager)
    * SQS FIFO Queue
    * Lambda Function
    * S3 Lambda Event Trigger
    * ECR Container Repository
    * ECS Container Cluster
    * ECS Container Service
    * ECS Container Task

- Other:
    * Builds Docker Image
    * Tags Docker Image
    * Push's Docker Image to ECR

## Usage ###

|Argument| Purpose|
|---------|--------|
| bucket  |  [Requiered] S3 Bucket to be replicated. |
| accountid |  [Requiered] AWS Account ID |
| region |  [Requiered] AWS region |
| cpcode |  [Requiered] Akamai NetStorage CPCODE |
| secret |  [Requiered] NetStorage API Credentials, in Json format. Expects Hostname, username and Key  |

### Example:
#### Plan
```sh
terraform plan -var='bucket=CHANGE_ME' -var='accountid=CHANGE_ME' -var='cpcode=CHANGE_ME' -var='region=CHANGE_ME' -var='secret={"NS_HOSTNAME":"CHANGE_ME","NS_USER":"CHANGE_ME","NS_KEY":"CHANGE_ME"}'
```
#### Apply
```sh
terraform apply -var='bucket=CHANGE_ME' -var='accountid=CHANGE_ME' -var='cpcode=CHANGE_ME' -var='region=CHANGE_ME' -var='secret={"NS_HOSTNAME":"CHANGE_ME","NS_USER":"CHANGE_ME","NS_KEY":"CHANGE_ME"}'
```

### Container

```docker
FROM python:3
RUN pip3 install netstorageapi
RUN pip3 install boto3
COPY sync.py /
ENTRYPOINT [ "python", "./sync.py" ]
```

### [Sync.py](https://github.com/roymartinezblanco/Akamai-s3-ns-sync/blob/master/sync.py)

Lightweight python script that is run by ECS instance. 

Functionality:
- Reads SQS Queue
```python
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
```
- Fetches s3 Object
```python
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
```
- Uploads/updates Akamai Netstorage objects.
```python
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
    
    NS_USER = json.loads(SECRET)['NS_USER']
    NS_KEY = json.loads(SECRET)['NS_KEY']
    NS_HOSTNAME = json.loads(SECRET)['NS_HOSTNAME']
    logger.info("Uploading to Ns with user: '{0}'".format(NS_USER))
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
```
- Removes Event from Queue
```python
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
```