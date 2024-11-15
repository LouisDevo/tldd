provider "google" {
  project = var.project
  region  = var.region
}

resource "google_storage_bucket" "tldd" {
  name     = var.pdf_bucket
  location = var.region
}

resource "google_storage_bucket" "tldd-frontend" {
  name     = "gcs-tldd-extension-bucket"
  location = var.region
}

terraform {
  backend "gcs" {
    bucket = "spectacles-tldd_tf_state"
    prefix = "tldd"
  }
}

resource "google_artifact_registry_repository" "tldd" {
  provider = google
  format   = "DOCKER"
  location = var.region
  repository_id = "tldd"
  description   = "Artifact Registry for tldd"
  project = var.project
}

resource "google_secret_manager_secret" "resend_api_key" {
  secret_id = "resend-api-key"
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_firestore_database" "tldd" {
  name     = "tldd"
  project  = var.project
  location_id = var.region
  type     = "FIRESTORE_NATIVE"
}

resource "google_service_account" "tldd" {
  account_id = "sa-tldd-cloud-run"
  project    = var.project
}

data "google_iam_policy" "tldd-firestore"{
  binding {
    role = "roles/datastore.user"
    members = ["serviceAccount:${google_service_account.tldd.email}"]
  }
}

data "google_iam_policy" "tldd-pdf-bucket" {
  binding {
    role = "roles/storage.objectViewer"
    members = ["serviceAccount:${google_service_account.tldd.email}"]
  }
}

data "google_iam_policy" "tldd-pdf-secrets" {
  binding {
    role = "roles/secretmanager.secretAccessor"
    members = ["serviceAccount:${google_service_account.tldd.email}"]
  }
}

resource "google_storage_bucket_iam_policy" "tldd-pdf-bucket-policy" { 
  bucket = google_storage_bucket.tldd.name
  policy_data = data.google_iam_policy.tldd-pdf-bucket.policy_data
}

resource "google_cloud_run_service" "tldd" {
  name     = "tldd"
  location = var.region


  template {
    
    spec {
      service_account_name = google_service_account.tldd.email  # It may say name, but the docs say email!
      containers {
        image = "${var.region}-docker.pkg.dev/${var.project}/tldd/tldd:${var.run_hash}"
        ports {
          container_port = 8000
        }
        env {
          name = "RESEND_API_KEY"
          value_from {
            secret_key_ref {
              name = google_secret_manager_secret.resend_api_key.secret_id
              key  = "latest"
            }
          }
        }
        env {
          name  = "PDF_BUCKET"
          value = var.pdf_bucket
        }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  autogenerate_revision_name = true

  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
  }
}

resource "google_cloud_run_service_iam_member" "tldd_invoker" {
  service = google_cloud_run_service.tldd.name
  location = google_cloud_run_service.tldd.location
  role    = "roles/run.invoker"
  member  = "allUsers"
}
