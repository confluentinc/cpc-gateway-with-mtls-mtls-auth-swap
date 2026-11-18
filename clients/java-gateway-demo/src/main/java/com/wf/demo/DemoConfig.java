package com.wf.demo;

import java.io.IOException;
import java.io.InputStream;
import java.io.Reader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.TreeSet;

import org.apache.avro.Schema;
import org.apache.kafka.common.Node;
import org.apache.kafka.common.PartitionInfo;

/** Command-line options and client properties shared by {@link Producer} and {@link Consumer}. */
final class DemoConfig {

  static final Set<String> AVRO_TOPICS = Set.of("demo-payments", "demo-csfle-test");
  static final String DEFAULT_CONFIG = ".secrets/clients/alice-gateway.properties";

  private final Map<String, String> options = new HashMap<>();

  private DemoConfig(String[] args) {
    for (int i = 0; i < args.length; i++) {
      String arg = args[i];
      if (!arg.startsWith("--") || i + 1 >= args.length) {
        throw new IllegalArgumentException("Expected --name value pairs, got: " + arg);
      }
      options.put(arg.substring(2), args[++i]);
    }
  }

  static DemoConfig parse(String[] args) {
    return new DemoConfig(args);
  }

  String get(String name, String defaultValue) {
    return options.getOrDefault(name, defaultValue);
  }

  int getInt(String name, int defaultValue) {
    return Integer.parseInt(get(name, String.valueOf(defaultValue)));
  }

  String topic() {
    return get("topic", "demo-orders");
  }

  boolean isAvro() {
    return Boolean.parseBoolean(get("avro", String.valueOf(AVRO_TOPICS.contains(topic()))));
  }

  /** The client file from clients/export-client-config.sh: Gateway mTLS plus Schema Registry basic auth. */
  Properties clientProperties() throws IOException {
    Path path = Path.of(get("config", DEFAULT_CONFIG));
    Properties props = new Properties();
    try (Reader reader = Files.newBufferedReader(path)) {
      props.load(reader);
    }
    return props;
  }

  /** Options whose name contains a dot are client properties (e.g. rule.executors._default_.disabled). */
  Map<String, String> clientOverrides() {
    Map<String, String> overrides = new HashMap<>();
    options.forEach((name, value) -> {
      if (name.contains(".")) {
        overrides.put(name, value);
      }
    });
    return overrides;
  }

  /** Prints what the client learned from its bootstrap connection: the advertised brokers and partition leaders. */
  static void printMetadata(String bootstrap, String topic, List<PartitionInfo> partitions) {
    Set<String> brokers = new TreeSet<>();
    partitions.forEach(p -> Arrays.stream(p.replicas()).forEach(n -> brokers.add(describe(n))));
    System.out.println("Bootstrap: " + bootstrap);
    System.out.println("Brokers advertised in metadata:");
    brokers.forEach(b -> System.out.println("  " + b));
    System.out.println("Partition leaders for " + topic + ":");
    partitions.stream().sorted(Comparator.comparingInt(PartitionInfo::partition))
        .forEach(p -> System.out.printf("  %s-%d -> %s%n", topic, p.partition(), describe(p.leader())));
  }

  /** Current leader of a partition, from the client's cached metadata. */
  static String leader(List<PartitionInfo> partitions, int partition) {
    return partitions.stream().filter(p -> p.partition() == partition).findFirst()
        .map(p -> p.leader() == null ? "no leader" : p.leader().host() + ":" + p.leader().port())
        .orElse("unknown");
  }

  private static String describe(Node node) {
    if (node == null) {
      return "no leader";
    }
    return node.host() + ":" + node.port() + " (id " + node.id() + (node.hasRack() ? ", rack " + node.rack() : "") + ")";
  }

  static Schema paymentSchema() throws IOException {
    try (InputStream in = DemoConfig.class.getResourceAsStream("/payment.avsc")) {
      return new Schema.Parser().parse(in);
    }
  }
}
