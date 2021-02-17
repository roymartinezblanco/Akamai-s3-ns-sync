
provider "aws" {
  region = var.region
}


resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket
}

## START SQS QUEUE
resource "aws_sqs_queue" "SQSQueue" {
  content_based_deduplication = "true"
  delay_seconds               = "0"
  fifo_queue                  = "true"
  max_message_size            = "262144"
  message_retention_seconds   = "345600"
  receive_wait_time_seconds   = "0"
  visibility_timeout_seconds  = "30"
  name                        = "s3-object-eventsv2.fifo"
}

## END SQS QUEUE

## START Secret Mananager

resource "aws_secretsmanager_secret" "SecretsManagerSecret" {
    name = "AKAMAI/NETSTORAGEv5"

}
resource "aws_secretsmanager_secret_version" "SecretsManagerSecretVersion" {
    secret_id = aws_secretsmanager_secret.SecretsManagerSecret.arn
    secret_string = jsonencode(var.secret)
}

## END Secret Mananager

## START IAM

resource "aws_iam_policy" "iam_policy_readSecrets" {
  name        = "readSecretsv2"
  path        = "/"
  description = "Allow Reading Secrets"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetRandomPassword",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.SecretsManagerSecret.arn
      },
    ]
  })
}

resource "aws_iam_role" "iam_lambda_sqs" {
  path                 = "/service-role/"
  name                 = "AkamaiNetStorageSync_lambda-sqs"
  assume_role_policy   = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
  max_session_duration = 3600

}
resource "aws_iam_role_policy_attachment" "sqs-full-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_sqs.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_iam_role" "iam_lambda_ecs_task" {
  path                 = "/service-role/"
  name                 = "AkamaiNetStorageSync_ecs_task"
  assume_role_policy   = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
  max_session_duration = 3600

}
resource "aws_iam_role_policy_attachment" "sqs-exec-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}


resource "aws_iam_role" "iam_lambda_ecs_exec" {
    path = "/"
    name = "AkamaiNetStorageSync_ecs_exec"
    assume_role_policy = "{\"Version\":\"2008-10-17\",\"Statement\":[{\"Sid\":\"\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    max_session_duration = 3600

}

resource "aws_iam_role_policy_attachment" "ecs-readSecrets-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_ecs_exec.name
  policy_arn = aws_iam_policy.iam_policy_readSecrets.arn
}
resource "aws_iam_role_policy_attachment" "ecs-exec-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}
resource "aws_iam_role_policy_attachment" "ecr-read-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "s3-read-role-policy-attach" {
  role       = aws_iam_role.iam_lambda_ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

## END IAM 

## START Lambda
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.test_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "media/"

  }
  depends_on = [
    aws_lambda_permission.allow_bucket,
    aws_lambda_function.test_lambda

  ]
}
resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.test_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.bucket.arn
}
resource "aws_lambda_function" "test_lambda" {
  filename      = "lambda_function.zip"
  function_name = "akamai_s3_to_sqs"
  role          = aws_iam_role.iam_lambda_sqs.arn
  handler       = "lambda_function.lambda_handler"

  # The filebase64sha256() function is available in Terraform 0.11.12 and later
  # For Terraform 0.11.11 and earlier, use the base64sha256() function and the file() function:
  # source_code_hash = "${base64sha256(file("lambda_function_payload.zip"))}"
  source_code_hash = filebase64sha256("lambda_function.zip")

  runtime = "python3.8"
  tracing_config {
    mode = "PassThrough"
  }
  environment {
    variables = {
      queueUrl = aws_sqs_queue.SQSQueue.id
    }
  }
}

## END Lambda

## START VPC/Network

resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }
}

resource "aws_vpc" "AkamaiNetStorageSync" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "AkamaiNetStorageSync VPC"
  }
}

resource "aws_security_group" "EC2SecurityGroup" {
  description = "ECS Task Allowed Ports"
  name        = "SG-AkamaiNetStorageSync"

  vpc_id = aws_default_vpc.default.id
  ingress {
      cidr_blocks = [
          "0.0.0.0/0"
      ]
      from_port = 80
      protocol = "tcp"
      to_port = 80
  }
  ingress {
      ipv6_cidr_blocks = [
          "::/0"
      ]
      from_port = 80
      protocol = "tcp"
      to_port = 80
  }
  ingress {
      cidr_blocks = [
          "0.0.0.0/0"
      ]
      from_port = 443
      protocol = "tcp"
      to_port = 443
  }
  ingress {
      ipv6_cidr_blocks = [
          "::/0"
      ]
      from_port = 443
      protocol = "tcp"
      to_port = 443
  }
  egress {
    cidr_blocks = [
      "0.0.0.0/0"
    ]
    from_port = 0
    to_port   = 0
    protocol  = "-1"
  }
}

resource "aws_subnet" "EC2Subnet" {
    availability_zone = "${var.region}b"
    cidr_block = "172.31.30.0/24"
    vpc_id = aws_default_vpc.default.id
    map_public_ip_on_launch = false
    tags = {
      Name = "akamainetstoragesync SUBNET 1"
    }
}

resource "aws_subnet" "EC2Subnet2" {
    availability_zone = "${var.region}a"
    cidr_block = "172.31.50.0/24"
    vpc_id = aws_default_vpc.default.id
    map_public_ip_on_launch = false
    tags = {
      Name = "akamainetstoragesync SUBNET 2"
    }
}

## END VPC/Network


## START ECR Container Repository

resource "aws_ecr_repository" "akamainetstoragesync" {
  name                 = "akamainetstoragesync"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
} 

resource "null_resource" "getCreds" {
  depends_on = [aws_ecr_repository.akamainetstoragesync]
  provisioner "local-exec" {
    command = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${var.accountid}.dkr.ecr.${var.region}.amazonaws.com"
  }
}

resource "null_resource" "buildImage" {
  depends_on = [null_resource.getCreds]
  provisioner "local-exec" {
    command = "docker build -t akamainetstoragesync . -f DockerFile"
  }
}
resource "null_resource" "tagImage" {
  depends_on = [null_resource.buildImage]
  provisioner "local-exec" {
    command = "docker tag akamainetstoragesync:latest ${aws_ecr_repository.akamainetstoragesync.repository_url}:latest"
  }
}
resource "null_resource" "pushImage" {
  depends_on = [null_resource.tagImage]
  provisioner "local-exec" {
    command = "docker push ${aws_ecr_repository.akamainetstoragesync.repository_url}:latest"
  }
}

## END ECR Container Repository
## START ECS Container Service
resource "aws_ecs_cluster" "ECSCluster" {
  name = "AkamaiNetStorageSync"
}
data "template_file" "container" {
    depends_on = [ aws_ecr_repository.akamainetstoragesync ]
    template = "${file("container.json")}"
    vars = {
    /*
      List variable replacement mapping, as defined in 'variables.tf'
    */
    sqs = aws_sqs_queue.SQSQueue.id
    bucket = var.bucket
    region = var.region
    cpcode = var.cpcode
    secret = aws_secretsmanager_secret.SecretsManagerSecret.arn
    repository = aws_ecr_repository.akamainetstoragesync.repository_url
     
  }
}
resource "aws_ecs_task_definition" "AkamaiNetStorageSync_task" {
  depends_on = [
    null_resource.pushImage,
    data.template_file.container
  ]
  container_definitions = data.template_file.container.rendered

  family                = "NetstorageSyncv2"
  task_role_arn         = aws_iam_role.iam_lambda_ecs_task.arn
  execution_role_arn    = aws_iam_role.iam_lambda_ecs_exec.arn
  network_mode          = "awsvpc"
  requires_compatibilities = [
    "FARGATE"
  ]
  cpu    = "512"
  memory = "4096"
}

resource "aws_ecs_service" "ECSService" {
    depends_on = [aws_ecs_task_definition.AkamaiNetStorageSync_task]
    name = "akamai-netstorage-service"
    cluster = aws_ecs_cluster.ECSCluster.arn
    desired_count = 0
    launch_type = "FARGATE"
    platform_version = "LATEST"
    task_definition = aws_ecs_task_definition.AkamaiNetStorageSync_task.arn
    deployment_maximum_percent = 200
    deployment_minimum_healthy_percent = 100
    network_configuration {
        assign_public_ip = false
        security_groups = [
            aws_security_group.EC2SecurityGroup.id
        ]
        subnets = [
            aws_subnet.EC2Subnet.id,
            aws_subnet.EC2Subnet2.id
        ]
    }
    scheduling_strategy = "REPLICA"
}
## END ECS Container Service