terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
}

variable "access_key" {
  type = string
}

variable "secret_key" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr_block" {
  default = "10.0.0.0/16"
}

provider "aws" {
  access_key = var.access_key
  secret_key = var.secret_key
  region = var.region
}

resource "aws_ecr_repository" "sryoss-ecr-testing" {
  name = "sryoss-ecr-testing"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# build and push repo
locals {
  repo_url = aws_ecr_repository.sryoss-ecr-testing.repository_url
}

resource "null_resource" "image" {
  triggers = {
    hash = md5(join("-", [for x in fileset("", "./{*.py,*.tsx,Dockerfile}") : filemd5(x)]))
  }

  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password | docker login --username AWS --password-stdin ${local.repo_url}
      docker build --platform linux/amd64 -t ${local.repo_url}:latest .
      docker push ${local.repo_url}:latest
    EOF
  }
}

data "aws_ecr_image" "latest" {
  repository_name = aws_ecr_repository.sryoss-ecr-testing.name
  image_tag       = "latest"
  depends_on      = [null_resource.image]
}

# Creating an ECS cluster
resource "aws_ecs_cluster" "sryoss-cluster" {
  name = "sryoss-cluster"
}

# creating an iam policy document for ecsTaskExecutionRole
data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# creating an iam role with needed permissions to execute tasks
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

# attaching AmazonECSTaskExecutionRolePolicy to ecsTaskExecutionRole
resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Creating the task definition
resource "aws_ecs_task_definition" "sryoss-task-testing" {
  family                   = "sryoss-task-testing" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "sryoss-container",
      "image": "${aws_ecr_repository.sryoss-ecr-testing.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3001,
          "hostPort": 3001
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our task requires
  cpu                      = 256         # Specifying the CPU our task requires
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn # Stating Amazon Resource Name (ARN) of the execution role
}

# Providing a reference to our default VPC
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "ap-southeast-1a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "ap-southeast-1b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "ap-southeast-1c"
}

# Creating a load balancer
resource "aws_alb" "sryoss-lb" {
  name               = "sryoss-lb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_default_subnet.default_subnet_a.id}",
    "${aws_default_subnet.default_subnet_b.id}",
    "${aws_default_subnet.default_subnet_c.id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.sryoss-lb_security_group.id}"]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "sryoss-lb_security_group" {
  ingress {
    from_port   = 80 
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0             
    to_port     = 0             
    protocol    = "-1"          
    cidr_blocks = ["0.0.0.0/0"] 
  }
}

# Creating a target group for the load balancer
resource "aws_lb_target_group" "sryoss-target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
  health_check {
    matcher = "200,301,302"
    path    = "/"
  }
}

# Creating a listener for the load balancer
resource "aws_lb_listener" "sryoss-listener" {
  load_balancer_arn = aws_alb.sryoss-lb.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sryoss-target_group.arn # Referencing our target group
  }
}

# Creating the service
resource "aws_ecs_service" "sryoss-service" {
  name            = "sryoss-service"                        
  cluster         = aws_ecs_cluster.sryoss-cluster.id       # Referencing our created Cluster
  task_definition = aws_ecs_task_definition.sryoss-task-testing.arn # Referencing the task our service will spin up
  launch_type     = "FARGATE"
  desired_count   = 1 # Setting the number of containers we want deployed to 3

  load_balancer {
    target_group_arn = aws_lb_target_group.sryoss-target_group.arn # Referencing our target group
    container_name   = "sryoss-container"
    container_port   = 3001 # Specifying the container port
  }

  network_configuration {
    subnets          = ["${aws_default_subnet.default_subnet_a.id}", "${aws_default_subnet.default_subnet_b.id}", "${aws_default_subnet.default_subnet_c.id}"]
    assign_public_ip = true                                                # Providing our containers with public IPs
    security_groups  = ["${aws_security_group.sryoss-service_security_group.id}"] # Setting the security group
  }
}

# Creating a security group for the service
resource "aws_security_group" "sryoss-service_security_group" {
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.sryoss-lb_security_group.id}"]
  }

  egress {
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

output "lb_dns" {
  value       = aws_alb.sryoss-lb.dns_name
  description = "AWS load balancer DNS Name"
}