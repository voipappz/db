# Sourced by backup.sh and restore.sh: the S3/MinIO remote, configured from
# the environment alone (rclone reads RCLONE_CONFIG_<REMOTE>_*), so the image
# carries no config file and no credentials.

export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_S3_TYPE=s3
export RCLONE_CONFIG_S3_PROVIDER="${S3_ENDPOINT:+Minio}"
export RCLONE_CONFIG_S3_PROVIDER="${RCLONE_CONFIG_S3_PROVIDER:-AWS}"
export RCLONE_CONFIG_S3_ENDPOINT="${S3_ENDPOINT:-}"
export RCLONE_CONFIG_S3_REGION="${S3_REGION:-us-east-1}"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
# The bucket is created by whoever owns the store (mothership's createbuckets);
# a missing bucket should fail the run, not be made with default policy.
export RCLONE_S3_NO_CHECK_BUCKET=true

s3_enabled() { [ -n "${S3_BUCKET:-}" ]; }
s3_path() { echo "s3:${S3_BUCKET}/${S3_PREFIX:-postgres}${1:+/$1}"; }
