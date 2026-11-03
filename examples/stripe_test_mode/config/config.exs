import Config
config :ash, default_string_length_count: :codepoints

config :ash_billing_consumer,
  ash_domains: [AshBillingConsumer.Domain],
  ecto_repos: [AshBillingConsumer.Repo]

config :ash_billing_consumer, AshBillingConsumer.Repo,
  database: "ash_billing_stripe_integration",
  username: System.get_env("USER"),
  hostname: "localhost",
  pool_size: 10

config :logger, level: :warning
