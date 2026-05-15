#!/usr/bin/env bash

# Abort script at first error, when a command exits with non-zero status
set -e -o pipefail
# Echo each command before executing it
set -x
# Attempt to use undefined variable outputs error message, and forces an exit
set -u

# Default values
ENVIRONMENT=""
DATA_SET_SIZE="LARGE_YAHOO"
SHARD=""
DARK_FEATURES=""
MIGRATION_SCOPE_OPTION=""
BLOCK_BEFORE_RUNNING="NO"
USER_MIGRATION_MODE=""
AUTHOR=""

# Function to display usage information
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "OPTIONS:"
  echo "  -e, --environment       ENVIRONMENT  Environment to use (staging or prod) [required]"
  echo "  -d, --data-set          DATA_SET     Data set size to use [default: LARGE_YAHOO]"
  echo "  -s, --shard             SHARD        Shard name to use [optional]"
  echo "  --dark-features         FEATURES     Comma-delimited list of dark feature flags [optional]"
  echo "  -m, --migration-scope   SCOPE        Migration scope option [optional]"
  echo "  -u, --user-migration-mode MODE       User migration mode [optional]"
  echo "  -b, --block-running     YES/NO       Block migration from starting [default: NO]"
  echo "  -a, --author            AUTHOR       Author name [optional]"
  echo "  -h, --help                           Display this help message"
  exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    -d|--data-set)
      DATA_SET_SIZE="$2"
      shift 2
      ;;
    -s|--shard)
      SHARD="$2"
      shift 2
      ;;
    --dark-features)
      DARK_FEATURES="$2"
      shift 2
      ;;
    -m|--migration-scope)
      MIGRATION_SCOPE_OPTION="$2"
      shift 2
      ;;
    -u|--user-migration-mode)
      USER_MIGRATION_MODE="$2"
      shift 2
      ;;
    -b|--block-running)
      BLOCK_BEFORE_RUNNING="$2"
      shift 2
      ;;
    -a|--author)
      AUTHOR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Check if required arguments are provided
if [[ -z "$ENVIRONMENT" ]]; then
    echo "Error: Environment is required"
    usage
fi

# Install jq if not available
if ! [ -x "$(command -v jq)" ]; then
  echo "jq not installed, installing now"
  apt-get update
  apt-get install -y jq
fi

# Install atlas if not available
if ! [ -x "$(command -v ./atlas)" ]; then
  echo "atlas not installed, installing now"
  curl -fL https://statlas.prod.atl-paas.net/atlas-cli/linux/atlas-latest-linux-amd64.tar.gz | tar -xzp atlas
  ./atlas plugin install -n slauth
fi

# Set endpoint based on environment
if [ "$ENVIRONMENT" = "staging" ]; then
  PERF_ENDPOINT="https://migration-scale-perf-test.us-east-1.staging.atl-paas.net"
else
  PERF_ENDPOINT="https://migration-scale-perf-test.us-west-2.prod.atl-paas.net"
fi

# Path of the snapshot jar when it is built
JAR_FOLDER="jira-migration-plugin/target"
JAR_PATH="$(find $JAR_FOLDER -name "*-SNAPSHOT*.jar" -maxdepth 1 -print -quit)"

echo $JAR_PATH

COMMIT_HASH=$(git rev-parse --short HEAD)

PERF_ENDPOINT="$PERF_ENDPOINT/performance-test/start/JIRA?commitHash=$COMMIT_HASH&dataSetSize=$DATA_SET_SIZE"

# Add shardName parameter if SHARD is set
if [[ -n "$SHARD" ]]; then
    PERF_ENDPOINT="${PERF_ENDPOINT}&shardName=$SHARD"
fi

# Add migrationScopeOption parameter if MIGRATION_SCOPE_OPTION is set
if [[ -n "$MIGRATION_SCOPE_OPTION" ]]; then
    PERF_ENDPOINT="${PERF_ENDPOINT}&migrationScopeOption=$MIGRATION_SCOPE_OPTION"
fi

if [[ -n "$AUTHOR" ]]; then
    # URL encode the author parameter using printf to avoid newline and format string issues
    ENCODED_AUTHOR=$(printf '%s' "$AUTHOR" | jq -sRr @uri)
    PERF_ENDPOINT="${PERF_ENDPOINT}&author=$ENCODED_AUTHOR"
fi

# Add migrationOverrides.userMigrationMode parameter if USER_MIGRATION_MODE is set
if [[ -n "$USER_MIGRATION_MODE" ]]; then
    PERF_ENDPOINT="${PERF_ENDPOINT}&migrationOverrides.userMigrationMode=$USER_MIGRATION_MODE"
fi

# Add feature flags, one parameter per flag
if [[ -n "$DARK_FEATURES" ]]; then
    # Split by comma, trim spaces and add each flag individually
    IFS=',' read -ra FLAGS <<< "$DARK_FEATURES"
    for flag in "${FLAGS[@]}"; do
        # Trim leading and trailing whitespaces
        flag=$(echo "$flag" | xargs)
        if [[ -n "$flag" ]]; then
            PERF_ENDPOINT="${PERF_ENDPOINT}&featureFlags=$flag"
        fi
    done
fi

# Add query parameter for preventing test migration if BLOCK_BEFORE_RUNNING is set to YES or true
if [[ "$BLOCK_BEFORE_RUNNING" == "YES" || "$BLOCK_BEFORE_RUNNING" == "true" ]]; then
    PERF_ENDPOINT="${PERF_ENDPOINT}&migrationOverrides.preventTestMigrationFromStarting=true"
    echo "Will prevent the test migration from starting automatically"
fi

# Form parameters now only include the JAR file
FORM_PARAMS=("cmaJar=@$JAR_PATH")

# Construct the curl command with all form parameters
FORM_PARAM_STR=$(printf -- "--form %s " "${FORM_PARAMS[@]}")

RESPONSE=$(./atlas slauth curl -a migration-scale-perf-test -- -X POST --url "$PERF_ENDPOINT" --header "content-type: multipart/form-data" $FORM_PARAM_STR)

# Check if success is true using jq
if ! echo "$RESPONSE" | jq -e '.data.success == true' > /dev/null; then
    echo "Error: API call to create a new migration for commit $COMMIT_HASH was not successful"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "Success: API call completed successfully"