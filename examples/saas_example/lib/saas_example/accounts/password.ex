defmodule SaasExample.Accounts.Password do
  @moduledoc """
  PBKDF2-SHA256 password hashing using Erlang/OTP `:crypto` with constant-time
  verification via `Plug.Crypto.secure_compare/2`.
  """

  @salt_bytes 16
  @key_length 32
  @default_iterations 100_000

  @spec hash(String.t()) :: String.t()
  def hash(password) when is_binary(password) do
    iterations = Application.get_env(:saas_example, :pbkdf2_iterations, @default_iterations)
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    derived = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @key_length)
    "pbkdf2_sha256$#{iterations}$#{Base.encode64(salt)}$#{Base.encode64(derived)}"
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    case String.split(stored, "$") do
      ["pbkdf2_sha256", iter_str, salt_b64, hash_b64] ->
        with {iterations, ""} when iterations > 0 <- Integer.parse(iter_str),
             {:ok, salt} <- Base.decode64(salt_b64),
             {:ok, expected} <- Base.decode64(hash_b64) do
          candidate =
            :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, byte_size(expected))

          Plug.Crypto.secure_compare(candidate, expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def verify(_, _), do: false
end
