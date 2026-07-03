# App instance "B" — the second backend the ALB routes to. Identical shape to app-a but answers
# "hello from app-b", so you can see which instance served a given request.
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
    ami_id     = "ami-00000000000000000"
    vpc_id     = "vpc-mock"
    subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "security" {
  config_path = "../security"

  mock_outputs = {
    app_security_group_id = "sg-mock"
  }
}

inputs = {
  name      = "alb-routing-lab-app-b"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_ids[0]

  vpc_security_group_ids      = [dependency.security.outputs.app_security_group_id]
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf install -y python3
    cat >/opt/app.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    NAME = "app-b"
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = ("hello from %s (path=%s)\n" % (NAME, self.path)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a):
            pass
    HTTPServer(("0.0.0.0", 80), H).serve_forever()
    PY
    cat >/etc/systemd/system/webapp.service <<'UNIT'
    [Unit]
    Description=demo web app
    After=network.target
    [Service]
    ExecStart=/usr/bin/python3 /opt/app.py
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now webapp
  EOF

  tags = {
    Environment = "lab"
    App         = "app-b"
  }
}
