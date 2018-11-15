defmodule APISexFilterThrottlerTest do
  use ExUnit.Case
  use Plug.Test
  doctest APISexFilterThrottler

  test "No throttling (by ip)" do
    opts =
      APISexFilterThrottler.init(
        key: &APISexFilterThrottler.Functions.throttle_by_ip/1,
        scale: 10_000,
        limit: 5
      )

    conn =
      conn(:get, "/")
      |> put_ip_address({23, 91, 178, 41})
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)

    refute conn.status == 429
    refute conn.halted
  end

  test "Throttling (by ip)" do
    opts =
      APISexFilterThrottler.init(
        key: &APISexFilterThrottler.Functions.throttle_by_ip/1,
        scale: 10_000,
        limit: 5
      )

    conn =
      conn(:get, "/")
      |> put_ip_address({136, 66, 6, 7})
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)
      |> APISexFilterThrottler.call(opts)

    assert conn.status == 429
    assert conn.halted
  end

  defp put_ip_address(conn, ip_address) do
    %{conn | remote_ip: ip_address}
  end
end
