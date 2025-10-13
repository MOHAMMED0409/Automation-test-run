resource "aws_db_instance" "prod_db" {
  identifier              = "prod-database"
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

  # ✅ Enable PITR
  backup_retention_period = 7       # Must be > 0 to enable PITR
  skip_final_snapshot     = false   # Recommended for production
  deletion_protection     = true    # Prevent accidental deletion

  tags = {
    Name        = "prod-rds"
    Environment = "production"
  }
}
