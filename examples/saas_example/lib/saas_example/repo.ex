defmodule SaasExample.Repo do
  use AshPostgres.Repo,
    otp_app: :saas_example,
    warn_on_missing_ash_functions?: false

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  def installed_extensions do
    ["uuid-ossp", "citext"]
  end
end
