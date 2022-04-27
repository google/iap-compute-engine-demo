# Copyright 2022 Google LLC
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Set up global variables, data sources, and local variables

module "global_variables" {
  source = "../00-global-variables"
}

data "google_compute_image" "web_server_image" {
  provider = google

  family = module.global_variables.image_family
  project = module.global_variables.image_project
}

data "google_project" "this_project" {
  provider = google
}

locals {
  project_number = data.google_project.this_project.number
}

# Set up network resources

resource "google_compute_network" "vpc_network" {
  provider = google

  name = "demo-vpc"
  description = "VPC for the resources for the IAP demo"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpc_subnet" {
  provider = google

  name = "demo-subnet"
  description = "Subnet for the web servers for the IAP demo VPC"
  ip_cidr_range = "10.100.10.0/24"
  network = google_compute_network.vpc_network.id
}

resource "google_compute_firewall" "fw_tunneled_ssh_traffic" {
  provider = google

  name = "fw-tunneled-ssh-traffic"
  description = "Firewall to allow tunneled SSH traffic"

  network = google_compute_network.vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [ "35.235.240.0/20" ]
}

resource "google_compute_firewall" "fw_healthcheck_and_proxied_traffic" {
  provider = google

  name = "fw-healthcheck-and-proxied-traffic"
  description = "Firewall rule to allow health checks and proxied traffic"

  network = google_compute_network.vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = [ "130.211.0.0/22", "35.191.0.0/16" ]
}

resource "google_compute_router" "vpc_router" {
  provider = google

  name = "demo-router"
  region = google_compute_subnetwork.vpc_subnet.region
  network = google_compute_network.vpc_network.id
}

resource "google_compute_router_nat" "nat" {
  provider = google

  name = "my-router-nat"
  router = google_compute_router.vpc_router.name
  region = google_compute_router.vpc_router.region
  nat_ip_allocate_option = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Set up compute

# web_server_template - instance template for creating a web server
# 
# startup-script - Meta data key to install Apache and a home page
#
# The home page consists of the instance's name and internal IP address.
#
# Notes:
#
# (1) There are nested heredocs below, including the definition of the script
#     (delimited by SCRIPT) and the creation of the home page (delimited by
#     EOF).
# (2) The SCRIPT heredoc begins with "<<-" to strip off leading spaces.
#     If you remove the "-" from "<<-", the heredoc will include the leading
#     spaces and will not load properly.

resource "google_compute_instance_template" "web_server_template" {
  provider = google

  name_prefix = "demo-template-"
  description = "Instance template for the web servers"
  region = module.global_variables.region
  machine_type = module.global_variables.machine_type

  network_interface {
    subnetwork = google_compute_subnetwork.vpc_subnet.self_link
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  disk {
    boot = true
    source_image = data.google_compute_image.web_server_image.self_link
  }

  metadata = {
    enable_oslogin = "TRUE"
    startup-script = <<-SCRIPT
      #!/bin/bash
      MD_URL="http://metadata.google.internal/computeMetadata/v1/instance"
      MD_HEADER="Metadata-Flavor: Google"
      #
      INSTANCE_ID=$(curl $MD_URL/id -H "$MD_HEADER")
      INSTANCE_NAME=$(curl $MD_URL/name -H "$MD_HEADER")
      INTERNAL_IP=$(curl $MD_URL//network-interfaces/0/ip -H "$MD_HEADER")
      #
      apt update
      apt -y install apache2
      cat <<EOF > /var/www/html/index.html
      <html>
      <body>
      <h1>Instance name: $INSTANCE_NAME</h1>
      <h1>Internal IP: $INTERNAL_IP</h1>
      <h1>Instance ID: $INSTANCE_ID</h1>
      </body>
      </html>
      EOF
      SCRIPT
  }
}

resource "google_compute_instance_from_template" "web_server" {
  provider = google

  name = "demo-web-server"
  description = "Web server for unmanaged instanced group for load balancer"

  zone = module.global_variables.zone
  source_instance_template = (
    google_compute_instance_template.web_server_template.id
  )
}

resource "google_compute_instance_group" "web_server_instance_group" {
  provider = google

  name        = "demo-web-server-group"
  description = "Unmanaged instance group containing the web server"

  instances = [
    google_compute_instance_from_template.web_server.id
  ]

  named_port {
    name = "http"
    port = "80"
  }

  zone = module.global_variables.zone
}

# Set up HTTPS global load balancer

resource "google_compute_health_check" "load_balancer_health_check" {
  provider = google

  name = "demo-load-balancer-health-check"
  description = "Health check for load balancer web servers"

  timeout_sec = 3
  check_interval_sec = 3
  healthy_threshold = 1
  unhealthy_threshold = 2

  http_health_check {
    port_name = "http"
    port_specification = "USE_NAMED_PORT"
    request_path = "/"
    proxy_header = "NONE"
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "web_server_backend_service" {
  provider = google

  name = "demo-web-server-backend-service"
  description = "Backend service that points to the web server backend"

  load_balancing_scheme = "EXTERNAL"
  health_checks = [
    google_compute_health_check.load_balancer_health_check.id
  ]
  port_name = "http"
  protocol = "HTTP"

  backend {
    description = "Backend for the web server instance group"

    group = google_compute_instance_group.web_server_instance_group.id
  }

  iap {
    oauth2_client_id = google_iap_client.demo_iap_client.client_id
    oauth2_client_secret = google_iap_client.demo_iap_client.secret
  }
}

# default_url_map - define the URL map for the load balancer
#
# Notes:
#
# (1) The name of the URL map appears as the name of the load balancer in the
#     console.
#
# (2) All paths go to the backend web service.

resource "google_compute_url_map" "default_url_map" {
  provider = google

  name = "demo-load-balancer-url-map"
  description = "URL map for load balancer,no changes to paths"

  default_service = (
    google_compute_backend_service.web_server_backend_service.id
  )
}

resource "google_compute_global_address" "external_load_balancer_ip" {
  provider = google

  name = "demo-external-load-balancer-ip"
  description = "IP address is for frontend of forwarding rule"
}

resource "google_compute_ssl_certificate" "ssl_cert" {
  provider = google

  name_prefix = "demo-certificate-"
  description = "SSL certificate for the load balancer"

  private_key = file(module.global_variables.ssl_private_key_file)
  certificate = file(module.global_variables.ssl_certificate_file)

  lifecycle {
    create_before_destroy = true
  }
}

# ssl_policy - SSL policy for load balancer https proxy
#
# Restrict SSL policy to use a minimum TLS version of 1.2 and also
# limit the ciphers to the MODERN suite.  This will help with
# compliance initiatives.

resource "google_compute_ssl_policy" "ssl_policy" {
  provider = google

  name = "demo-ssl-policy"
  profile = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "https_proxy" {
  provider = google

  name = "demo-https-proxy"
  description = "HTTPS proxy for the backend web servers"

  url_map = google_compute_url_map.default_url_map.id
  ssl_certificates = [google_compute_ssl_certificate.ssl_cert.id]
  ssl_policy = google_compute_ssl_policy.ssl_policy.self_link
}

resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  provider = google

  name = "demo-https-forwarding-rule"
  description = "This forwarding rule is used to handle HTTPS traffic."

  ip_protocol = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range = "443"
  target = google_compute_target_https_proxy.https_proxy.id
  ip_address = google_compute_global_address.external_load_balancer_ip.id
}

# demo_iap_client - OAuth Client for demo
#
# Note:  Since there can be only one brand for each project, the format of the
# brand identifier is well-known and does not need to be imported.  If more
# brands per project are supported in the future, it may become necessary to
# import the brand into Terraform.
#
# See: "iap_brand" in the Google Cloud Terraform registry for more information.

resource "google_iap_client" "demo_iap_client" {
  provider = google

  display_name = "Demo IAP Client"
  brand = "projects/${local.project_number}/brands/${local.project_number}"
}

resource "google_iap_web_backend_service_iam_binding" "iap_web_binding" {
  provider = google

  web_backend_service = (
    google_compute_backend_service.web_server_backend_service.name
  )
  role = "roles/iap.httpsResourceAccessor"
  members = [
    "user:${module.global_variables.iap_test_user}"
  ]
}

resource "google_iap_tunnel_instance_iam_binding" "iap_tunnel_binding" {
  provider = google

  zone = module.global_variables.zone
  instance = google_compute_instance_from_template.web_server.name
  role = "roles/iap.tunnelResourceAccessor"
  members = [
    "user:${module.global_variables.iap_test_user}"
  ]
}
