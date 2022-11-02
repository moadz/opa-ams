#!/bin/bash

# Runs a semi-realistic integration test with a producer generating metrics
# all being authenticated via Hydra and authorized with opa-ams.

set -euo pipefail

result=1
trap 'kill $(jobs -p); exit $result' EXIT

(DSN=memory hydra serve all --dangerous-force-http --disable-telemetry --config ./test/config/hydra.yaml) &

echo "-------------------------------------------"
echo "- Waiting for Hydra to come up...  -"
echo "-------------------------------------------"

until curl --output /dev/null --silent --fail --insecure http://127.0.0.1:4444/.well-known/openid-configuration; do
  printf '.'
  sleep 1
done

echo "-------------------------------------------"
echo "- Registering OIDC clients...         -"
echo "-------------------------------------------"

curl \
    --header "Content-Type: application/json" \
    --request POST \
    --data '{"audience": ["observatorium"], "client_id": "up", "client_secret": "secret", "grant_types": ["client_credentials"], "token_endpoint_auth_method": "client_secret_post"}' \
    http://127.0.0.1:4445/clients

curl \
    --header "Content-Type: application/json" \
    --request POST \
    --data '{"audience": ["observatorium"], "client_id": "read-only", "client_secret": "secret", "grant_types": ["client_credentials"], "token_endpoint_auth_method": "client_secret_post"}' \
    http://127.0.0.1:4445/clients

curl \
    --header "Content-Type: application/json" \
    --request POST \
    --data '{"audience": ["observatorium"], "client_id": "write-only", "client_secret": "secret", "grant_types": ["client_credentials"], "token_endpoint_auth_method": "client_secret_post"}' \
    http://127.0.0.1:4445/clients

curl \
    --header "Content-Type: application/json" \
    --request POST \
    --data '{"audience": ["tollbooth"], "client_id": "opa-ams", "client_secret": "secret", "grant_types": ["client_credentials"], "token_endpoint_auth_method": "client_secret_basic"}' \
    http://127.0.0.1:4445/clients

echo "-------------------------------------------"
echo "- Getting authentication token...         -"
echo "-------------------------------------------"

up_token=$(curl \
    --request POST \
    --silent \
    --url http://127.0.0.1:4444/oauth2/token \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data grant_type=client_credentials \
    --data client_id=up \
    --data client_secret=secret \
    --data audience=observatorium \
    --data scope="openid" | sed 's/^{.*"access_token":[^"]*"\([^"]*\)".*}/\1/')

read_only_token=$(curl \
    --request POST \
    --silent \
    --url http://127.0.0.1:4444/oauth2/token \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data grant_type=client_credentials \
    --data client_id=read-only \
    --data client_secret=secret \
    --data audience=observatorium \
    --data scope="openid" | sed 's/^{.*"access_token":[^"]*"\([^"]*\)".*}/\1/')

write_only_token=$(curl \
    --request POST \
    --silent \
    --url http://127.0.0.1:4444/oauth2/token \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data grant_type=client_credentials \
    --data client_id=write-only \
    --data client_secret=secret \
    --data audience=observatorium \
    --data scope="openid" | sed 's/^{.*"access_token":[^"]*"\([^"]*\)".*}/\1/')

(
  api \
    --web.listen=0.0.0.0:8443 \
    --web.internal.listen=0.0.0.0:8448 \
    --web.healthchecks.url=http://127.0.0.1:8443 \
    --metrics.read.endpoint=http://127.0.0.1:9091 \
    --metrics.write.endpoint=http://127.0.0.1:19291 \
    --rbac.config=./test/config/rbac.yaml \
    --tenants.config=./test/config/tenants.yaml \
    --log.level=debug
) &

(
  thanos receive \
    --receive.hashrings-file=./test/config/hashrings.json \
    --receive.local-endpoint=127.0.0.1:10901 \
    --receive.default-tenant-id="1610b0c3-c509-4592-a256-a1871353dbfa" \
    --grpc-address=127.0.0.1:10901 \
    --http-address=127.0.0.1:10902 \
    --remote-write.address=127.0.0.1:19291 \
    --log.level=error \
    --tsdb.path="$(mktemp -d)"
) &

(
  thanos query \
    --grpc-address=127.0.0.1:10911 \
    --http-address=127.0.0.1:9091 \
    --store=127.0.0.1:10901 \
    --log.level=error \
    --web.external-prefix=.
) &

(
  ams \
      --ams.access-reviews=./test/config/access_reviews.json \
      --oidc.issuer-url=http://localhost:4444/ \
      --oidc.client-id=tollbooth \
      --web.listen=:8082
) &

(memcached -u "$(whoami)") &

(
  ./opa-ams \
      --oidc.issuer-url=http://localhost:4444/ \
      --oidc.client-id=opa-ams \
      --oidc.client-secret=secret \
      --oidc.audience=tollbooth \
      --ams.url=http://127.0.0.1:8082 \
      --ams.mappings=test-oidc=foo \
      --ams.mappings=test-oidc=foo-bar \
      --ams.mappings=test-delegate-authz=bar \
      --opa.package=observatorium \
      --memcached=localhost:11211 \
      --resource-type-prefix=observatorium \
      --web.listen=:8080
) &

echo "-------------------------------------------"
echo "- Waiting for dependencies to come up...  -"
echo "-------------------------------------------"
sleep 10

until curl --output /dev/null --silent --fail http://127.0.0.1:8081/ready; do
  printf '.'
  sleep 1
done

echo "-------------------------------------------"
echo "- Metrics tests                           -"
echo "-------------------------------------------"

if up \
  --listen=0.0.0.0:8888 \
  --endpoint-type=metrics \
  --endpoint-read=http://127.0.0.1:8443/api/metrics/v1/test-oidc/api/v1/query \
  --endpoint-write=http://127.0.0.1:8443/api/metrics/v1/test-oidc/api/v1/receive \
  --period=500ms \
  --initial-query-delay=250ms \
  --threshold=1 \
  --latency=10s \
  --duration=10s \
  --log.level=error \
  --name=observatorium_write \
  --labels='_id="test"' \
  --token="$up_token"; then
  result=0
  echo "-------------------------------------------"
  echo "- tests: OK                               -"
  echo "-------------------------------------------"
else
  result=1
  echo "-------------------------------------------"
  echo "- tests: FAILED                           -"
  echo "-------------------------------------------"
  exit 1
fi

echo "-------------------------------------------"
echo "- Authorization delegation test           -"
echo "-------------------------------------------"

up \
  --listen=0.0.0.0:8888 \
  --endpoint-type=metrics \
  --endpoint-write=http://127.0.0.1:8443/api/metrics/v1/test-delegate-authz/api/v1/receive \
  --period=100ms \
  --threshold=1 \
  --duration=2s \
  --log.level=error \
  --name=observatorium_write \
  --labels='_id="test"' \
  --token="$write_only_token"

if curl \
  --fail \
  --verbose \
  --header "Authorization: bearer $read_only_token" \
  http://127.0.0.1:8443/api/metrics/v1/test-delegate-authz/api/v1/query?query=up; then
  result=0
  echo "-------------------------------------------"
  echo "- test: OK                                -"
  echo "-------------------------------------------"
else
  result=1
  echo "-------------------------------------------"
  echo "- test: FAILED                            -"
  echo "-------------------------------------------"
  exit 1
fi

echo "-------------------------------------------"
echo "- All tests: OK                           -"
echo "-------------------------------------------"
exit 0
