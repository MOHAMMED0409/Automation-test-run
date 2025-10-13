# ----------------------------
# 1. Generate a new key pair
# ----------------------------
resource "tls_private_key" "bastion_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "bastion_key" {
  key_name   = "bastion-key-new"
  public_key = tls_private_key.bastion_key.public_key_openssh
}

# Save the private key locally
resource "local_file" "bastion_private_key" {
  content         = tls_private_key.bastion_key.private_key_pem
  filename        = "${path.module}/bastion-key-new.pem"
  file_permission = "0400"
}

# ----------------------------
# 2. Security Group
# ----------------------------
resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Allow SSH access"
  vpc_id      = aws_vpc.main_vpc.id  # existing VPC

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["125.21.10.86/32"]  # your current public IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------
# 3. Bastion EC2
# ----------------------------
resource "aws_instance" "bastion" {
  ami                    = "ami-0360c520857e3138f"  # Amazon Linux 2
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.subnet1.id  # existing public subnet
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  key_name               = aws_key_pair.bastion_key.key_name

  tags = {
    Name = "BastionHost"
  }
}

# # ----------------------------
# # 4. Output Public IP
# # ----------------------------
# output "bastion_public_ip" {
#   value = aws_instance.bastion.public_ip
# }

# # ----------------------------
# # 5. Output Private Key Location
# # ----------------------------
# output "bastion_private_key_path" {
#   value = local_file.bastion_private_key.filename
# }
