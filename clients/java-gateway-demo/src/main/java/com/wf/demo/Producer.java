package com.wf.demo;

import java.time.Instant;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ThreadLocalRandom;

import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.clients.producer.RecordMetadata;
import org.apache.kafka.common.serialization.StringSerializer;

import io.confluent.kafka.serializers.KafkaAvroSerializer;

/**
 * Produces to a demo topic through the CPC Gateway.
 *
 * <pre>
 * java -cp target/gateway-demo.jar com.wf.demo.Producer --topic demo-orders [--count 10] [--interval-ms 1000]
 * java -cp target/gateway-demo.jar com.wf.demo.Producer --topic demo-payments   (Avro, governed by the Gateway)
 * java -cp target/gateway-demo.jar com.wf.demo.Producer --topic demo-payments --invalid amount|currency|card
 * </pre>
 *
 * {@code --count 0} produces until Ctrl-C. {@code --config} overrides the client properties file. {@code --invalid}
 * breaks one field so a data-quality rule of the schema rejects the record. Other {@code --<client property> value}
 * pairs that contain a dot are passed to the client, e.g. {@code --rule.executors._default_.disabled true}.
 */
public final class Producer {

  private static final List<String> CURRENCIES = List.of("USD", "EUR", "GBP");
  private static final List<String> MERCHANTS = List.of("Acme Grocers", "Blue Bottle Coffee", "City Rail",
      "Northwind Electronics", "Riverside Pharmacy", "Summit Outdoor");
  private static final List<String> CUSTOMERS = List.of("Maria Garcia", "James Smith", "Priya Patel",
      "Chen Wei", "Olivia Johnson", "Ahmed Khan");

  public static void main(String[] args) throws Exception {
    DemoConfig config = DemoConfig.parse(args);
    String topic = config.topic();
    int count = config.getInt("count", 10);
    int intervalMs = config.getInt("interval-ms", 1000);
    String invalid = config.get("invalid", "");

    Properties props = config.clientProperties();
    props.put(ProducerConfig.CLIENT_ID_CONFIG, "java-gateway-demo-producer");
    props.put(ProducerConfig.ACKS_CONFIG, "all");
    props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
    props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
    if (config.isAvro()) {
      props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, KafkaAvroSerializer.class.getName());
      // The subject is registered with its rule set (REST); the producer serializes with the latest version.
      props.put("auto.register.schemas", "false");
      props.put("use.latest.version", "true");
    } else {
      props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
    }
    props.putAll(config.clientOverrides());

    Schema paymentSchema = config.isAvro() ? DemoConfig.paymentSchema() : null;
    System.out.printf("Producing to %s via %s (%s)%n", topic, props.getProperty("bootstrap.servers"),
        config.isAvro() ? "Avro, schema registry " + props.getProperty("schema.registry.url") : "string");

    try (KafkaProducer<String, Object> producer = new KafkaProducer<>(props)) {
      DemoConfig.printMetadata(props.getProperty("bootstrap.servers"), topic, producer.partitionsFor(topic));
      for (int i = 1; count == 0 || i <= count; i++) {
        String key = (config.isAvro() ? "pay-" : "order-") + UUID.randomUUID().toString().substring(0, 8);
        Object value = config.isAvro() ? payment(paymentSchema, key, invalid) : "order " + i + " at " + Instant.now();
        try {
          RecordMetadata md = producer.send(new ProducerRecord<>(topic, key, value)).get();
          System.out.printf("sent  key=%s value=%s -> partition %d offset %d leader %s%n", key, value, md.partition(),
              md.offset(), DemoConfig.leader(producer.partitionsFor(topic), md.partition()));
        } catch (ExecutionException e) {
          System.out.printf("REJECTED key=%s value=%s%n  %s%n", key, value, e.getCause());
        }
        if (intervalMs > 0) {
          Thread.sleep(intervalMs);
        }
      }
    }
  }

  private static GenericRecord payment(Schema schema, String id, String invalid) {
    ThreadLocalRandom random = ThreadLocalRandom.current();
    GenericRecord payment = new GenericData.Record(schema);
    payment.put("id", id);
    payment.put("amount", "amount".equals(invalid) ? -25.0 : Math.round(random.nextDouble(1, 1000) * 100) / 100.0);
    payment.put("currency", "currency".equals(invalid) ? "JPY" : CURRENCIES.get(random.nextInt(CURRENCIES.size())));
    payment.put("merchant", MERCHANTS.get(random.nextInt(MERCHANTS.size())));
    payment.put("customer_name", CUSTOMERS.get(random.nextInt(CUSTOMERS.size())));
    payment.put("card_number", "card".equals(invalid) ? "4111-1111" : "4" + (100_000_000_000_000L
        + random.nextLong(900_000_000_000_000L)));
    return payment;
  }
}
