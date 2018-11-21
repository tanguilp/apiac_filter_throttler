# APISexFilterThrottler

An `APISex.Filter` plug for API requests rate-limiting

This plug uses the [Exhammer](https://github.com/ExHammer/hammer) package as
its backend. This library uses the token bucket algorithm, which means that
this plug is mainly suitable for limiting abuses, not for accurate rate limiting. By
default, a local ETS backend is launched on startup.

## Plug options

- `key`: a
`(Plug.Conn.t -> String.t | {String.t, non_neg_integer(), non_neg_integer()})`
function, taking in parameter the connection and returning either the key, or the
tuple `{key, scale, limit}`. No default value.
Note that the `APISexFilterThrottler.Functions` provides with out-of-the-box functions
- `scale`: the time window of the token bucket algorithm, in milliseconds. No default value.
- `limit`: the maximum limit of the token bucket algorithm, in milliseconds. No default value.
- `increment`: the increment of the token bucket algorithm (defaults to `1`)
- `backend`: Exhammer's backend, defaults to `nil`
- `exec_cond`: a `(Plug.Conn.t() -> boolean())` function that determines whether
this filter is to be executed or not. Defaults to `fn _ -> true end`
- `send_error_response`: function called when request is throttled. Defaults to
`APISexFilterThrottler.send_error_response/3`
- `error_response_verbosity`: one of `:debug`, `:normal` or `:minimal`.
Defaults to `:normal`

## Example

Allow 50 request / 10 seconds per subject and per client:

```elixir
plug APISexFilterThrottler, key: &APISexFilterThrottler.Functions.throttle_by_subject_client/1,
  scale: 10_000,
  limit: 50
```

Allow 5000 requests / minute per client, only for machine-to-machine access:

```elixir
plug APISexFilterThrottler, key: &APISexFilterThrottler.Functions.throttle_by_client/1,
  exec_cond: &APISex.machine_to_machine?/1,
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
