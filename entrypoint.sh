#!/bin/bash

set -e

if [[ -z "$BUCKET_NAME" ]]; then
  echo "❌ Env var BUCKET_NAME is required"
  exit 1
fi


if [[ -z "$SCW_DEFAULT_REGION" ]]; then
  echo "❌ Default region not specified use fr-par"
  SCW_DEFAULT_REGION="fr-par"
  export SCW_DEFAULT_REGION
fi

echo "👉 Init scw cli..."
scw init project-id=$SCW_PROJECT_ID \
  organization-id=$SCW_ORGANIZATION_ID \
  access-key=$SCW_ACCESS_KEY \
  secret-key=$SCW_SECRET_KEY \
  install-autocomplete=false \
  with-ssh-key=false \
  send-telemetry=false >/dev/null 2>&1

echo "👉 Init mc cli..."
mc alias set s3 https://s3.$SCW_DEFAULT_REGION.scw.cloud $SCW_ACCESS_KEY $SCW_SECRET_KEY --api S3v4 >/dev/null 2>&1

echo "✅ Environment ready !"

function delete_snapshot_id() {
  scw instance snapshot delete $1 || true
  echo "⚠️ Snapshot \"$1\" have been deleted"
}

function create_snapshot_from_volume_id() {
  SERVER_NAME=$(scw instance volume get $1 -o json | jq -r .volume.server.name)
  echo "👉 Selecting volume \"$1\" with name \"$SERVER_NAME\""
  SNAPSHOT_NAME="snp_${SERVER_NAME}_$(date +'%d_%m_%Y__%H_%M_%S')"
  echo "👀 Creating snapshot \"$SNAPSHOT_NAME\" now"
  SNAPSHOT_ID=$(scw instance snapshot create -o json tags.0=to-delete name=$SNAPSHOT_NAME volume-id=$1 | jq -r '.snapshot.id')
  echo "✨ Snapshot \"$SNAPSHOT_ID\" created. Waiting to become available."
  scw instance snapshot wait $SNAPSHOT_ID >/dev/null 2>&1
  echo "✅ Snapshot \"$SNAPSHOT_ID\" is available. Exporting to bucket s3..."
  S3_OBJECT_KEY="$SCW_DEFAULT_ZONE/$SERVER_NAME/$(date +'%Y')/$(date +'%m')/$(date +'%d')/$SNAPSHOT_NAME.qcow"
  scw instance snapshot export snapshot-id=$SNAPSHOT_ID bucket=$BUCKET_NAME key=$S3_OBJECT_KEY >/dev/null 2>&1
  echo "🔐 Snapshot export s3 task created \"$S3_OBJECT_KEY\""
}

echo "🎯 Deleting obsolete snapshots"

for sid in $(scw instance snapshot list -o json tags=to-delete | jq -r '.[].id')
do
  delete_snapshot_id $sid
done

echo "🎯 Creating snapshots based on server list"

for tag in $(echo $TAG_SELECTOR | tr ',' ' '); do
    for vid in $(scw instance server list -o json state=running tags.0=$tag | jq -r '.[].volumes[].id'); do
        create_snapshot_from_volume_id $vid
    done
done


echo "🎯 Removing old unused snapshots"
mc rm --recursive --force s3/$BUCKET_NAME --older-than 7d || true

if [[ ! -z "$HEARTBEAT_URL" ]]; then
  echo "💙 Sending heartbeat to url"
  curl --silent --output /dev/null $HEARTBEAT_URL
fi

echo "✅ Done !"
