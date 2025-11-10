#!/bin/bash

# Media Processor Microservice - Google Cloud Setup Script
# Run this script to set up the Google Cloud resources

set -e

PROJECT_ID="glassy-tube"
SERVICE_NAME="media-processor"
REGION="us-central1"

echo "Setting up Google Cloud resources for $SERVICE_NAME..."

# Set the project
gcloud config set project $PROJECT_ID

# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable cloudbuild.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable containerregistry.googleapis.com

# Create Cloud Storage bucket for temporary file storage (optional)
echo "Creating Cloud Storage bucket for temporary files..."
gsutil mb -p $PROJECT_ID -c STANDARD -l $REGION gs://$PROJECT_ID-media-temp || echo "Bucket may already exist"

# Set up Cloud Build trigger (requires GitHub connection)
echo "Setting up Cloud Build trigger..."
echo "Note: You'll need to connect your GitHub repository manually in the Cloud Console"
echo "Go to: https://console.cloud.google.com/cloud-build/triggers"

# Grant Cloud Build permissions to deploy to Cloud Run
echo "Granting Cloud Build permissions..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member=serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com \
    --role=roles/run.admin

gcloud iam service-accounts add-iam-policy-binding \
    $PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --member=serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com \
    --role=roles/iam.serviceAccountUser

echo "Setup complete!"
echo "Next steps:"
echo "1. Connect GitHub repository to Cloud Build"
echo "2. Create a trigger for the main branch"
echo "3. Push code to trigger first deployment"
echo ""
echo "Service will be available at: https://$SERVICE_NAME-$(gcloud config get-value project)-$REGION.a.run.app"