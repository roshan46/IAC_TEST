resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-database"
  description = "Private database placement across two AZs"
  subnet_ids  = [for subnet in aws_subnet.database : subnet.id]
  tags        = { Name = "${local.name_prefix}-database" }
}

resource "aws_db_parameter_group" "main" {
  name   = "${local.name_prefix}-postgres17"
  family = "postgres17"
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }
}

resource "aws_cloudwatch_log_group" "postgres" {
  name              = "/aws/rds/instance/${local.name_prefix}-db/postgresql"
  retention_in_days = 7
}

resource "aws_db_instance" "main" {
  identifier                  = "${local.name_prefix}-db"
  engine                      = "postgres"
  engine_version              = var.db_engine_version
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "orders"
  username                    = "labadmin"
  manage_master_user_password = true
  port                        = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  multi_az               = false
  availability_zone      = var.availability_zones[0]
  publicly_accessible    = false

  # Temporary lab: explicitly opt into data disposal or name a final snapshot.
  deletion_protection             = false
  skip_final_snapshot             = var.db_skip_final_snapshot
  final_snapshot_identifier       = var.db_final_snapshot_identifier
  delete_automated_backups        = true
  backup_retention_period         = 1
  backup_window                   = "04:00-05:00"
  maintenance_window              = "sun:06:00-sun:07:00"
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = false
  allow_major_version_upgrade     = false
  apply_immediately               = true
  engine_lifecycle_support        = "open-source-rds-extended-support-disabled"
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags       = { Name = "${local.name_prefix}-db" }
  depends_on = [aws_cloudwatch_log_group.postgres]

  lifecycle {
    precondition {
      condition     = var.db_skip_final_snapshot || var.db_final_snapshot_identifier != null
      error_message = "Supply a unique final snapshot identifier when retaining a final snapshot."
    }
  }
}
