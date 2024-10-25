variable "region" {
  type = string
}

variable "project" {
  type = string
}

variable "short_project_prefix" {
  type = string
}

variable "env" {
  type = string
}

variable "user" {
  type = string
}

variable "scriptpath" {
  type    = string
  default = "./ml-api/startup.sh"
}

variable "publickeypath" {
  type = string
}

variable "endpoint" {
  type = string
}

variable "model" {
  type = string
}

variable "schemas_folder" {
  type = string
}

locals {
  # cleaning up project name to make it friendly to some IDs
  project_prefix = replace(var.project, "-", "_")
}

### BEGIN ENABLING APIS

module  "project_services" {
  source="terraform-google-modules/project-factory/google//modules/project_services"
  project_id  = var.project
  activate_apis  = [
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "config.googleapis.com",
    "documentai.googleapis.com",
    "eventarc.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage-api.googleapis.com",
    "storage.googleapis.com",
  ]
}
### END ENABLING APIS

### Creating local variables
locals {
  bucket_main_name   = "summary-main-${var.project}"
  bucket_docs_name   = "summary-docs-${var.project}"
  webhook_name       = "summary-webhook"
  webhook_sa_name    = "summary-webhook-sa"
  artifact_repo_name = "summary-artifact-repo"
  trigger_name       = "summary-trigge"
  trigger_sa_name    = "summary-trigger-sa"
  ocr_processor_name = "summary-ocr-processor"
  bq_dataset_name    = "summary_dataset"
}

resource "google_storage_bucket" "main" {
  name= local.bucket_main_name
  location= var.region
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "docs" {
  name= local.bucket_docs_name
  location= var.region
  uniform_bucket_level_access = true
}

resource "google_cloudfunctions2_function" "webhook" {
  project  = var.project
  name     = local.webhook_name
  location = var.region

  build_config {
    runtime           = "python312"
    entry_point       = "on_cloud_event"
    docker_repository = google_artifact_registry_repository.webhook_images.id
    source {
      storage_source {
        bucket = google_storage_bucket.main.name
        object = google_storage_bucket_object.webhook_staging.name
      }
    }
  }
  service_config {
    available_memory      = "1G"
    service_account_email = google_service_account.sa.email
    environment_variables = {
      OUTPUT_BUCKET    = google_storage_bucket.main.name
      DOCAI_PROCESSOR  = google_document_ai_processor.ocr.id
      DOCAI_LOCATION   = google_document_ai_processor.ocr.location
      BQ_DATASET       = google_bigquery_dataset.main.dataset_id
      BQ_TABLE         = google_bigquery_table.main.table_id
      LOG_EXECUTION_ID = true
    }
  }
}

resource "google_project_iam_member" "webhook" {
  project = var.project
  member  = google_service_account.sa.member
  for_each = toset([
    "roles/aiplatform.serviceAgent", # https://cloud.google.com/iam/docs/service-agents
    "roles/bigquery.dataEditor",     # https://cloud.google.com/bigquery/docs/access-control
    "roles/documentai.apiUser",      # https://cloud.google.com/document-ai/docs/access-control/iam-roles
  ])
  role = each.key
}
resource "google_artifact_registry_repository" "webhook_images" {
  location      = var.region
  repository_id = local.artifact_repo_name
  format        = "DOCKER"
}

data "archive_file" "webhook_staging" {
  type        = "zip"
  source_dir  = "webhook/"
  output_path = abspath("${path.module}/.tmp/webhook.zip")
  excludes = [
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "__pycache__",
    "env",
  ]
}

resource "google_storage_bucket_object" "webhook_staging" {
  name   = "webhook-staging/${data.archive_file.webhook_staging.output_base64sha256}.zip"
  bucket = google_storage_bucket.main.name
  source = data.archive_file.webhook_staging.output_path
}

resource "google_project_iam_member" "trigger" {
  project = var.project
  member  = google_service_account.sa.member
  for_each = toset([
    "roles/eventarc.eventReceiver", # https://cloud.google.com/eventarc/docs/access-control
    "roles/run.invoker",            # https://cloud.google.com/run/docs/reference/iam/roles
  ])
  role = each.key
}

resource "google_project_iam_member" "gcs_account"{
  project=var.project
  member=google_service_account.sa.member
  role="roles/pubsub.publisher"
  }

resource "google_project_iam_member" "eventarc_agent"{
  project=var.project
  member=google_service_account.sa.member
  role="roles/eventarc.serviceAgent"
}

resource "google_project_service_identity" "eventarc_agent"{
  provider=google-beta
  project=var.project
  service="eventarc.googleapis.com"
}

#--DocumentAI--#
resource "google_document_ai_processor" "ocr"{
  project=var.project
  location="us"
  display_name=local.ocr_processor_name
  type="OCR_PROCESSOR"
  }
#--BigQuery--#
resource "google_bigquery_dataset" "main"{
  project=var.project
  dataset_id=local.bq_dataset_name
  delete_contents_on_destroy=true
  }

resource "google_bigquery_table" "main"{
  project=var.project
  dataset_id=google_bigquery_dataset.main.dataset_id
  table_id="summaries"
  schema=file("${path.module}/schema.json")
  deletion_protection=false
  }

provider "google" {
  project = var.project
  region  = var.region
}

data "google_project" "project" {
  project_id = var.project
}

### BEGIN SERVICE ACCOUNT PERMISSIONS

resource "google_service_account" "sa" {
  account_id = "${var.short_project_prefix}-${var.env}-sa"
  display_name = "${var.project}-${var.env} Service Account"
}

resource "google_project_iam_member" "storage_object_viewer" {
  project = var.project
  role    = "roles/storage.objectViewer"
  member  = google_service_account.sa.member
}

resource "google_project_iam_member" "ai_platform_user" {
  project = var.project
  role    = "roles/aiplatform.user"
  member  = google_service_account.sa.member
}

resource "google_project_iam_member" "compute_instances_get" {
  project = var.project
  role    = "roles/compute.instanceAdmin.v1"
  member  = google_service_account.sa.member
}

### END SERVICE ACCOUNT PERMISSIONS

resource "google_bigquery_dataset" "database" {
  dataset_id    = "${local.project_prefix}_${var.env}_database"
  location      = "US"
}

resource "google_bigquery_table" "data_table" {
  deletion_protection = false
  dataset_id          = google_bigquery_dataset.database.dataset_id
  table_id            = "data_table"
  schema              = file("${var.schemas_folder}/data.json")
}

resource "google_bigquery_table" "predictions_table" {
  deletion_protection = false
  dataset_id          = google_bigquery_dataset.database.dataset_id
  table_id            = "predictions_table"
  schema              = file("${var.schemas_folder}/predictions.json")
}

resource "google_bigquery_table" "ground_truth_table" {
  deletion_protection = false
  dataset_id          = google_bigquery_dataset.database.dataset_id
  table_id            = "ground_truth_table"
  schema              = file("${var.schemas_folder}/groundtruth.json")
}

resource "google_compute_firewall" "ssh" {
  name    = "${var.project}-${var.env}-ssh-firewall"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] 
  target_tags   = ["sshfw"]
}

resource "google_compute_firewall" "webserver" {
  name    = "${var.project}-${var.env}-http-https-firewall"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8080","8051","8501"]
  }

  source_ranges = ["0.0.0.0/0"] 
  target_tags   = ["webserverfw"]
}

resource "google_compute_address" "static_ip" {
  name = "${var.project}-${var.env}-website-address"
}

resource "google_storage_bucket" "api_source" {
  name= "${var.project}-${var.env}-api-source"
  location= "US"
  uniform_bucket_level_access = true
}

data "archive_file" "ml_api" {
  type        = "zip"
  output_path = "${path.module}/ml-api.zip"
  source_dir  = "ml-api/"
}

resource "google_storage_bucket_object" "ml_api" {
  name   = "ml-api.zip"
  bucket = google_storage_bucket.api_source.name
  source = data.archive_file.ml_api.output_path
  depends_on = [ google_storage_bucket.api_source, data.archive_file.ml_api ]
}

resource "google_compute_instance" "ml-api-server" {
  name  = "${var.project}-${var.env}-ml-api"
  machine_type              = "e2-micro"
  zone  = "${var.region}-a"
  tags  = ["sshfw", "webserverfw", "http-server"]
  allow_stopping_for_update = true

   
  boot_disk { 
    initialize_params {
      image = "ubuntu-2004-lts"
    }
  }

  network_interface {
    network = "default"
    
    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  metadata = {
    ssh-keys = "${var.user}:${file(var.publickeypath)}"
    endpoint = var.endpoint
    model    = var.model
    env      = var.env
  }

  metadata_startup_script = file(var.scriptpath)

  service_account {
    email  = google_service_account.sa.email
    scopes = ["sql-admin", "cloud-platform"]
  }

  depends_on = [ google_compute_firewall.ssh, google_compute_firewall.webserver, data.archive_file.ml_api ]
  
}

output "public_ip_address" {
  value = google_compute_address.static_ip.address
}

output "ssh_access_via_ip" {
  value = "ssh ${var.user}@${google_compute_address.static_ip.address}"
}

resource "google_bigquery_dataset" "featurestore_dataset" {
  dataset_id    = "${local.project_prefix}_${var.env}_featurestore_dataset"
  location      = "US"
}

resource "google_bigquery_table" "featurestore_table" {
  deletion_protection = false
  dataset_id = google_bigquery_dataset.featurestore_dataset.dataset_id
  table_id   = "featurestore_table"
  schema     = file("${var.schemas_folder}/featurestore.json")
}

resource "google_vertex_ai_feature_online_store" "featurestore" {
  name   = "${local.project_prefix}_${var.env}_featurestore"
  region = var.region
  optimized {}
  force_destroy = true
}

resource "google_vertex_ai_feature_online_store_featureview" "featureview" {
  name                 = "featureview"
  region               = var.region
  feature_online_store = google_vertex_ai_feature_online_store.featurestore.name
  sync_config {
    cron = "* * * * *" // sync every minute
  }
  big_query_source {
    uri = "bq://${google_bigquery_table.featurestore_table.project}.${google_bigquery_table.featurestore_table.dataset_id}.${google_bigquery_table.featurestore_table.table_id}"
    entity_id_columns = ["entity_id"]
  }
}