defmodule APIacFilterThrottler do
  @behaviour Plug
  @behaviour APIac.Filter

  @moduledoc """
  An `APIac.Filter` plug for API requests rate-limiting

  This plug uses the [Exhammer](https://github.com/ExHammer/hammer) package as
  its backend. This library uses the token bucket algorithm, which means that
  this plug is mainly suitable for limiting abuses, not for accurate rate limiting. By
  default, a local ETS backend is launched on startup.

  ## Plug options

  - `key`: a
  `(Plug.Conn.t -> String.t | {String.t, non_neg_integer(), non_neg_integer()})`
  function, taking in parameter the connection and returning either the key, or the
  tuple `{key, scale, limit}`. No default value.
  Note that the `APIacFilterThrottler.Functions` provides with out-of-the-box functions
  - `scale`: the time window of the token bucket algorithm, in milliseconds. No default value.
  - `limit`: the maximum limit of the token bucket algorithm, in attempt count. No default value.
  - `increment`: the increment of the token bucket algorithm (defaults to `1`)
  - `backend`: Exhammer's backend, defaults to `nil`
  - `exec_cond`: a `(Plug.Conn.t() -> boolean())` function that determines whether
  this filter is to be executed or not. Defaults to `fn _ -> true end`
  - `send_error_response`: function called when request is throttled. Defaults to
  `#{__MODULE__}.send_error_response/3`
  - `error_response_verbosity`: one of `:debug`, `:normal` or `:minimal`.
  Defaults to `:normal`

  ## Example

  Allow 50 request / 10 seconds per subject and per client:

  ```elixir
  plug APIacFilterThrottler, key: &APIacFilterThrottler.Functions.throttle_by_subject_client/1,
    scale: 10_000,
    limit: 50
  ```

  Allow 5000 requests / minute per client, only for machine-to-machine access:

  ```elixir
  plug APIacFilterThrottler, key: &APIacFilterThrottler.Functions.throttle_by_client/1,
    exec_cond: &APIac.machine_to_machine?/1,
    scale: 60_000,
    limit: 5000
  ```

  ## Security considerations

  Consider the risk of collisions when constructing the key> For instance, a key function
  concatenating the ip address and a subject (username) would return the same key
  ("72.23.241.121edwards") for:
  - a user "edwards" connecting from 72.23.241.121
  - a user "1edwards" connecting from 72.23.241.12

  The more control an attacker has on choosing the key parameters (e.g. the username), the
  easier to find a collision.

  Finding a collision can result in a DOS for the legitimate requester.

  Using a hash function such as `:erlang.phash2/1`, MD5, etc. cam help mitigate the risk,
  at the expense of performance. Also note that `:erlang.phash2/1` is not a
  collision-resistant hash function (as results are not uniformly distributed).

  """

  @impl Plug
  def init(opts) do
    if opts[:key] == nil, do: raise("`key` is a mandatory parameter")
    if opts[:scale] == nil, do: raise("`scale` is a mandatory parameter")
    if opts[:limit] == nil, do: raise("`limit` is a mandatory parameter")

    opts
    |> Enum.into(%{})
    |> Map.put_new(:increment, 1)
    |> Map.put_new(:backend, nil)
    |> Map.put_new(:exec_cond, fn _ -> true end)
    |> Map.put_new(:send_error_response, &__MODULE__.send_error_response/3)
    |> Map.put_new(:error_response_verbosity, :normal)
  end

  @impl Plug
  def call(conn, opts) do
    if opts[:exec_cond].(conn) do
      case filter(conn, opts) do
        {:ok, conn} ->
          conn

        {:error, conn, reason} ->
          opts[:send_error_response].(conn, reason, opts)
      end
    else
      conn
    end
  end

  @impl APIac.Filter
  def filter(conn, opts) do
    {key, scale, limit} =
      case get_filter_fun(opts[:key]).(conn) do
        key when is_binary(key) ->
          {key, opts[:scale], opts[:limit]}

        {key, scale, limit} ->
          {key, scale, limit}
      end

    case throttle(opts[:backend], key, scale, limit, opts[:increment]) do
      {:allow, _count} ->
        {:ok, conn}

      {:deny, _limit} ->
        {:ok, {_count, _count_remaining, ms_to_next_bucket, _created_at, _updated_at}} =
          Hammer.inspect_bucket(key, scale, limit)

        {:error, conn,
         %APIac.Filter.Forbidden{
           filter: __MODULE__,
           reason: :rate_limited,
           error_data: ms_to_next_bucket
         }}

      {:error, reason} ->
        {:error, conn, %APIac.Filter.Forbidden{filter: __MODULE__, reason: reason}}
    end
  end

  defp get_filter_fun(fun) when is_function(fun, 1), do: fun

  defp get_filter_fun(params) when is_list(params) do
    function_name =
      "throttle_" <>
        (params
         |> Enum.sort()
         |> Enum.map(&Atom.to_string/1)
         |> Enum.join("_"))

    Module.concat(APIacFilterThrottler.Functions, function_name)
  end

  defp throttle(nil, key, scale, limit, increment) do
    Hammer.check_rate_inc(key, scale, limit, increment)
  end

  defp throttle(backend, key, scale, limit, increment) do
    Hammer.check_rate_inc(backend, key, scale, limit, increment)
  end

  @doc """
  Implementation of the `APIac.Filter` behaviour.

  ## Verbosity

  The following elements in the HTTP response are set depending on the value
  of the `:error_response_verbosity` option:

  | Error reponse verbosity | HTTP status             | Headers     | Body                                          |
  |:-----------------------:|-------------------------|-------------|-----------------------------------------------|
  | :debug                  | Too many requests (429) | retry-after | `APIac.Filter.Forbidden` exception's message |
  | :normal                 | Too many requests (429) | retry-after |                                               |
  | :minimal                | Forbidden (403)         |             |                                               |

  """
  @impl APIac.Filter
  def send_error_response(conn, %APIac.Filter.Forbidden{error_data: ms_to_next_bucket} = error, opts) do
    # not rounding here because rounding could result in having in an invalid retry_after
    # by less than a second, but that could still confuse automated scripts
    retry_after = Integer.to_string(trunc(ms_to_next_bucket / 1000) + 1)

    verbosity = opts[:error_response_verbosity]

    send_error_response(conn, error, retry_after, verbosity)
  end

  defp send_error_response(conn, error, retry_after, :debug) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after)
    |> Plug.Conn.send_resp(:too_many_requests, Exception.message(error))
    |> Plug.Conn.halt()
  end

  defp send_error_response(conn, _error, retry_after, :normal) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after)
    |> Plug.Conn.send_resp(:too_many_requests, "")
    |> Plug.Conn.halt()
  end

  defp send_error_response(conn, _error, _retry_after, :minimal) do
    conn
    |> Plug.Conn.send_resp(:forbidden, "")
    |> Plug.Conn.halt()
  end
end
