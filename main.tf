# ATTENDANCE

resource "aws_security_group" "attendance_security_group" {
  vpc_id = aws_vpc.ot_microservices_dev.id
  name = "attendance-security-group"

  tags = {
    Name = "attendance-security-group"
  }
  
  ingress {
    from_port        = 8080
    to_port          = 8080
    protocol         = "tcp"
    security_groups = [aws_security_group.alb_security_group.id]
  }

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    security_groups = [aws_security_group.bastion_security_group.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    # ipv6_cidr_blocks = ["::/0"]
  }
}

# instance

resource "aws_instance" "attendance_instance" {
  ami           = "ami-0646a2db03a898068"
  subnet_id = aws_subnet.database_subnet.id
  vpc_security_group_ids = [aws_security_group.attendance_security_group.id]
  instance_type = "t2.micro"
  key_name = "backend"

  tags = {
    Name = "Attendance"
  }
}

# target group and attachment

resource "aws_lb_target_group" "attendance_target_group" {
  name     = "attendnace-tg"
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

# listener rule

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


# launch template for attendance

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
  # ami to be replaced with actual ami currently not right
  image_id      = "ami-05eb8291d90fc00c8"
  instance_type = "t2.micro"

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "AttendanceASG"
    }
  }
}


# auto scaling for attendance

resource "aws_autoscaling_group" "attendance_autoscaling" {
  name                      = "attendance-autoscale"
  max_size                  = 2
  min_size                  = 0
  desired_capacity = 0
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.attendance_launch_template.id
    version = "$Default"
  }
  vpc_zone_identifier = [aws_subnet.application_subnet.id]
  target_group_arns = [aws_lb_target_group.attendance_target_group.arn]
}

resource "aws_autoscaling_policy" "attendance" {
  name                   = "attendance-autoscaling-policy"
  policy_type            = "TargetTrackingScaling"
  adjustment_type        = "ChangeInCapacity"
  estimated_instance_warmup = 300
  autoscaling_group_name = aws_autoscaling_group.attendance_autoscaling.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}