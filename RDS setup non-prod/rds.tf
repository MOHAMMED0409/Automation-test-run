resource "aws_db_instance" "non_prod_db" {
  identifier              = "non-prod-database"
  allocated_storage       = 20
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  username                = var.db_username
  password                = aws_secretsmanager_secret_version.db_password_version.secret_string
  db_name                 = var.db_name
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name        = "non-prod-rds"
    Environment = "non-production"
  }
}
