#!/usr/bin/env bash
set -euo pipefail

STATE_FILE=".cloudfiles_state"
LOCAL_LOG="${LOCAL_LOG:-cloudfiles_actions.log}"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_local() { echo "$(timestamp) | $*" >> "$LOCAL_LOG"; }

# load state
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_FILE"
else
  echo "State file $STATE_FILE missing. Run deploy_storage.sh first or set env vars." >&2
  exit 1
fi

: "${STORAGE_ACCOUNT:?Need STORAGE_ACCOUNT in $STATE_FILE or env}"
: "${CONTAINER_NAME:?Need CONTAINER_NAME}"
: "${STORAGE_KEY:?Need STORAGE_KEY}"

AZ_COMMON=(--account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY")
# optional remote append log blob path
REMOTE_LOG_BLOB="logs/actions.log"

# Ensure logs append blob exists (creates if not)
ensure_remote_log() {
  # create container path (container exists already)
  if ! az storage blob show "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$REMOTE_LOG_BLOB" &>/dev/null; then
    # create append blob
    az storage blob create "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$REMOTE_LOG_BLOB" --type Append --only-show-errors
  fi
}

append_remote_log() {
  local line="$1"
  # ensure blob exists
  ensure_remote_log
  printf "%s\n" "$line" | az storage blob append "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$REMOTE_LOG_BLOB" --content - --only-show-errors
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  upload)
    local_path="${1:-}"; remote_name="${2:-}"
    if [[ -z "$local_path" ]]; then
      echo "Usage: $0 upload <local_path> [remote_name]" ; exit 1
    fi
    if [[ -z "$remote_name" ]]; then remote_name="$(basename "$local_path")"; fi
    echo "Uploading $local_path -> $remote_name"
    az storage blob upload "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$remote_name" --file "$local_path" --overwrite true --only-show-errors
    line="UPLOAD $local_path -> $remote_name"
    log_local "$line"
    # also append remotely
    append_remote_log "$line"
    echo "Uploaded."
    ;;
  download)
    blob_name="${1:-}"; dest="${2:-.}"
    if [[ -z "$blob_name" ]]; then
      echo "Usage: $0 download <blob_name> [dest_dir]" ; exit 1
    fi
    mkdir -p "$dest"
    az storage blob download "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$blob_name" --file "$dest/$blob_name" --only-show-errors
    line="DOWNLOAD $blob_name -> $dest/$blob_name"
    log_local "$line"
    append_remote_log "$line"
    echo "Downloaded to $dest/$blob_name"
    ;;
  list)
    az storage blob list "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --output table
    log_local "LIST"
    append_remote_log "LIST"
    ;;
  delete)
    blob_name="${1:-}"
    if [[ -z "$blob_name" ]]; then
      echo "Usage: $0 delete <blob_name>" ; exit 1
    fi
    az storage blob delete "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$blob_name" --only-show-errors
    line="DELETE $blob_name"
    log_local "$line"
    append_remote_log "$line"
    echo "Deleted $blob_name"
    ;;
  info)
    blob_name="${1:-}"
    if [[ -z "$blob_name" ]]; then
      echo "Usage: $0 info <blob_name>" ; exit 1
    fi
    az storage blob show "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$blob_name" -o json
    log_local "INFO $blob_name"
    append_remote_log "INFO $blob_name"
    ;;
  sas)
    blob_name="${1:-}"
    expiry="${2:-1h}" # e.g. 1h or 2d
    if [[ -z "$blob_name" ]]; then
      echo "Usage: $0 sas <blob_name> [expiry]" ; exit 1
    fi
    # simple expiry parsing (supports Nh or Nd)
    if [[ "$expiry" =~ ^([0-9]+)h$ ]]; then
      HOURS="${BASH_REMATCH[1]}"
      EXPIRY_DATE=$(date -u -d "+$HOURS hours" +"%Y-%m-%dT%H:%MZ")
    elif [[ "$expiry" =~ ^([0-9]+)d$ ]]; then
      DAYS="${BASH_REMATCH[1]}"
      EXPIRY_DATE=$(date -u -d "+$DAYS days" +"%Y-%m-%dT%H:%MZ")
    else
      # default 1 hour
      EXPIRY_DATE=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%MZ")
    fi
    token=$(az storage blob generate-sas "${AZ_COMMON[@]}" --container-name "$CONTAINER_NAME" --name "$blob_name" --permissions r --expiry "$EXPIRY_DATE" -o tsv)
    sasurl="https://$STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME/$blob_name?$token"
    echo "$sasurl"
    log_local "SAS $blob_name expiry=$EXPIRY_DATE"
    append_remote_log "SAS $blob_name expiry=$EXPIRY_DATE"
    ;;
  help|--help|-h|"")
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  upload <local_path> [remote_name]
  download <blob_name> [dest_dir]
  list
  delete <blob_name>
  info <blob_name>
  sas <blob_name> [expiry]   # expiry e.g. 1h or 2d
EOF
    ;;
  *)
    echo "Unknown command: $cmd" ; exit 1
    ;;
esac
