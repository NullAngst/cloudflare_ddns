#!/bin/bash
# Cloudflare DDNS Updater Script
# Using API Token (Bearer Auth)

# --- Configuration ---
auth_token="YOUR_API_TOKEN_HERE"
zone_identifier="YOUR_ZONE_ID"
record_name="mydomain.com"
proxied="true"

# --- 1. Get Current Public IP ---
# Using ipv4.icanhazip.com services as requested
# Primary: IPv4 (since this script updates A records)
ip=$(curl -s https://ipv4.icanhazip.com)

# Alternative endpoints:
# ip=$(curl -s https://ipv6.icanhazip.com)

if [[ -z "$ip" ]]; then
    echo "Error: Could not determine public IP."
    exit 1
fi

echo "Current Public IP: $ip"

# --- 2. Get Cloudflare DNS Record ---
# Note: Using "Authorization: Bearer" instead of X-Auth-Key/Email
record_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=$record_name" \
     -H "Authorization: Bearer $auth_token" \
     -H "Content-Type: application/json")

# Check if auth failed (common error with tokens)
if [[ "$record_info" == *"\"success\":false"* ]]; then
    echo "Error: Authentication failed. Check your API Token and Permissions."
    echo "$record_info"
    exit 1
fi

record_identifier=$(echo "$record_info" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
old_ip=$(echo "$record_info" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$record_identifier" ]]; then
    echo "Error: Could not find record for $record_name"
    exit 1
fi

echo "Cloudflare IP: $old_ip"

# --- 3. Compare and Update ---
if [[ "$ip" == "$old_ip" ]]; then
    echo "IP has not changed. No update needed."
    exit 0
fi

echo "IP changed. Updating record..."

update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" \
     -H "Authorization: Bearer $auth_token" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$record_name\",\"content\":\"$ip\",\"proxied\":$proxied}")

if [[ "$update" == *"\"success\":true"* ]]; then
    echo "Success: DNS record updated to $ip"
else
    echo "Error: Update failed."
    echo "$update"
fi
