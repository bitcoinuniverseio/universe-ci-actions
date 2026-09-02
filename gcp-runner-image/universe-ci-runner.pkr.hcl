# Golden VM image for WarpBuild BYOC runners on GCP Spot.
#
# The runner must arrive ready to work. Nothing in this image is installed at
# job time: every toolchain below was measured from the 218 workflow and action
# files across the 151 repositories in the organization, so the image carries
# what CI actually uses and nothing else.
#
# Build:
#   packer init . && packer build -var-file=versions.pkrvars.hcl .

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

# The build host follows the same capacity rule as the runners it produces.
# PREEMPTIBLE_CPUS is 0 while the project is on the free trial, so a
# preemptible build host cannot start at all. Set this back to true once Spot
# quota exists: an image build is interruptible work that belongs on Spot.
variable "build_on_spot" {
  type    = bool
  default = false
}

locals {
  # The image name pins every version it contains, so a toolchain change
  # produces a new immutable image rather than mutating one in place.
  version_stamp = substr(sha256(join("-", [
    var.node_version, var.npm_version, var.rust_version,
    var.docker_version, var.python_version,
  ])), 0, 12)
}

source "googlecompute" "runner" {
  project_id   = var.project_id
  zone         = var.zone
  source_image_family = "ubuntu-2404-lts-amd64"
  ssh_username = "packer"

  image_name        = "${var.image_family}-${local.version_stamp}"
  image_family      = var.image_family
  image_description = "Universe CI runner. node=${var.node_version} npm=${var.npm_version} rust=${var.rust_version} docker=${var.docker_version} python=${var.python_version}"

  image_labels = {
    managed_by    = "packer"
    purpose       = "ci-runner"
    node_version  = replace(var.node_version, ".", "-")
    docker_version = replace(var.docker_version, ".", "-")
  }

  machine_type = "c3d-highcpu-8"
  preemptible  = var.build_on_spot
  disk_size           = 50
  disk_type           = "pd-balanced"
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

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E env NODE_VERSION='${var.node_version}' NPM_VERSION='${var.npm_version}' RUST_VERSION='${var.rust_version}' DOCKER_VERSION='${var.docker_version}' PYTHON_VERSION='${var.python_version}' {{ .Path }}"
    script          = "verify.sh"
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
