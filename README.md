# AWS S3 event based replication to Akamai NetStorage

This is a sample starter project that show cases how to replicate between AWS s3 storage and Akamai Netstorage based on object events. (only create/update events for now)

This project uses a Lambda s3 object event trigger function that adds the events to a SQS queue. This queue is read by a ECS Cluster task that processes the events and updates Netstorage. 

> The scope of this POC is to provide the means/example on how to get started, but additional changes will be needed, like: adjusting auto scaling, exploring SQS long poling or creation of Task schedule, etc.

![Diagram](https://raw.githubusercontent.com/roymartinezblanco/Akamai-s3-ns-sync/master/etc/diagram.png)


# [Terraform](https://github.com/roymartinezblanco/Akamai-s3-ns-sync/blob/master/terraform.tf)

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
    * ECS Step Autoscaling

- Other:
    * Builds Docker Image
    * Tags Docker Image
    * Push's Docker Image to ECR

## Usage ###

|Argument| Purpose|
|---------|--------|
| bucket  |  [Required] S3 Bucket to be replicated. |
| accountid |  [Required] AWS Account ID |
| region |  [Required] AWS region |
| cpcode |  [Required] Akamai NetStorage CPCODE |
| secret |  [Required] NetStorage API Credentials, in Json format. Expects Hostname, username and Key  |
| natgwrtid | [Required] The route table ID for private subnets to route to the NAT Gateway. This project creates 2 private subnets in the Default 172.31.0.0/16 VPC and will use existing NAT Gateway configuration |

### Example:
#### Plan
```sh
terraform plan -var='bucket=CHANGE_ME' -var='accountid=CHANGE_ME' -var='cpcode=CHANGE_ME' -var='region=CHANGE_ME' -var='secret={"NS_HOSTNAME":"CHANGE_ME","NS_USER":"CHANGE_ME","NS_KEY":"CHANGE_ME"}' -var='natgwrtid=CHANGE_ME'
```
#### Apply
```sh
terraform apply -var='bucket=CHANGE_ME' -var='accountid=CHANGE_ME' -var='cpcode=CHANGE_ME' -var='region=CHANGE_ME' -var='secret={"NS_HOSTNAME":"CHANGE_ME","NS_USER":"CHANGE_ME","NS_KEY":"CHANGE_ME"}' -var='natgwrtid=CHANGE_ME'
```

### Container

```docker
FROM python:3
RUN pip3 install netstorageapi
RUN pip3 install boto3
COPY sync.py /
ENTRYPOINT [ "python", "./sync.py" ]
```

### [Lambda Function](https://github.com/roymartinezblanco/Akamai-s3-ns-sync/blob/master/lambda_function.py)

Lightweight python script that reads s3 events and adds them to SQS queue.

#### Handler
```python
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

```

#### Add to Queue
```python
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
            QueueUrl= os.environ['queueUrl'],
            DelaySeconds=0,
            MessageBody=(json.dumps(record)),
            MessageGroupId=str(int(time.time()))
            
        )
        logger.info ("Record added to queue: {0}".format(record))
    except Exception as e: 
        logger.error ("Error adding record '{0}' to queue: {1}".format(record,e))
        return False
    return True
```
### [Container Worker](https://github.com/roymartinezblanco/Akamai-s3-ns-sync/blob/master/sync.py)

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

## Contribute
Want to contribute? Sure why not! just let me know!

## Author
Me https://roymartinez.dev/
## Licensing
I am providing code and resources in this repository to you under an open-source license. Because this is my repository, the license you receive to my code and resources is from me and not my employer (Akamai).

```
Copyright 2019 Roy Martinez

Creative Commons Attribution 4.0 International License (CC BY 4.0)

http://creativecommons.org/licenses/by/4.0/
```