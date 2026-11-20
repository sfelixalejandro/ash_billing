defmodule SaasExample.Accounts do
  @moduledoc """
  Accounts Ash domain providing user registration, authentication, and fresh
  actor reloading (with current billing subscriptions) at request boundaries.
  """
  use Ash.Domain, otp_app: :saas_example

  require Ash.Query

  alias SaasExample.Accounts.{Password, User}

  resources do
    resource SaasExample.Accounts.User
  end

  @doc """
  Public user registration. Always assigns `role: :member` and ignores any
  caller-supplied `:role` / `"role"` field to prevent privilege escalation.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, term()}
  def register_user(attrs) when is_map(attrs) do
    create_account(attrs, :create)
  end

  @doc """
  Administrative user provisioning for trusted seeds or system tooling.
  Must NEVER be wired to public registration endpoints.
  """
  @spec create_admin_user(map()) :: {:ok, User.t()} | {:error, term()}
  def create_admin_user(attrs) when is_map(attrs) do
    create_account(attrs, :create_admin)
  end

  defp create_account(attrs, action) do
    email = attrs |> get_param(:email) |> normalize_string()
    name = attrs |> get_param(:name) |> normalize_string()
    password = get_param(attrs, :password)

    cond do
      email == "" or not String.contains?(email, "@") ->
        {:error, :invalid_email}

      name == "" ->
        {:error, :invalid_name}

      not is_binary(password) or byte_size(password) < 8 ->
        {:error, :password_too_short}

      true ->
        User
        |> Ash.Changeset.for_create(action, %{
          email: email,
          name: name,
          hashed_password: Password.hash(password)
        })
        |> Ash.create(domain: __MODULE__, authorize?: false)
    end
  end

  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    trimmed = String.trim(email)

    case User
         |> Ash.Query.filter(email == ^trimmed)
         |> Ash.read_one(domain: __MODULE__, authorize?: false) do
      {:ok, %User{} = user} ->
        if Password.verify(password, user.hashed_password) do
          load_fresh_actor(user.id)
        else
          {:error, :invalid_credentials}
        end

      _ ->
        # Mitigate simple timing discrepancy when account does not exist
        _ = Password.hash("dummy_password_for_timing_balance")
        {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_, _), do: {:error, :invalid_credentials}

  @doc """
  Reloads the actor and its `:subscriptions` fresh from PostgreSQL at the HTTP
  request boundary so revoked or canceled subscriptions are immediately reflected
  in `AshBilling.Checks.Subscribed` and `AshBilling.Checks.HasPrice`.
  """
  @spec load_fresh_actor(String.t()) :: {:ok, User.t()} | {:error, term()}
  def load_fresh_actor(user_id) when is_binary(user_id) do
    with {:ok, %User{} = user} <- Ash.get(User, user_id, domain: __MODULE__, authorize?: false),
         {:ok, loaded} <- Ash.load(user, :subscriptions, domain: __MODULE__, authorize?: false) do
      {:ok, loaded}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_fresh_actor(_), do: {:error, :not_found}

  defp get_param(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_string(val) when is_binary(val), do: String.trim(val)
  defp normalize_string(_), do: ""
end
