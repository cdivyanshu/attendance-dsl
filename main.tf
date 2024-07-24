provider "aws" {
  region = "us-west-2"
}

# Define the VPC
resource "aws_vpc" "ot_microservices_dev" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "ot_microservices_dev"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.ot_microservices_dev.id

  tags = {
    Name = "internet-gateway"
  }
}

# Route Table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.ot_microservices_dev.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "route-table"
  }
}

# Associate Route Table with Subnets
resource "aws_route_table_association" "application_subnet_association" {
  subnet_id      = aws_subnet.application_subnet.id
  route_table_id = aws_route_table.route_table.id
}

# Subnets
resource "aws_subnet" "application_subnet" {
  vpc_id            = aws_vpc.ot_microservices_dev.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2b"

  tags = {
    Name = "application-subnet"
  }
}

# ALB Security Group
resource "aws_security_group" "alb_security_group" {
  vpc_id = aws_vpc.ot_microservices_dev.id
  name   = "alb-security-group"

  tags = {
    Name = "alb-security-group"
  }

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

# ALB Load Balancer
resource "aws_lb" "front_end" {
  name               = "frontend-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_security_group.id]
  subnets            = [aws_subnet.application_subnet.id]

  enable_deletion_protection = false

  tags = {
    Name = "frontend-lb"
  }
}

# ALB Listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.front_end.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Default action"
      status_code  = "200"
    }
  }
}

# Define the security group for the employee
resource "aws_security_group" "employee_security_group" {
  vpc_id = aws_vpc.ot_microservices_dev.id
  name   = "employee-security-group"

  tags = {
    Name = "employee-security-group"
  }

  ingress {
    from_port        = 8080
    to_port          = 8080
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb_security_group.id]
  }

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb_security_group.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}

# Define the EC2 instance for the employee
resource "aws_instance" "employee_instance" {
  ami                    = "ami-0cc489ff5815b317c"
  subnet_id              = aws_subnet.application_subnet.id
  vpc_security_group_ids = [aws_security_group.employee_security_group.id]
  instance_type          = "t2.micro"
  key_name               = "backend"

  tags = {
    Name = "employee"
  }
}

# Define the target group for the load balancer
resource "aws_lb_target_group" "employee_target_group" {
  name        = "employee-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.ot_microservices_dev.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold    = 2
    unhealthy_threshold  = 2
  }
}

# Define the target group attachment
resource "aws_lb_target_group_attachment" "employee_target_group_attachment" {
  target_group_arn = aws_lb_target_group.employee_target_group.arn
  target_id        = aws_instance.employee_instance.id
  port             = 8080
}

# Define the listener rule for the load balancer
resource "aws_lb_listener_rule" "employee_rule" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.employee_target_group.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/employee/*"]
    }
  }
}

# Define the launch template for the employee instances
resource "aws_launch_template" "employee_launch_template" {
  name = "employee-template"

  block_device_mappings {
    device_name = "/dev/sdf"

    ebs {
      volume_size = 10
      volume_type = "gp3"
    }
  }

  network_interfaces {
    subnet_id                   = aws_subnet.application_subnet.id
    associate_public_ip_address = false
    security_groups             = [aws_security_group.employee_security_group.id]
  }

  key_name      = "backend"
  image_id      = "ami-0cc489ff5815b317c"
  instance_type = "t2.micro"

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "employeeASG"
    }
  }
}

# Define the auto-scaling group for the employee
resource "aws_autoscaling_group" "employee_autoscaling" {
  name                      = "employee-autoscale"
  max_size                  = 2
  min_size                  = 1
  desired_capacity          = 1
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.employee_launch_template.id
    version = "$Default"
  }
  vpc_zone_identifier = [aws_subnet.application_subnet.id]
  target_group_arns = [aws_lb_target_group.employee_target_group.arn]
}

# Define the auto-scaling policy for the employee
resource "aws_autoscaling_policy" "employee_scaling_policy" {
  name                   = "employee-autoscaling-policy"
  policy_type            = "TargetTrackingScaling"
  adjustment_type        = "ChangeInCapacity"
  estimated_instance_warmup = 300
  autoscaling_group_name = aws_autoscaling_group.employee_autoscaling.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}
