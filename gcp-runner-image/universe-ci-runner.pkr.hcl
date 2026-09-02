# Golden VM image for Universe ephemeral GitHub Actions runners on GCP.
#
# The runner must arrive ready to work. Nothing in this image is installed at
# job time: every toolchain below was measured from the workflow and action
# files across the organization, so the image carries what CI actually uses
# and nothing else. runner.sh then adds the GitHub Actions runner agent, the
# boot service that fetches a one-time JIT configuration from the control
# plane, Playwright Chromium, and the Cloud Logging agent.
#
# Build:
#   packer init . && packer build -var-file=versions.pkrvars.hcl -var git_commit=$(git rev-parse --short HEAD) .

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = ">= 1.1.6"
    }
  }
}

variable "project_id" {
  type    = string
  default = "universe-507319"
}
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "image_family" {
  type    = string
  default = "universe-ci-runner"
}

variable "node_version" {
  type = string
}
variable "npm_version" {
  type = string
}
variable "rust_version" {
  type = string
}
variable "docker_version" {
  type = string
}
variable "python_version" {
  type = string
}
variable "runner_version" {
  type = string
}
variable "playwright_version" {
  type = string
}
variable "git_commit" {
  type    = string
  default = "unknown"
}

# The build host is Spot: an image build is interruptible work.
variable "build_on_spot" {
  type    = bool
  default = true
}

locals {
  # The image name pins every version it contains, so a toolchain change
  # produces a new immutable image rather than mutating one in place.
  version_stamp = substr(sha256(join("-", [
    var.node_version, var.npm_version, var.rust_version,
    var.docker_version, var.python_version,
    var.runner_version, var.playwright_version,
  ])), 0, 12)
}

source "googlecompute" "runner" {
  project_id          = var.project_id
  zone                = var.zone
  source_image_family = "ubuntu-2404-lts-amd64"
  ssh_username        = "packer"

  image_name        = "${var.image_family}-${local.version_stamp}"
  image_family      = var.image_family
  image_description = "Universe CI runner. node=${var.node_version} npm=${var.npm_version} rust=${var.rust_version} docker=${var.docker_version} python=${var.python_version} runner=${var.runner_version} playwright=${var.playwright_version} commit=${var.git_commit}"

  image_labels = {
    managed_by     = "packer"
    system         = "universe-ci"
    purpose        = "ci-runner"
    node_version   = replace(var.node_version, ".", "-")
    docker_version = replace(var.docker_version, ".", "-")
    runner_version = replace(var.runner_version, ".", "-")
    git_commit     = var.git_commit
    build_date     = formatdate("YYYY-MM-DD", timestamp())
  }

  machine_type = "c3d-highcpu-8"
  preemptible  = var.build_on_spot
  disk_size    = 50
  disk_type    = "pd-balanced"
  metadata = {
    block-project-ssh-keys = "true"
  }
}

build {
  name    = "universe-ci-runner"
  sources = ["source.googlecompute.runner"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E env NODE_VERSION='${var.node_version}' NPM_VERSION='${var.npm_version}' RUST_VERSION='${var.rust_version}' DOCKER_VERSION='${var.docker_version}' PYTHON_VERSION='${var.python_version}' {{ .Path }}"
    script          = "provision.sh"
  }

  provisioner "file" {
    sources     = ["runner-bootstrap.sh", "universe-runner.service", "ops-agent.yaml"]
    destination = "/tmp/"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E env RUNNER_VERSION='${var.runner_version}' PLAYWRIGHT_VERSION='${var.playwright_version}' {{ .Path }}"
    script          = "runner.sh"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E env NODE_VERSION='${var.node_version}' NPM_VERSION='${var.npm_version}' RUST_VERSION='${var.rust_version}' DOCKER_VERSION='${var.docker_version}' RUNNER_VERSION='${var.runner_version}' PLAYWRIGHT_VERSION='${var.playwright_version}' {{ .Path }}"
    script          = "verify.sh"
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
