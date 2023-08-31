* VPC
 * Bump default subnets high in CIDR range as it can conflict with default VPC ranges.
 * Add Secrets Manager private VPC endpoint
* Lambda to SQS
 * Single SQS FIFO group ID prevents ECS scaling as only 10 messages can be pulled at a time per group ID preventing parallel processing of the queue.
 * In the case of needing to upload thousands of S3 objects, scaling using parallel uploads to Akamai over exact order is typically preferred (exact order is not guaranteed from S3 delivery to Lambda anyway).
 * A FIFO SQS queue will help with exactly once delivery, as required when uploading large files (why do it twice?) and using a group ID to the EPOCH second will allow for multiple ECS tasks to run in parallel processing the files, 10 at a time, that arrived in that second.
* Lambda logs
 * Logs were not going to CloudWatch logs. Added policy
* Auto Scaling
 * Added step scaling for out/in
* ECS Internet.
 * Recommended approach is to use a private subnet with a NAT GW. Instead of getting to deep into network creation, new variable for a route table that supports NAT GW to assign to the new subnets.
* Container Config
 * Region for logs was hard coded.
 * Added group auto create
