# Demo walkthrough

Run from the repository root after `./setup.sh`. `CORE` and `DMZ` below are the cluster names from `config.env`.
Passwords are in `.secrets/passwords.env`.

```bash
eval "$(./lib/env.sh)"    # sets CORE_CTX, DMZ_CTX, GATEWAY_DOMAIN, SR_PUBLIC_HOST, ... in this shell (bash or zsh)
```

## 1. External producer and consumer through the Gateway

The Java client uses alice's certificate for Kafka (`kafka.gateway.<PUBLIC_ZONE>:9092`, mTLS) and her LDAP login for
the public Schema Registry. Each run prints the bootstrap server, the brokers advertised in metadata (Gateway names
only) and the partition leader of every record.

```bash
./clients/run.sh consumer --topic demo-payments                       # terminal 1, Ctrl-C to stop
./clients/run.sh producer --topic demo-payments --count 5             # terminal 2
./clients/run.sh consumer --topic demo-payments --group demo-replay-1 --from beginning   # re-read (group must start with demo-)
./clients/run.sh producer --topic demo-orders                         # plain-text topic, no schema
```

## 2. Data contracts at the Gateway

`demo-payments-value` carries CEL rules and an ENCRYPT rule on PII fields, run by the Gateway (`enableAt: GATEWAY`),
so clients need no rule code and no KMS access.

```bash
./clients/run.sh producer --topic demo-payments --count 1 --invalid amount     # REJECTED: amount must be > 0
./clients/run.sh producer --topic demo-payments --count 1 --invalid currency   # REJECTED: USD, EUR or GBP only
./clients/run.sh producer --topic demo-payments --count 1 --invalid card       # REJECTED: card number must be 16 digits
./clients/run.sh producer --topic demo-payments --count 1 --avro false         # REJECTED: not Avro
```

Encryption: the external consumer sees `card_number` and `customer_name` in clear; on the brokers they are
ciphertext. Read the topic directly from the brokers with the internal client pod (alice, no KMS access):

```bash
kubectl --context $CORE_CTX -n clients exec -it internal-client -- \
  consumer --topic demo-payments --from beginning --group demo-raw-1 --rule.executors._default_.disabled true
```

## 3. Authentication and authorization failures

```bash
./check.sh gateway     # includes a client without a certificate and a self-signed CN=mallory: both refused at TLS
./clients/run.sh --user bob producer --topic demo-payments --count 1   # bob: valid certificate, no SR role bindings -> 403
kubectl --context $CORE_CTX -n clients exec -it internal-client -- env CLIENT_USER=bob producer --topic demo-orders --count 1
                       # bob directly on the brokers: TopicAuthorizationException
```

## 4. Route fencing

The Gateway route blocks produce requests to `demo-fenced`; other topics are unaffected. A fenced producer gets no
error from the Gateway and times out (`delivery.timeout.ms`, 2 minutes by default):

```bash
./clients/run.sh producer --topic demo-fenced --count 1 --delivery.timeout.ms 15000 --request.timeout.ms 10000
```

Grafana's Gateway Overview dashboard shows the attempts under **Route fencing**.

## 5. Schema linking

The core registry exports every subject (same names and IDs, with rule sets) to the read-only cluster; the DMZ
followers serve it at `https://sr.<PUBLIC_ZONE>`. Writes are refused there; the core registry stays private.

```bash
source .secrets/passwords.env
curl -s -u alice:$ALICE_PASSWORD https://$SR_PUBLIC_HOST/subjects/demo-payments-value/versions/latest | jq '{id, version, rules: [.ruleSet.domainRules[].name]}'
curl -s -o /dev/null -w '%{http_code}\n' -u bob:$BOB_PASSWORD https://$SR_PUBLIC_HOST/subjects               # 403
curl -s -o /dev/null -w '%{http_code}\n' -u testadmin:$TESTADMIN_PASSWORD https://$SR_PUBLIC_HOST/dek-registry/v1/keks   # 404
./check.sh schema-linking
```

To show a change propagating, register a new version on the core (for example edit
`cfk/core/05-data-contracts/schemas/payment-rules.json` and run `./setup.sh data-contracts`), then read it from the
public endpoint a few seconds later.

## 6. Consoles

```bash
kubectl --context $CORE_CTX -n confluent port-forward svc/controlcenter-0-internal 9021:9021   # https://localhost:9021, testadmin
kubectl --context $DMZ_CTX -n monitoring port-forward svc/grafana 3000:3000                    # http://localhost:3000, admin / .secrets/grafana-admin.password
```

Grafana has the Gateway dashboards (traffic, latency, schema rejections, fencing, JVM) and a Loki data source with
the broker and Gateway logs.

Useful one-liners:

```bash
kubectl --context $CORE_CTX -n confluent get confluentrolebinding \
  -o custom-columns='NAME:.metadata.name,PRINCIPAL:.spec.principal.name,ROLE:.spec.role,RESOURCE:.spec.resourcePatterns[*].name,SR_CLUSTER:.spec.clustersScopeByIds.schemaRegistryClusterId,STATE:.status.state'
JAVA_TOOL_OPTIONS=-Dorg.slf4j.simpleLogger.log.org.apache.kafka.clients.Metadata=debug \
  ./clients/run.sh consumer --topic demo-payments      # every metadata refresh, with the advertised brokers
```
