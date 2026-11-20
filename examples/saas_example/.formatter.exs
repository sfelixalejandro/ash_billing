[
  import_deps: [:ash, :ash_postgres, :ecto, :ecto_sql, :phoenix],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/*/seeds.exs",
    "priv/repo/migrations/*.exs"
  ]
]
