# Idempotent demo seed for SaasExample (restricted to :dev / explicit demo environments)
# Run with: mix run priv/repo/seeds.exs

SaasExample.DemoSeeds.run!()

IO.puts("""
Seeded SaasExample demo accounts (local dev/demo only; password: password1234):
  - free@example.com       (No subscription)
  - starter@example.com    (Starter plan, 2 seats contracted, 1 used)
  - pro@example.com        (Pro plan, 5 seats contracted, 2 used)
  - enterprise@example.com (Enterprise plan, 20 seats contracted, 2 used, admin)
""")
