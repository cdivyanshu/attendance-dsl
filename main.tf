# Provider Configuration
provider "aws" {
  region = "us-west-2"
}

# VPC
resource "aws_vpc" "ot_microservices_dev" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "ot_microservices_dev"
  }
}

# Subnets
resource "aws_subnet" "database_subnet" {
  vpc_id            = aws_vpc.ot_microservices_dev.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name = "database-subnet"
  }
}

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

# Bastion Security Group
resource "aws_security_group" "bastion_security_group" {
  vpc_id = aws_vpc.ot_microservices_dev.id
  name   = "bastion-security-group"

  tags = {
    Name = "bastion-security-group"
  }

  ingress {
    from_port   = 22
    to_port     = 22
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
  subnets            = [aws_subnet.database_subnet.id, aws_subnet.application_subnet.id]

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

# ATTENDANCE

resource "aws_security_group" "attendance_security_group" {
  vpc_id = aws_vpc.ot_microservices_dev.id
  name   = "attendance-security-group"

  tags = {
    Name = "attendance-security-group"
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
    security_groups  = [aws_security_group.bastion_security_group.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    # ipv6_cidr_blocks = ["::/0"]
  }
}

# Instance

resource "aws_instance" "attendance_instance" {
  ami                    = "ami-0075013580f6322a1"
  subnet_id              = aws_subnet.database_subnet.id
  vpc_security_group_ids = [aws_security_group.attendance_security_group.id]
  instance_type          = "t2.micro"
  key_name               = "backend"

  tags = {
    Name = "Attendance"
  }
}

# Target Group and Attachment

resource "aws_lb_target_group" "attendance_target_group" {
  name     = "attendance-tg"
  port     = 80
  protocol = "HTTP"
  target_type = "instance"
  vpc_id   = aws_vpc.ot_microservices_dev.id
}

resource "aws_lb_target_group_attachment" "attendance_target_group_attachment" {
  target_group_arn = aws_lb_target_group.attendance_target_group.arn
  target_id        = aws_instance.attendance_instance.id
  port             = 8080
}

# Listener Rule

resource "aws_lb_listener_rule" "attendance_rule" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 4

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.attendance_target_group.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/attendance/*"]
    }
  }
}

# Launch Template for Attendance

resource "aws_launch_template" "attendance_launch_template" {
  name = "attendance-template"

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
    security_groups             = [aws_security_group.attendance_security_group.id]
  }

  key_name      = "backend"
  image_id      = "ami-0075013580f6322a1"  # Updated AMI ID
  instance_type = "t2.micro"

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "AttendanceASG"
    }
  }
}

# Auto Scaling for Attendance

resource "aws_autoscaling_group" "attendance_autoscaling" {
  name                      = "attendance-autoscale"
  max_size                  = 2
  min_size                  = 0
  desired_capacity          = 0
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.attendance_launch_template.id
    version = "$Default"
  }
  vpc_zone_identifier = [aws_subnet.application_subnet.id]
  target_group_arns = [aws_lb_target_group.attendance_target_group.arn]
}

resource "aws_autoscaling_policy" "attendance" {
  name                        = "attendance-autoscaling-policy"
  policy_type                 = "TargetTrackingScaling"
  adjustment_type             = "ChangeInCapacity"
  estimated_instance_warmup   = 300
  autoscaling_group_name      = aws_autoscaling_group.attendance_autoscaling.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}
