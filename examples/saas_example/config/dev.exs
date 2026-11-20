import Config

config :saas_example, SaasExample.Repo,
  username: System.get_env("POSTGRES_USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD") || "postgrespassword",
  hostname: System.get_env("POSTGRES_HOST") || "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
  database: System.get_env("POSTGRES_DB") || "saas_example_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :saas_example, SaasExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  secret_key_base:
    "dev_only_secret_key_base_never_valid_in_prod_0123456789abcdefghijklmnopqrstuvwxyz",
  check_origin: false,
  code_reloader: false,
  debug_errors: true

config :ash_billing,
  stripe_api_key:
    System.get_env("STRIPE_SECRET_KEY") ||
      System.get_env("STRIPE_API_KEY") ||
      "sk_test_local_dev_placeholder",
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "whsec_local_dev_placeholder",
  expected_livemode: false
