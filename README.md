# Confluent Platform on EKS with a CPC Gateway DMZ

Two EKS clusters in one AWS account, built by Terraform and Confluent for Kubernetes (CFK 3.4):

- **Core** (`CORE_CLUSTER`, private only): KRaft, 3 Kafka brokers (mTLS, RBAC, MDS on OpenLDAP), Schema Registry with
  data contracts (CEL rules, field encryption with AWS KMS), Control Center, Loki.
- **DMZ** (`DMZ_CLUSTER`, internet-facing): CPC Gateway on `kafka.gateway.<PUBLIC_ZONE>:9092` (mTLS, SNI routing,
  schema validation, encryption, route fencing), a read-only Schema Registry on `https://sr.<PUBLIC_ZONE>` fed by
  schema linking, Prometheus and Grafana.

External clients only ever reach the two public names. The brokers, MDS and the writable Schema Registry stay in the
core VPC; the VPC peering and network ACLs let the DMZ open only Kafka, SR, MDS and Loki connections to the core.
Diagram (drawn with the reference names `wf.dspdemos.com` / `internal.dspdemos.com`):
[docs/architecture.html](docs/architecture.html). Endpoints, network rules, identities and secrets:
[docs/architecture.md](docs/architecture.md).

## Prerequisites

- An AWS account where you can create VPCs, EKS, IAM roles, KMS keys, load balancers and Route 53 zones, and an
  **existing public Route 53 zone** (`PARENT_ZONE`). The build creates `PUBLIC_ZONE` under it and delegates it.
- A **Confluent Platform license** with the CSFLE add-on, saved as raw JWT text (default `.secrets/confluent-license.txt`).
- Tools: `aws` v2, `terraform` ≥ 1.6, `kubectl`, `helm` 3, `jq`, `envsubst` (gettext; `brew install gettext`),
  `openssl`, `curl`, `nc`, `dig`, Java 21+ (`java`, `keytool`) and Maven.

## Configure

```bash
cp config.env.example config.env    # then edit: AWS profile/region, cluster names, CIDRs, zones, allowlist
mkdir -p .secrets && cp /path/to/license.txt .secrets/confluent-license.txt
aws sso login --profile <AWS_PROFILE>   # or any credentials the AWS CLI picks up
```

`config.env` is the only file you edit. Terraform reads it through generated `config.auto.tfvars.json` files, and the
manifests reference it as `${PUBLIC_ZONE}`, `${PRIVATE_ZONE}`, ... (rendered by `lib/common.sh` at apply time, together
with Terraform outputs such as the KMS key and IAM role ARNs).

## Deploy

```bash
./setup.sh -y          # everything, about 60-75 minutes; -y skips the Terraform approval prompts
./setup.sh list        # the 15 steps
./setup.sh dmz-sr      # re-run one step (every step is idempotent)
./setup.sh --from dmz-platform
```

You supply only `config.env` and the license. Every other credential (LDAP passwords, the MDS token key pair, client
key stores) is generated into `.secrets/` (git-ignored) on first run, reused on re-runs, and turned into Kubernetes
Secrets by the step scripts; certificates come from cert-manager. The file-to-Secret map and how to bring your own are
in [docs/architecture.md](docs/architecture.md#secrets). Kubectl contexts are named after the clusters
(`kubectl --context <CORE_CLUSTER>`).

## Check

```bash
./check.sh                       # about 10 minutes; PASS/FAIL lines, stops at the first failure
./check.sh gateway schema-linking
FAILOVER=1 ./check.sh kafka      # also restarts a broker while producing
```

`checks/gateway.sh` runs from your machine over the internet like a partner would: it covers mTLS with good, missing
and untrusted certificates, metadata that shows only Gateway names, CEL rejections, encryption (ciphertext on the
brokers, plaintext through the Gateway) and fencing. `checks/schema-linking.sh` compares subjects and IDs between
the core and the read-only registry and confirms the public endpoint is read-only.

## Try it

```bash
./clients/run.sh consumer --topic demo-payments               # terminal 1
./clients/run.sh producer --topic demo-payments --count 5     # terminal 2
./clients/run.sh producer --topic demo-payments --count 1 --invalid amount   # rejected by a CEL rule
```

The full walkthrough (encryption, AuthN failures, fencing, schema linking, Control Center and Grafana) is in
[DEMO.md](DEMO.md). The Java client is in `clients/java-gateway-demo`; its config files
(`.secrets/clients/<user>-gateway.properties`) work with any Kafka client.

## Use your own pieces

| To replace | Change |
| --- | --- |
| Names, account, region, CIDRs, allowlist | `config.env` |
| Certificate authority | `cfk/core/00-platform/ca-issuer.yaml` (any cert-manager issuer; certificates in `certificates.yaml` keep their CNs, which are the RBAC principals) |
| LDAP directory | `cfk/core/00-platform/ldap*.yaml`, MDS LDAP settings in `cfk/core/01-kafka/kafka.yaml` |
| Users, topics, role bindings | `cfk/core/01-kafka/topics-rbac.yaml`, `cfk/core/02-schema-registry/{topics,rbac}.yaml`, `cfk/core/06-schema-linking/rbac.yaml` (read-only cluster), `cfk/dmz/01-gateway/core-rbac.yaml` |
| Schemas and rules | `cfk/core/05-data-contracts/` (re-run `./setup.sh data-contracts`) |
| Gateway routes, governance, fencing | `cfk/dmz/01-gateway/gateway.yaml` |
| Sizes and versions | `terraform/*/variables.tf` (nodes), image tags in the CRs, `CFK_CHART_VERSION` in `lib/common.sh` |

## Tear down

```bash
./teardown.sh          # asks once; -y for none
```

It deletes the workloads first, so Kubernetes removes their load balancers, DNS records and volumes, then runs
`terraform destroy` for the DMZ and the core. `.secrets/` stays. KMS keys enter the 7-day deletion window.

## Layout

| Path | What it defines |
| --- | --- |
| `config.env.example` | Every environment-specific setting |
| `setup.sh`, `teardown.sh`, `check.sh`, `lib/common.sh` | Orchestration and shared helpers (config, contexts, rendering, port-forwards) |
| `terraform/core` | Core VPC, EKS, EBS CSI and `gp3`, private zone, AWS Load Balancer Controller, ExternalDNS, cert-manager |
| `terraform/dmz` | DMZ VPC and EKS, peering and network ACLs, public zone and delegation, Gateway NLB security group, SR ALB, KMS key and Gateway IAM roles |
| `cfk/core/00-platform` | CFK operator, private CA, every certificate, OpenLDAP and its users |
| `cfk/core/01-kafka` | KRaftController and Kafka CRs (listeners, MDS, audit logs), demo topics and role bindings |
| `cfk/core/02-schema-registry` | Core SchemaRegistry CR (rule sets, DEK registry, exporter), license secret, role bindings |
| `cfk/core/03-control-center` | ControlCenter CR (next-gen, with Prometheus and Alertmanager) |
| `cfk/core/04-logging` | Loki and Alloy (broker logs), Loki NLB for the DMZ |
| `cfk/core/05-data-contracts` | KEK, Payment schema and its rule set |
| `cfk/core/06-schema-linking` | Read-only SR leader, MDS NLB, role bindings, exporter |
| `cfk/dmz/00-platform` | DMZ CFK operator, Gateway certificates and SR credentials |
| `cfk/dmz/01-gateway` | Gateway CR, IRSA service account, core role bindings for the Gateway |
| `cfk/dmz/02-schema-registry` | Read-only SR followers, ALB TargetGroupBinding |
| `cfk/dmz/03-monitoring`, `04-logging` | Prometheus, Grafana and dashboards; Alloy for the Gateway logs |
| `clients/` | Client config export, Java producer and consumer, internal client pod |
| `checks/` | Verification scripts used by `check.sh` |

## Before production

This is a reference build. For real use: replace the self-signed CA and OpenLDAP with yours; store passwords and keys
in a secret manager instead of `.secrets/`; use remote Terraform state; narrow `PUBLIC_ALLOWED_CIDRS`; add PodDisruptionBudgets
and sizing for your load; and decide whether the Gateway should map client certificates to their own principals
(today the brokers authorize all Gateway traffic as `User:cpcgw-dmz-client`).
