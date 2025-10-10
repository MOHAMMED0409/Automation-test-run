# resource "null_resource" "create_tables" {
#   depends_on = [aws_db_instance.prod_db]

#   provisioner "local-exec" {
#     command = <<EOT
# mysql -h ${aws_db_instance.prod_db.address} \
#       -P 3306 \
#       -u ${var.db_username} \
#       -p${aws_secretsmanager_secret_version.db_password_version.secret_string} \
#       ${var.db_name} \
#       -e "
#       CREATE TABLE IF NOT EXISTS prod_sso (
#         id INT AUTO_INCREMENT PRIMARY KEY,
#         user_name VARCHAR(255),
#         email VARCHAR(255),
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
#       );

#       CREATE TABLE IF NOT EXISTS prod_thepoint (
#         id INT AUTO_INCREMENT PRIMARY KEY,
#         title VARCHAR(255),
#         description TEXT,
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
#       );
#       "
# EOT
#   }
# }
