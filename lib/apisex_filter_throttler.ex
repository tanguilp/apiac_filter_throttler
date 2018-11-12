defmodule APISexFilterThrottler do
  @behaviour Plug
  @behaviour APISex.Filter

  @moduledoc """
  An `APISex.Filter` plug for API requests rate-limiting

  This plug uses the [Exhammer](https://github.com/ExHammer/hammer) package as
  for the backend. This library uses the token bucket algorithm, which means that
  this plug is mainly suitable for limiting abuses, not for accurate rate limiting. By
  default, an local ETS backend is launched on startup.

  ## Plug options

  - `key`: one of (no default value):
  a `(Plug.Conn.t -> String.t | {String.t, non_neg_integer(), non_neg_integer()})`
  function, taking in parameter the connection and returning either the key, or the
  tuple `{key, scale, limit}`.
  Note that the `APISexFilterThrottler.Functions` provides with out-of-the-box functions
  - `scale`: the time window of the token bucket algorithm. No default value.
  - `limit`: the maximum limit of the token bucket algorithm. No default value.
  - `increment`: the increment of the token bucket algorithm (defaults to `1`)
  - `backend`: Exhammer's backend, default to `nil`
  - `set_filter_error_response`: if `true`, sets the HTTP status code to `429`.
  If false, does not do anything. Defaults to `true`
  - `halt_on_filter_failure`: if set to `true`, halts the connection and directly sends the
  response. When set to `false`, does nothing and therefore allows dealing with the error
  later in the code. Defaults to `true`

  ##
  """

  @impl Plug
  def init(opts) do
    if opts[:key] == nil, do: raise "`key` is a mandatory parameter"
    if opts[:scale] == nil, do: raise "`scale` is a mandatory parameter"
    if opts[:limit] == nil, do: raise "`limit` is a mandatory parameter"

    opts
    |> Enum.into(%{})
    |> Map.put_new(:increment, 1)
    |> Map.put_new(:backend, nil)
    |> Map.put_new(:set_filter_error_response, true)
    |> Map.put_new(:halt_on_filter_failure, true)
  end

  @impl Plug
  def call(conn, opts) do
    case filter(conn, opts) do
      {:ok, conn} ->
        conn

      {:error, conn, reason} ->
        conn =
          if opts[:set_filter_error_response] do
            set_error_response(conn, reason, opts)
          else
            conn
          end

        if opts[:halt_on_filter_failure] do
          conn
          |> Plug.Conn.send_resp()
          |> Plug.Conn.halt()
        else
          conn
        end
    end
  end

  @impl APISex.Filter
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
        {:ok, {_count, count_remaining, _ms_to_next_bucket, _created_at}} =
          Hammer.inspect_bucket(key, scale, limit)

        {:error, conn, %APISex.Filter.Forbidden{filter: __MODULE__,
                                                reason: :rate_limited,
                                                error_data: count_remaining}}

      {:error, reason} ->
        {:error, conn, %APISex.Filter.Forbidden{filter: __MODULE__, reason: reason}}
    end
  end

  defp get_filter_fun(fun) when is_function(fun, 1), do: fun
  defp get_filter_fun(params) when is_list(params)
  do
    function_name = "throttle_" <>
      (
        params
        |> Enum.sort()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.join("_")
      )

    Module.concat(APISexFilterThrottler.Functions, function_name)
  end

  defp throttle(nil, key, scale, limit, increment) do
    Hammer.check_rate_inc(key, scale, limit, increment)
  end

  defp throttle(backend, key, scale, limit, increment) do
    Hammer.check_rate_inc(backend, key, scale, limit, increment)
  end

  @impl APISex.Filter
  def set_error_response(conn, %APISex.Filter.Forbidden{error_data: count_remaining}, _opts) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", trunc(count_remaining / 1000) + 1)
    |> Plug.Conn.resp(:too_many_requests, "")
  end
end
