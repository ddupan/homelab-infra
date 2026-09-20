#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
case "$mode" in
  --check | --apply) ;;
  *) echo "usage: $0 [--check|--apply]" >&2; exit 2 ;;
esac

: "${TF_VAR_nexus_url:?set TF_VAR_nexus_url}"
: "${TF_VAR_nexus_username:?set TF_VAR_nexus_username}"
: "${TF_VAR_nexus_password:?set TF_VAR_nexus_password}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
auth_file="$(mktemp /tmp/nexus-oci-auth.XXXXXX)"
trap 'rm -f -- "$auth_file"' EXIT
chmod 0600 "$auth_file"
printf 'machine %s\nlogin %s\npassword %s\n' \
  "${TF_VAR_nexus_url#*://}" "$TF_VAR_nexus_username" \
  "$TF_VAR_nexus_password" >"$auth_file"

drift=0
for entry in \
  "hosted:$script_dir/oci/oci-hosted.json" \
  "proxy:$script_dir/oci/oci-proxy.json" \
  "group:$script_dir/oci/oci-public.json"; do
  repository_type="${entry%%:*}"
  desired_file="${entry#*:}"
  repository_name="$(jq -er '.name' "$desired_file")"
  endpoint="$TF_VAR_nexus_url/service/rest/v1/repositories/oci/$repository_type"
  current_file="$(mktemp /tmp/nexus-oci-current.XXXXXX)"

  status="$(curl --silent --show-error --netrc-file "$auth_file" \
    --output "$current_file" --write-out '%{http_code}' \
    "$endpoint/$repository_name")"

  if [[ "$status" == 404 ]]; then
    drift=1
    if [[ "$mode" == --apply ]]; then
      curl --fail --silent --show-error --netrc-file "$auth_file" \
        --header 'Content-Type: application/json' \
        --data-binary "@$desired_file" "$endpoint"
      echo "created $repository_name"
    else
      echo "missing $repository_name" >&2
    fi
  elif [[ "$status" == 200 ]]; then
    if jq -e --slurpfile desired "$desired_file" '
      def subset($actual; $wanted):
        if ($wanted | type) == "object" then
          all($wanted | keys[];
            ($actual[.] != null) and subset($actual[.]; $wanted[.]))
        else
          $actual == $wanted
        end;
      subset(.; $desired[0])
    ' "$current_file" >/dev/null; then
      echo "in sync $repository_name"
    else
      drift=1
      if [[ "$mode" == --apply ]]; then
        curl --fail --silent --show-error --netrc-file "$auth_file" \
          --request PUT --header 'Content-Type: application/json' \
          --data-binary "@$desired_file" "$endpoint/$repository_name"
        echo "updated $repository_name"
      else
        echo "drifted $repository_name" >&2
      fi
    fi
  else
    cat "$current_file" >&2
    echo "unexpected HTTP $status for $repository_name" >&2
    exit 1
  fi
  rm -f -- "$current_file"
done

if [[ "$mode" == --check && "$drift" -ne 0 ]]; then
  exit 1
fi
