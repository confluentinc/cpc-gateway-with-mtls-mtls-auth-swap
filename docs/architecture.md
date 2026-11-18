# Architecture reference

Names below use the `config.env` settings: `<PUBLIC_ZONE>`, `<PRIVATE_ZONE>`, `<CORE>` and `<DMZ>` (cluster names).

## Endpoints

| Endpoint | Where | Who uses it | Authentication |
| --- | --- | --- | --- |
| `kafka.gateway.<PUBLIC_ZONE>:9092`, `b0..b2.kafka.gateway.<PUBLIC_ZONE>` | Internet-facing NLB in the DMZ (allowlist, port 9092 only) | External clients | mTLS, client certificate from the demo CA |
| `https://sr.<PUBLIC_ZONE>` | Internet-facing ALB in the DMZ (ACM certificate) → read-only SR followers | External serializers | LDAP basic auth (checked by MDS), read roles only |
| `kafka.<PRIVATE_ZONE>:9092`, `b0..b2.<PRIVATE_ZONE>` | Internal NLBs in the core | Gateway, read-only SR followers, core apps | mTLS |
| `https://sr.<PRIVATE_ZONE>` | Internal NLB in the core → core SR | Gateway (governance, DEKs), core apps | LDAP basic auth |
| `https://mds.<PRIVATE_ZONE>:8090` | Internal NLB in the core, DMZ private subnets only | Read-only SR followers | mTLS |
| `loki.<PRIVATE_ZONE>:3100` | Internal NLB in the core, DMZ VPC only | DMZ Alloy and Grafana | none (network only) |
| Control Center, Grafana, Prometheus | ClusterIP services | Operators, through `kubectl port-forward` | C3: LDAP; Grafana: admin password |

## Network

- Two VPCs (`CORE_VPC_CIDR`, `DMZ_VPC_CIDR`), three AZs each, peered. Routes exist only between the private subnets.
- DMZ private subnets → core: network ACL allows only 9092 (Kafka), 443 (core SR), 8090 (MDS) and 3100 (Loki), plus
  return traffic. The DMZ public subnets (load balancers, NAT) have no route to the core and their ACL denies it.
- The core can't open connections into the DMZ: DMZ security groups admit nothing from the core CIDR.
- Public ALB → DMZ SR pods on 8081 only; Gateway NLB security group admits 9092 from `PUBLIC_ALLOWED_CIDRS`
  (CFK also publishes 9180/9190 on that service; the security group blocks them).

## Identities and role bindings

Certificate CNs are the Kafka principals (mapping rule `CN=(...)`). LDAP users are the SR and Control Center logins.

| Principal | Kind | Used by | Main permissions |
| --- | --- | --- | --- |
| `kafka`, `kraftcontroller` | certificate | brokers, controllers | super users |
| `sr` | certificate | core SR | CFK-created SR bindings; DEK registry and exporter topics |
| `sr-ro` | certificate | read-only SR leader (core) | CFK-created bindings for `id_schemaregistry-ro_confluent` |
| `sr-dmz` | certificate | read-only SR followers (DMZ) | same cluster's store topic and group, license topics (`06-schema-linking/rbac.yaml`) |
| `c3` | certificate + LDAP | Control Center | SystemAdmin (CFK-created) |
| `cpcgw-dmz-client` | certificate | Gateway → brokers | `demo-*` topics and groups (`dmz/01-gateway/core-rbac.yaml`) |
| `cpcgw-dmz-sr-client` | LDAP | Gateway → core SR | read `demo-*` subjects, the payments KEK |
| `sr-exporter` | LDAP | schema link → read-only cluster | ResourceOwner on all subjects and KEKs of the read-only cluster |
| `alice` | certificate + LDAP | demo app user | `demo-*` topics, groups and subjects (read only on the read-only cluster) |
| `bob` | certificate + LDAP | negative tests | none |
| `testadmin` | LDAP | administrator | ClusterAdmin on Kafka, SystemAdmin on both SR clusters |

Traffic through the Gateway reaches the brokers as `cpcgw-dmz-client`, whichever client certificate was presented.

## Secrets

No Secret manifests are kept in the repo. The step scripts generate credentials into `.secrets/` (git-ignored) on
first run and create the Kubernetes Secrets from those files with `kubectl create secret ... --dry-run=client -o yaml |
kubectl apply -f -`. TLS certificates are cert-manager `Certificate` resources and never touch disk.

### Local files (`.secrets/`)

| File | Written by | Used for |
| --- | --- | --- |
| `confluent-license.txt` | you (`CONFLUENT_LICENSE_FILE`) | `confluent-license` Secret in both clusters |
| `passwords.env` | `core-platform` | one `<USER>_PASSWORD` line per LDAP user: `LDAP_ADMIN`, `LDAP_CONFIG`, `LDAP_READONLY_USER`, `KAFKA`, `SR`, `C3`, `CPCGW_SR`, `SR_EXPORTER`, `TESTADMIN`, `ALICE`, `BOB` |
| `mds-token-keypair.pem`, `mds-token-public.pem` | `core-kafka` | `mds-token` (core), `mds-token-public` (DMZ, public key only) |
| `sr-password-encoder.txt` | `core-sr` | `sr-password-encoder` |
| `ca.crt` | `data-contracts` and later steps | demo CA, used locally to call the SR admin API through a port-forward |
| `grafana-admin.password` | `dmz-monitoring` | `grafana-admin` |
| `clients/` | `clients` | `truststore.jks`, `<user>.keystore.jks`, `store.password` and `<user>-gateway.properties` for alice and bob; also the `internal-client` Secret |

A missing file is generated; an existing one is reused, so re-running a step never rotates credentials. To bring your
own, write the file (or the `passwords.env` line) before the step first runs. Delete `.secrets/` (except the license)
for a fresh set on the next full setup.

### Kubernetes Secrets

| Secret | Namespace | Created by | Content |
| --- | --- | --- | --- |
| `tls-*`, `cpcgw-dmz-*-tls`, `client-*-tls` | `confluent` (core) | cert-manager, `00-platform/certificates.yaml` and `06-schema-linking/certificates.yaml` | PEM certificate, key, CA |
| copies of `cpcgw-dmz-*-tls`, `tls-schemaregistry-dmz`, `cpcgw-dmz-ca` | `gateway` (DMZ) | `dmz/00-platform`, `dmz/02-schema-registry` | copied from the core; no CA key in the DMZ |
| `ldap-env`, `ldap-ldifs` | `confluent` | `00-platform/deploy.sh` | LDAP admin passwords, bootstrap users and groups |
| `mds-token` (key pair), `mds-token-public` (DMZ) | both | `01-kafka`, `dmz/02-schema-registry` | MDS token signing key / public key only |
| `mds-ldap-bind` | `confluent` | `01-kafka/deploy.sh` | MDS bind user for LDAP |
| `confluent-license` | both | `02-schema-registry`, `dmz/02-schema-registry` | license JWT from `CONFLUENT_LICENSE_FILE` |
| `sr-password-encoder` | `confluent` | `02-schema-registry/deploy.sh` | encrypts the exporter's stored credentials |
| `c3-sr-basic`, `cpcgw-dmz-sr-credentials` | both | step scripts | LDAP logins for C3 and the Gateway |
| `aws-kms-role-params` | `gateway` | `dmz/01-gateway/kms-irsa.yaml` | IAM role the encryption executors assume |
| `grafana-admin` | `monitoring` | `dmz/03-monitoring/deploy.sh` | Grafana admin password |
| `internal-client` | `clients` (core) | `clients/internal-client/deploy.sh` | trust store, key stores and configs for the in-cluster client |

## Schema linking

```
core SR (writable, private) --exporter dmz-readonly, all subjects, same IDs--> read-only SR cluster
                                                                    leader:    schemaregistry-ro (core, IMPORT mode)
                                                                    followers: schemaregistry-dmz x2 (DMZ, leader.eligibility=false)
                                                                               <- public ALB <- external clients
```

The followers join the read-only cluster through its Kafka topic `_schemas_schemaregistry-ro_confluent` and group
`id_schemaregistry-ro_confluent`. They have no DEK registry and no exporter API, so keys never reach the DMZ. Writes
sent to them are forwarded to the leader, where users only hold read roles and IMPORT mode admits only the exporter.
Users without write roles get 403. An administrator's write is also refused, but because the leader's rejection comes
back through the follower, it shows as HTTP 500 rather than 422. Sync is unaffected.

## Gateway configuration notes

- Route `sni-route-core`: SNI host routing (`b$(nodeId).kafka.gateway.<PUBLIC_ZONE>`), TLS termination with the
  Gateway server certificate, and a new mTLS session to the brokers as `cpcgw-dmz-client`.
- `configOverrides.server` sets `routes.sni-route-core.security.ssl.clientAuth: required`. Verified: without it a
  client with no certificate can produce through the Gateway; with it the client is refused in the TLS handshake
  (`PEER_DID_NOT_RETURN_A_CERTIFICATE` in the Gateway log). Passthrough is the default for a streaming domain with
  no `security.cluster` entry and needs no setting.
- CRD-native alternative (not yet tested here): the CFK 3.4 docs say mTLS clients require authentication swapping,
  because TLS ends at the Gateway. The documented form is `security.client.authentication` with `type: mtls`,
  `mtls.sslClientAuthentication: required` and `principalMappingRules`, plus `security.cluster.core` with
  `auth: swap` and `authentication.type: none` (no secret store; the Gateway still connects with its own
  certificate). What failed earlier was `type: mtls` with `auth: passthrough`, which the docs don't support: CFK
  rendered empty mapping rules and the Gateway didn't start.
- Data governance: schema validation on `demo-payments` (subject `demo-payments-value`), rule executors for
  ENCRYPT with the IAM role from Terraform. `demo-orders` and `demo-fenced` are excluded from validation.
- Fencing: `rules.fencing` blocks PRODUCE to `demo-fenced` on this route only.
