resource "random_password" "sql_sa" {
  length      = 20
  special     = false # avoids connection-string escaping pain on SQL Server
  upper       = true
  lower       = true
  numeric     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "random_password" "sql_readonly" {
  length      = 20
  special     = false
  upper       = true
  lower       = true
  numeric     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_security_group" "edge_sql" {
  name        = "${var.project_name}-edge-sql"
  description = "SQL Server in the Edge VPC. 1433 from app VPC only."
  vpc_id      = module.edge_vpc.vpc_id

  ingress {
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = [var.app_vpc_cidr]
    description = "Allow SQL Server traffic from app VPC"
  }

  # No public ingress. SSH/management is via SSM Session Manager.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound for package install + docker pull"
  }
}

# Edge VPC needs internet egress for docker pull + package install during boot.
# Smallest footprint: a single NAT-less option using a public subnet for the
# instance with a public IP. Cheaper than a NAT gateway for a 2-week demo.
resource "aws_subnet" "edge_public" {
  vpc_id                  = module.edge_vpc.vpc_id
  cidr_block              = cidrsubnet(var.edge_vpc_cidr, 4, 8)
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-edge-public" }
}

resource "aws_internet_gateway" "edge" {
  vpc_id = module.edge_vpc.vpc_id
  tags   = { Name = "${var.project_name}-edge-igw" }
}

resource "aws_route_table" "edge_public" {
  vpc_id = module.edge_vpc.vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.edge.id
  }
  route {
    cidr_block                = var.app_vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.app_to_edge.id
  }
  tags = { Name = "${var.project_name}-edge-public-rt" }
}

resource "aws_route_table_association" "edge_public" {
  subnet_id      = aws_subnet.edge_public.id
  route_table_id = aws_route_table.edge_public.id
}

# SSM access for the SQL Server EC2.
resource "aws_iam_role" "edge_sql" {
  name = "${var.project_name}-edge-sql"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "edge_sql_ssm" {
  role       = aws_iam_role.edge_sql.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "edge_sql" {
  name = "${var.project_name}-edge-sql"
  role = aws_iam_role.edge_sql.name
}

resource "aws_ebs_volume" "edge_sql_data" {
  availability_zone = var.azs[0]
  size              = var.edge_sql_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.project_name}-edge-sql-data" }
}

locals {
  edge_sql_user_data = <<-EOT
    #!/bin/bash
    set -eux

    # Wait for EBS attachment.
    while [ ! -e /dev/sdf ] && [ ! -e /dev/nvme1n1 ]; do sleep 2; done
    DEVICE=$(ls /dev/nvme1n1 2>/dev/null || echo /dev/sdf)
    if ! blkid "$DEVICE"; then
      mkfs.xfs "$DEVICE"
    fi
    mkdir -p /var/opt/mssql
    echo "$DEVICE /var/opt/mssql xfs defaults,nofail 0 2" >> /etc/fstab
    mount -a
    chown 10001:0 /var/opt/mssql

    # Install Docker.
    dnf -y install docker
    systemctl enable --now docker

    # Pull and run SQL Server 2022. Restart policy handles reboots.
    docker pull mcr.microsoft.com/mssql/server:2022-latest
    docker rm -f mssql 2>/dev/null || true
    docker run -d --name mssql \
      --restart unless-stopped \
      -e "ACCEPT_EULA=Y" \
      -e "MSSQL_SA_PASSWORD=${random_password.sql_sa.result}" \
      -e "MSSQL_PID=Express" \
      -p 1433:1433 \
      -v /var/opt/mssql:/var/opt/mssql \
      mcr.microsoft.com/mssql/server:2022-latest

    # Wait for SQL Server to accept connections, then run bootstrap.
    for i in $(seq 1 30); do
      if docker exec mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa \
          -P "${random_password.sql_sa.result}" -No -Q "SELECT 1" >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done

    docker exec mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa \
      -P "${random_password.sql_sa.result}" -No -Q "
        IF DB_ID('AcmeDemo') IS NULL CREATE DATABASE AcmeDemo;
        GO
        USE AcmeDemo;
        IF OBJECT_ID('dbo.customers') IS NULL
          CREATE TABLE dbo.customers (id INT PRIMARY KEY, name NVARCHAR(100), email NVARCHAR(100));
        IF OBJECT_ID('dbo.orders') IS NULL
          CREATE TABLE dbo.orders (id INT IDENTITY PRIMARY KEY, customer_id INT, amount DECIMAL(10,2), created_at DATETIME2 DEFAULT GETUTCDATE());
        IF NOT EXISTS (SELECT 1 FROM dbo.customers)
          INSERT INTO dbo.customers VALUES
            (1, N'Acme Corp', N'demo@acme.example'),
            (2, N'Globex', N'demo@globex.example'),
            (3, N'Initech', N'demo@initech.example'),
            (4, N'Soylent', N'demo@soylent.example'),
            (5, N'Stark Industries', N'demo@stark.example');
        IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'stakeholder_readonly')
        BEGIN
          CREATE LOGIN stakeholder_readonly WITH PASSWORD = '${random_password.sql_readonly.result}';
          CREATE USER stakeholder_readonly FOR LOGIN stakeholder_readonly;
          GRANT SELECT ON SCHEMA::dbo TO stakeholder_readonly;
        END
      "
  EOT
}

resource "aws_instance" "edge_sql" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.edge_sql_instance_type
  subnet_id              = aws_subnet.edge_public.id
  vpc_security_group_ids = [aws_security_group.edge_sql.id]
  iam_instance_profile   = aws_iam_instance_profile.edge_sql.name
  user_data              = local.edge_sql_user_data

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-edge-sql" }
}

resource "aws_volume_attachment" "edge_sql_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.edge_sql_data.id
  instance_id = aws_instance.edge_sql.id
}
