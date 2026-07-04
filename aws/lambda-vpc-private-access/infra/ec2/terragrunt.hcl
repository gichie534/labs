# The private "backend" the Lambda will reach. A single EC2 instance in a PRIVATE subnet, with NO
# public IP and no inbound path except from the Lambda SG. At boot it starts a tiny HTTP server on
# :8080 (Python's stdlib http.server, already present on Amazon Linux 2023 — no internet egress
# needed) that returns the instance's own identity as JSON. That JSON is the "private info" the
# Lambda reads to prove it has network access to a private VPC resource.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ec2-instance?ref=aws-ec2-instance-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    ami_id = "ami-00000000000000000"
    azs    = ["us-east-1a", "us-east-1b"]
  }
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
  }
}

dependency "sg_ec2" {
  config_path = "../sg/ec2"

  mock_outputs = {
    id = "sg-mockec2"
  }
}

inputs = {
  name      = "lambda-vpc-private-access"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.vpc.outputs.private_subnet_ids[0]

  vpc_security_group_ids = [dependency.sg_ec2.outputs.id]

  # Private instance: no public IP (it lives in a private subnet with no NAT).
  associate_public_ip_address = false

  # Serve the instance's identity as JSON on :8080 using only the stdlib http server (present in the
  # AMI), so no package install / internet egress is required.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    cat >/opt/info-server.py <<'PY'
    import http.server, json, socket, urllib.request

    def imds(path):
        try:
            token = urllib.request.urlopen(urllib.request.Request(
                "http://169.254.169.254/latest/api/token",
                method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
            ), timeout=2).read().decode()
            return urllib.request.urlopen(urllib.request.Request(
                "http://169.254.169.254/latest/meta-data/" + path,
                headers={"X-aws-ec2-metadata-token": token},
            ), timeout=2).read().decode()
        except Exception as e:
            return "unknown"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({
                "message": "hello from a private EC2 instance",
                "hostname": socket.gethostname(),
                "instance_id": imds("instance-id"),
                "private_ip": imds("local-ipv4"),
                "availability_zone": imds("placement/availability-zone"),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
    cat >/etc/systemd/system/info-server.service <<'UNIT'
    [Unit]
    Description=Private info HTTP server
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/info-server.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now info-server.service
  EOF

  tags = {
    Environment = "lab"
  }
}
