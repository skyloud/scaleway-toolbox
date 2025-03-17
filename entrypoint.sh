#!/bin/bash

set -e

if [[ -z "$BUCKET_NAME" ]]; then
  echo "❌ Env var BUCKET_NAME is required"
  exit 1
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
mc alias set s3 https://s3.fr-par.scw.cloud $SCW_ACCESS_KEY $SCW_SECRET_KEY --api S3v4 >/dev/null 2>&1

echo "✅ Environment ready !"

function delete_snapshot_id() {
  scw instance snapshot delete $1 || true
  echo "⚠️ Snapshot \"$1\" have been deleted"
}

function export_snapshot_with_retry() {
  local snapshot_id="$1"
  local bucket_name="$2"
  local object_key="$3"

  local max_attempts=50
  local attempts=0
  local sleep_seconds=60

  while true; do
    echo "🔄 Attempting export of snapshot \"$snapshot_id\" (attempt $((attempts+1))/$max_attempts)"
    if scw instance snapshot export snapshot-id=$snapshot_id bucket=$bucket_name key=$object_key; then
      echo "🔐 Snapshot export s3 task created \"$object_key\""
      break
    else
      attempts=$((attempts+1))
      if [ $attempts -ge $max_attempts ]; then
        echo "❌ Snapshot export failed after $max_attempts attempts. Exiting."
        exit 1
      fi
      echo "🐌 Snapshot export failed. Retrying in $sleep_seconds seconds..."
      sleep $sleep_seconds
    fi
  done
}

function create_snapshot_from_volume_id() {
  SERVER_NAME=$(scw instance volume get $1 -o json | jq -r .volume.server.name)
  echo "👉 Selecting volume \"$1\" with name \"$SERVER_NAME\""
  SNAPSHOT_NAME="snp_${SERVER_NAME}_$(date +'%d_%m_%Y__%H_%M_%S')"
  echo "👀 Creating snapshot \"$SNAPSHOT_NAME\" now"
  SNAPSHOT_ID=$(scw instance snapshot create -o json tags.0=to-delete name=$SNAPSHOT_NAME volume-id=$1 | jq -r '.snapshot.id')
  echo "✨ Snapshot \"$SNAPSHOT_ID\" created. Waiting to become available."
  scw instance snapshot wait $SNAPSHOT_ID
  echo "✅ Snapshot \"$SNAPSHOT_ID\" is available. Exporting to bucket s3..."
  S3_OBJECT_KEY="$SCW_DEFAULT_ZONE/$SERVER_NAME/$(date +'%Y')/$(date +'%m')/$(date +'%d')/$SNAPSHOT_NAME.qcow"
  echo "👉 Snapshot \"$SNAPSHOT_ID\" will be exported here : \"$BUCKET_NAME/$S3_OBJECT_KEY\""
  export_snapshot_with_retry "$SNAPSHOT_ID" "$BUCKET_NAME" "$S3_OBJECT_KEY"
  echo "✅ Export volume task is now pending"
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
