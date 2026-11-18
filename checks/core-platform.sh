#!/usr/bin/env bash
# CFK operator running, certificates issued with the expected subjects, LDAP serving users/groups over LDAPS.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
kubectl() { command kubectl --context "$CORE_CTX" "$@"; }

load_passwords
NS=confluent

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }

echo "== CFK operator"
kubectl -n "$NS" rollout status deploy/confluent-operator --timeout=120s >/dev/null \
  && pass "confluent-operator ready" || fail "confluent-operator not ready"
for crd in kafkas kraftcontrollers schemaregistries controlcenters gateways; do
  kubectl get crd "$crd.platform.confluent.io" >/dev/null 2>&1 && pass "CRD $crd" || fail "CRD $crd missing"
done

echo "== Certificates"
kubectl wait clusterissuer/wf-demo-ca --for=condition=Ready --timeout=10s >/dev/null && pass "ClusterIssuer wf-demo-ca ready"
check_cert() {  # secret expected_subject_substring
  local subj
  subj=$(kubectl -n "$NS" get secret "$1" -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -nameopt RFC2253)
  [[ "$subj" == *"$2"* ]] && pass "$1: $subj" || fail "$1 subject '$subj' (expected $2)"
  kubectl -n "$NS" get secret "$1" -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
  kubectl -n "$NS" get secret "$1" -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl verify -CAfile /tmp/ca.crt >/dev/null 2>&1 || fail "$1 does not verify against its ca.crt"
}
check_cert tls-kafka               "CN=kafka"
check_cert tls-kraftcontroller     "CN=kraftcontroller"
check_cert tls-schemaregistry      "CN=sr"
check_cert tls-controlcenter       "CN=c3"
check_cert ldap-sslcerts           "CN=ldap"
check_cert cpcgw-dmz-server-tls    "CN=${GATEWAY_DOMAIN},OU=cpc-gateway-server"
check_cert cpcgw-dmz-client-tls    "CN=cpcgw-dmz-client,OU=cpc-gateway-client"
check_cert client-alice-tls        "CN=alice"
check_cert client-bob-tls          "CN=bob"

echo "== OpenLDAP (LDAPS, bound as the MDS read-only user)"
kubectl -n "$NS" rollout status statefulset/ldap --timeout=120s >/dev/null && pass "ldap ready"
ldap() {
  kubectl -n "$NS" exec ldap-0 -- env LDAPTLS_CACERT=/container/service/slapd/assets/certs/ca.crt \
    ldapsearch -LLL -H ldaps://ldap.confluent.svc.cluster.local:636 \
    -D "cn=mds,dc=wf,dc=demo" -w "$LDAP_READONLY_USER_PASSWORD" -b "dc=wf,dc=demo" "$@"
}
users=$(ldap "(objectClass=inetOrgPerson)" cn | awk '/^cn:/{print $2}' | sort | tr '\n' ' ')
for u in alice bob c3 cpcgw-dmz-sr-client kafka sr testadmin; do
  [[ " $users" == *" $u "* ]] || fail "user $u missing (found: $users)"
done
pass "users: $users"
groups=$(ldap "(objectClass=groupOfNames)" cn | awk '/^cn:/{print $2}' | sort | tr '\n' ' ')
for g in app-developers gateway-services platform-admins; do
  [[ " $groups" == *" $g "* ]] || fail "group $g missing (found: $groups)"
done
pass "groups: $groups"

kubectl -n "$NS" exec ldap-0 -- env LDAPTLS_CACERT=/container/service/slapd/assets/certs/ca.crt \
  ldapwhoami -H ldaps://ldap.confluent.svc.cluster.local:636 \
  -D "cn=alice,ou=users,dc=wf,dc=demo" -w "$ALICE_PASSWORD" >/dev/null \
  && pass "alice can bind with her password" || fail "alice bind failed"
if kubectl -n "$NS" exec ldap-0 -- env LDAPTLS_CACERT=/container/service/slapd/assets/certs/ca.crt \
  ldapwhoami -H ldaps://ldap.confluent.svc.cluster.local:636 \
  -D "cn=alice,ou=users,dc=wf,dc=demo" -w wrong-password >/dev/null 2>&1; then
  fail "alice bind with a wrong password succeeded"
else
  pass "wrong password is rejected"
fi
