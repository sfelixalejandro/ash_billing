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

  @spec register_user(map()) :: {:ok, User.t()} | {:error, term()}
  def register_user(attrs) when is_map(attrs) do
    email = attrs |> get_param(:email) |> normalize_string()
    name = attrs |> get_param(:name) |> normalize_string()
    password = get_param(attrs, :password)
    role = Map.get(attrs, :role, :member)

    cond do
      email == "" or not String.contains?(email, "@") ->
        {:error, :invalid_email}

      name == "" ->
        {:error, :invalid_name}

      not is_binary(password) or byte_size(password) < 8 ->
        {:error, :password_too_short}

      true ->
        User
        |> Ash.Changeset.for_create(:create, %{
          email: email,
          name: name,
          hashed_password: Password.hash(password),
          role: role
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
