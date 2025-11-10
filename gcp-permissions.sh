#!/bin/bash

# Grant permissions to alejandro@carbonodev.com for the media processor microservice
# Run this script to give Alejandro the necessary GCP permissions

PROJECT_ID="glassy-tube"
USER_EMAIL="alejandro@carbonodev.com"

echo "Granting GCP permissions to $USER_EMAIL for project $PROJECT_ID..."

# Cloud Run permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/run.developer"

# Cloud Build permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/cloudbuild.builds.editor"

# Container Registry permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/storage.admin"

# Logs viewer
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/logging.viewer"

# Cloud Storage for temp files
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/storage.objectAdmin"

echo "Permissions granted successfully!"
echo "Alejandro can now:"
echo "- Deploy and manage the media processor service"
echo "- View logs and monitor the service"
echo "- Access Cloud Build for CI/CD"
echo "- Manage container images"