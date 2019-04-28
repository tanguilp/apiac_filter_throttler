defmodule APIacFilterThrottler.Functions do
  @moduledoc """
  Throttling functions that construct keys for the `APIacFilterThrottler` plug.

  Note that except `throttle_by_ip_subject_client_safe/1`, these functions do
  not protect against collisions. See the *Security considerations* of the
  `APIacFilterThrottler` module for further information.
  """

  @doc """
  Returns the IP address as a string

  Make sure that the `remote_ip` of the `Plug.Conn.t` is correctly set

  Example:
  ```elixir
  iex> throttle_by_ip(conn)
  "121.42.56.166"
  ```
  """
  @spec throttle_by_ip(Plug.Conn.t()) :: String.t()
  def throttle_by_ip(conn) do
    List.to_string(:inet.ntoa(conn.remote_ip))
  end

  @doc """
  Returns the IP address concatenated to the path as a string

  Make sure that the `remote_ip` of the `Plug.Conn.t` is correctly set

  Example:
  ```elixir
  iex> throttle_by_ip_path(conn)
  "121.42.56.166/api/prices/eurusd"
  ```
  """
  @spec throttle_by_ip_path(Plug.Conn.t()) :: String.t()
  def throttle_by_ip_path(conn) do
    List.to_string(:inet.ntoa(conn.remote_ip)) <> conn.request_path
  end

  @doc """
  Returns the authenticated client as a string

  Make sure that a client is authenticated by an `APIac.Authenticator` plug, otherwise
  this function will raise an exception since you certainly don't want clients to be
  throttled, but not unauthenticated accesses

  Example:
  ```elixir
  iex> throttle_by_client(conn)
  "client32187"
  ```
  """
  @spec throttle_by_client(Plug.Conn.t()) :: String.t()
  def throttle_by_client(conn) do
    case APIac.client(conn) do
      client when is_binary(client) ->
        client

      nil ->
        raise "#{__MODULE__}: unauthenticated client, cannot throttle"
    end
  end

  @doc """
  Returns the authenticated client concatenated to the path as a string

  Make sure that a client is authenticated by an `APIac.Authenticator` plug, otherwise
  this function will raise an exception since you certainly don't want clients to be
  throttled, but not unauthenticated accesses

  Example:
  ```elixir
  iex> throttle_by_client_path(conn)
  "client32187/api/prices/eurusd"
  ```
  """
  @spec throttle_by_client_path(Plug.Conn.t()) :: String.t()
  def throttle_by_client_path(conn) do
    case APIac.client(conn) do
      client when is_binary(client) ->
        client <> conn.request_path

      nil ->
        raise "#{__MODULE__}: unauthenticated client, cannot throttle"
    end
  end

  @doc """
  Returns the IP address concatenated to client as a string. May be usefull when
  dealing with OAuth2 public clients such as mobiles apps or SPAs, when many devices
  share the same `client_id` and to limit the *global* volume of calls so as to
  protect against, for instance, application faults triggering request storms

  Make sure that the `remote_ip` of the `Plug.Conn.t` is correctly set

  Example:
  ```elixir
  iex> throttle_by_ip_client(conn)
  "121.42.56.166client10341"
  ```
  """
  @spec throttle_by_ip_client(Plug.Conn.t()) :: String.t()
  def throttle_by_ip_client(conn) do
    List.to_string(:inet.ntoa(conn.remote_ip)) <> APIac.client(conn)
  end

  @doc """
  Returns the subject concatenated to the client. Maybe be usefull when
  dealing with OAuth2 public clients such as mobiles apps or SPAs, when many devices
  share the same `client_id`, to protect against a malicious user trying to globally
  block the API

  Example:
  ```elixir
  iex> throttle_by_subject_client(conn)
  "bob23mymobileapp"
  ```
  """
  @spec throttle_by_subject_client(Plug.Conn.t()) :: String.t()
  def throttle_by_subject_client(conn) do
    APIac.subject(conn) <> APIac.client(conn)
  end

  @doc """
  Returns the IP address concatenated to subject and the client. Maybe be usefull when
  dealing with OAuth2 public clients such as mobiles apps that can be used on several
  personal devices (e.g. Android laptop, smartphone and tablet) simultaneously (however
  devices could share the same IP address)

  Example:
  ```elixir
  iex> throttle_by_ip_subject_client(conn)
  "275.33.99.208bob23mymobileapp"
  ```
  """
  @spec throttle_by_ip_subject_client(Plug.Conn.t()) :: String.t()
  def throttle_by_ip_subject_client(conn) do
    List.to_string(:inet.ntoa(conn.remote_ip)) <> APIac.subject(conn) <> APIac.client(conn)
  end

  @doc """
  Same as throttle_by_subject_client/1 but avoids collisions by using `:erlang.phash2/1`

  Example:
  ```elixir
  iex> throttle_by_ip_subject_client_safe(conn)
  "37541545"
  ```
  """
  @spec throttle_by_subject_client_safe(Plug.Conn.t()) :: String.t()
  def throttle_by_subject_client_safe(conn) do
    {conn.remote_ip, APIac.subject(conn), APIac.client(conn)}
    |> :erlang.phash2()
    |> Integer.to_string()
  end
end
