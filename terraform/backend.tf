terraform {
  backend "gcs" {
    bucket = "tfstate-genai-platform"
    prefix = "terraform/state"
  }
}
