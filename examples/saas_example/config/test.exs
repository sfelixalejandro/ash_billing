import Config

config :saas_example, SaasExample.Repo,
  username: System.get_env("POSTGRES_USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD") || "postgrespassword",
  hostname: System.get_env("POSTGRES_HOST") || "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
  database: System.get_env("POSTGRES_TEST_DB") || "saas_example_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :saas_example, SaasExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_only_secret_key_base_0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdef",
  server: false

config :ash_billing,
  stripe_api_key: "sk_test_saas_example_test_key",
  webhook_secret: "whsec_saas_example_test_secret",
  expected_livemode: false,
  req_opts: [
    connect_options: [timeout: 3_000],
    receive_timeout: 5_000,
    retry: false
  ]

# Fast PBKDF2 iterations in test only (production/dev uses 100_000)
config :saas_example, :pbkdf2_iterations, 1_000

config :logger, level: :warning
