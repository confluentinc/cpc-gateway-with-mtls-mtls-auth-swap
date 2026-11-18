#!/usr/bin/env bash
# Core cluster: read-only Schema Registry leader, MDS internal NLB for the DMZ followers, and the schema link from the
# core registry (exporter dmz-readonly, all subjects, same names and IDs). Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_passwords
load_tf_outputs
EXPORTER=dmz-readonly

step "Certificates (sr-ro leader, sr-dmz followers)"
apply_core "$HERE/certificates.yaml"
kcore -n confluent wait certificate/schemaregistry-ro certificate/schemaregistry-dmz --for=condition=Ready --timeout=180s

step "MDS internal NLB (mds.$PRIVATE_ZONE:8090, DMZ private subnets only)"
apply_core "$HERE/mds-lb.yaml"

step "Role bindings on the read-only cluster"
apply_core "$HERE/rbac.yaml"
wait_rolebindings sr-dmz-ro-cluster sr-dmz-ro-store sr-dmz-license-read sr-dmz-license-write sr-exporter-ro-subjects \
  sr-ro-dek-registry-topic alice-ro-demo-subjects-read testadmin-ro-systemadmin

step "Read-only Schema Registry leader"
apply_core "$HERE/schemaregistry-ro.yaml"
kcore -n confluent wait schemaregistry/schemaregistry-ro --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s

sr_admin_open schemaregistry-ro 18091
sr_admin_open schemaregistry 18092

step "IMPORT mode on the read-only cluster"
[[ "$(sr_admin schemaregistry-ro /mode | jq -r .mode)" == IMPORT ]] ||
  sr_admin schemaregistry-ro '/mode?force=true' -X PUT -d '{"mode":"IMPORT"}'
echo

step "Schema exporter $EXPORTER on the core registry"
if ! sr_admin schemaregistry "/exporters/$EXPORTER" >/dev/null 2>&1; then
  JKS_PASSWORD="$(kcore -n confluent exec schemaregistry-0 -c schemaregistry -- cat /mnt/sslcerts/jksPassword.txt | cut -d= -f2-)"
  jq -n --arg name "$EXPORTER" --arg url "https://schemaregistry-ro.confluent.svc.cluster.local:8081" \
    --arg user "sr-exporter:$SR_EXPORTER_PASSWORD" --arg jks "$JKS_PASSWORD" '{
      name: $name, contextType: "NONE", subjects: ["*"],
      config: {
        "schema.registry.url": $url,
        "basic.auth.credentials.source": "USER_INFO",
        "basic.auth.user.info": $user,
        "schema.registry.ssl.truststore.location": "/mnt/sslcerts/truststore.p12",
        "schema.registry.ssl.truststore.type": "PKCS12",
        "schema.registry.ssl.truststore.password": $jks
      }}' | sr_admin schemaregistry /exporters -X POST -d @-
  echo
elif [[ "$(sr_admin schemaregistry "/exporters/$EXPORTER/status" | jq -r .state)" == PAUSED ]]; then
  sr_admin schemaregistry "/exporters/$EXPORTER/resume" -X PUT; echo
fi
for _ in $(seq 30); do
  state="$(sr_admin schemaregistry "/exporters/$EXPORTER/status" | jq -r .state)"
  [[ "$state" == RUNNING ]] && break
  sleep 5
done
sr_admin schemaregistry "/exporters/$EXPORTER/status"; echo
echo "Linked subjects on the read-only cluster: $(sr_admin schemaregistry-ro /subjects)"
