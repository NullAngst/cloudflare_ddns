#!/bin/bash
# Cloudflare DDNS Updater Script (Multi-Record, Dual Stack)
# Requires: curl, jq

set -euo pipefail

# Configuration variables
AUTH_TOKEN='YOUR_API_TOKEN_HERE'
ZONE_ID='YOUR_ZONE_ID'
LOG_FILE="${LOG_FILE:-/var/log/cloudflare_ddns.log}"
MAX_RETRIES=3
RETRY_DELAY=5

# DNS Records Configuration
declare -A records_0
records_0[name]='app.example.com'
records_0[enable_v4]=true
records_0[enable_v6]=false
records_0[proxied]=true

NUM_RECORDS=1

# Logging Function
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error Handler
error_exit() {
    log "ERROR" "$@"
    exit 1
}

# Function: Update Record
update_record() {
    local record_type=$1
    local curl_flag=$2
    local record_name=$3
    local proxied=$4
    local retry_count=0

    log "INFO" "Updating $record_type record for $record_name"

    # 1. Fetch public IP with retry logic
    local ip=""
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        ip=$(curl -s $curl_flag https://icanhazip.com 2>/dev/null || true)
        if [[ -n "$ip" ]]; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log "WARN" "Failed to fetch IP (attempt $retry_count/$MAX_RETRIES). Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done

    if [[ -z "$ip" ]]; then
        error_exit "Could not determine public $record_type IP after $MAX_RETRIES attempts"
    fi

    log "INFO" "Current Public $record_type: $ip"

    # 2. Query Cloudflare API for existing record
    local api_response
    retry_count=0
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        api_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$record_type" \
            -H "Authorization: Bearer $AUTH_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
        
        if echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log "WARN" "API call failed (attempt $retry_count/$MAX_RETRIES). Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done

    if ! echo "$api_response" | jq -e '.success' >/dev/null 2>&1; then
        error_exit "Cloudflare API error or authentication failed for $record_name ($record_type). Response: $api_response"
    fi

    # Extract record ID and current IP using jq
    local record_id=$(echo "$api_response" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    local old_ip=$(echo "$api_response" | jq -r '.result[0].content // empty' 2>/dev/null || true)

    if [[ -z "$record_id" ]]; then
        log "WARN" "Record '$record_name' ($record_type) not found in Cloudflare zone. Skipping."
        return 1
    fi

    log "INFO" "Cloudflare $record_type: $old_ip"

    # 3. Compare and Update if needed
    if [[ "$ip" == "$old_ip" ]]; then
        log "INFO" "[$record_name] IP unchanged. No update needed."
        return 0
    fi

    log "INFO" "[$record_name] IP changed ($old_ip to $ip). Updating record..."

    # 4. Update the DNS record
    local update_response
    retry_count=0
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        update_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
            -H "Authorization: Bearer $AUTH_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$record_type\",\"name\":\"$record_name\",\"content\":\"$ip\",\"proxied\":$proxied}" 2>/dev/null || echo '{"success":false}')
        
        if echo "$update_response" | jq -e '.success' >/dev/null 2>&1; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log "WARN" "Update failed (attempt $retry_count/$MAX_RETRIES). Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done

    # Verify update success
    if echo "$update_response" | jq -e '.success' >/dev/null 2>&1; then
        log "INFO" "✓ [$record_name] $record_type record successfully updated to $ip"
        return 0
    else
        error_exit "Update failed for $record_name ($record_type). Response: $update_response"
    fi
}

# Main Execution
log "INFO" "=== Cloudflare DDNS Update Started ==="

# Execution block based on array above
update_record "A" "-4" "${records_0[name]}" "${records_0[proxied]}"

log "INFO" "=== Cloudflare DDNS Update Completed ==="
