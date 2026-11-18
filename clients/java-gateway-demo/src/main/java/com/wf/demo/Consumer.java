package com.wf.demo;

import java.time.Duration;
import java.util.List;
import java.util.Properties;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.errors.WakeupException;
import org.apache.kafka.common.serialization.StringDeserializer;

import io.confluent.kafka.serializers.KafkaAvroDeserializer;

/**
 * Consumes a demo topic through the CPC Gateway until Ctrl-C, or until no record arrived for
 * {@code --idle-timeout-sec} seconds.
 *
 * <pre>
 * java -cp target/gateway-demo.jar com.wf.demo.Consumer --topic demo-orders [--group demo-java-consumer] [--from beginning]
 * java -cp target/gateway-demo.jar com.wf.demo.Consumer --topic demo-payments   (Avro)
 * </pre>
 *
 * The group must start with {@code demo-}: the brokers authorize Gateway traffic as User:cpcgw-dmz-client, whose
 * group binding is limited to that prefix.
 */
public final class Consumer {

  public static void main(String[] args) throws Exception {
    DemoConfig config = DemoConfig.parse(args);
    String topic = config.topic();
    String group = config.get("group", "demo-java-consumer");
    int idleTimeoutSec = config.getInt("idle-timeout-sec", 0);

    Properties props = config.clientProperties();
    props.put(ConsumerConfig.CLIENT_ID_CONFIG, "java-gateway-demo-consumer");
    props.put(ConsumerConfig.GROUP_ID_CONFIG, group);
    props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "beginning".equals(config.get("from", "latest")) ? "earliest" : "latest");
    props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
    props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
        config.isAvro() ? KafkaAvroDeserializer.class.getName() : StringDeserializer.class.getName());
    props.putAll(config.clientOverrides());

    KafkaConsumer<String, Object> consumer = new KafkaConsumer<>(props);
    Thread main = Thread.currentThread();
    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
      consumer.wakeup();
      try {
        main.join();
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }));

    System.out.printf("Consuming %s via %s as group %s (%s); Ctrl-C to stop%n", topic,
        props.getProperty("bootstrap.servers"), group, config.isAvro() ? "Avro" : "string");
    try (consumer) {
      DemoConfig.printMetadata(props.getProperty("bootstrap.servers"), topic, consumer.partitionsFor(topic));
      consumer.subscribe(List.of(topic));
      long lastRecord = System.currentTimeMillis();
      while (idleTimeoutSec == 0 || System.currentTimeMillis() - lastRecord < idleTimeoutSec * 1000L) {
        for (ConsumerRecord<String, Object> r : consumer.poll(Duration.ofSeconds(1))) {
          lastRecord = System.currentTimeMillis();
          System.out.printf("recv  key=%s value=%s <- partition %d offset %d leader %s%n", r.key(), r.value(),
              r.partition(), r.offset(), DemoConfig.leader(consumer.partitionsFor(topic), r.partition()));
        }
      }
      System.out.println("No records for " + idleTimeoutSec + "s, stopped.");
    } catch (WakeupException e) {
      System.out.println("Stopped.");
    }
  }
}
