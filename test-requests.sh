#!/usr/bin/env bash
# Shortens a few sample URLs against a running instance and follows each redirect.
# Usage: ./test-requests.sh [base-url]   (default base-url: http://localhost:8080)
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"

SAMPLE_URLS=(
  "https://www.anthropic.com"
  "https://spring.io"
  "https://openjdk.org"
)

for url in "${SAMPLE_URLS[@]}"; do
  echo "Shortening: $url"
  response=$(curl -s -X POST "$BASE_URL/api/urls" \
    -H "Content-Type: application/json" \
    -d "{\"url\": \"$url\"}")
  echo "  -> $response"

  short_code=$(echo "$response" | grep -oP '(?<="shortCode":")[^"]+')
  redirect=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE_URL/$short_code")
  echo "  -> GET /$short_code redirects to: $redirect"
  echo
done
