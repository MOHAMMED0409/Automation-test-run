output "rds_endpoint" {
  value = aws_db_instance.prod_db.address
}

output "rds_db_name" {
  value = aws_db_instance.prod_db.db_name
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "rds_endpoint_2" {
  value = aws_db_instance.prod_db_2.address
}

output "rds_db_name_2" {
  value = aws_db_instance.prod_db_2.db_name
}

