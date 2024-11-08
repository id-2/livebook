defmodule Livebook.Utils.HTTP do
  @type status :: non_neg_integer()
  @type headers :: %{String.t() => list(String.t())}
  @type header :: {String.t(), String.t()}

  @doc """
  Retrieves content type from response headers.
  """
  @spec fetch_content_type(headers()) :: {:ok, String.t()} | :error
  def fetch_content_type(headers) do
    with {:ok, [value]} <- Map.fetch(headers, "content-type") do
      {:ok, value |> String.split(";") |> hd()}
    else
      _ -> :error
    end
  end

  @doc """
  Makes an HTTP request.

  ## Options

    * `headers` - request headers, defaults to `[]`

    * `body` - request body given as `{content_type, body}`

    * `timeout` - request timeout, defaults to 10 seconds

  """
  @spec request(atom(), String.t(), keyword()) ::
          {:ok, %{status: status(), headers: headers(), body: binary()}} | {:error, term()}
  def request(method, url, opts \\ [])
      when is_atom(method) and is_binary(url) and is_list(opts) do
    headers = build_headers(opts[:headers] || [])

    request =
      case opts[:body] do
        nil -> {url, headers}
        {content_type, body} -> {url, headers, to_charlist(content_type), body}
      end

    http_opts = [
      ssl: http_ssl_opts(),
      timeout: opts[:timeout] || 10_000
    ]

    opts = [
      body_format: :binary
    ]

    case :httpc.request(method, request, http_opts, opts) do
      {:ok, {{_, status, _}, headers, body}} ->
        {:ok, %{status: status, headers: parse_headers(headers), body: body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_headers(entries) do
    headers =
      Enum.map(entries, fn {key, value} ->
        {to_charlist(key), to_charlist(value)}
      end)

    [{~c"user-agent", ~c"livebook"} | headers]
  end

  defp parse_headers(headers) do
    headers
    |> Enum.map(fn {key, val} ->
      {String.downcase(to_string(key)), to_string(val)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new()
  end

  @doc """
  Downloads resource at the given URL into `collectable`.

  If collectable raises an error, it is rescued and an error tuple
  is returned.

  ## Options

    * `:headers` - request headers

  """
  @spec download(String.t(), Collectable.t(), keyword()) ::
          {:ok, Collectable.t()} | {:error, String.t(), status()}
  def download(url, collectable, opts \\ []) do
    headers = build_headers(opts[:headers] || [])

    request = {url, headers}
    http_opts = [ssl: http_ssl_opts()]

    caller = self()

    receiver = fn reply_info ->
      request_id = elem(reply_info, 0)

      # Cancel the request if the caller terminates
      if Process.alive?(caller) do
        send(caller, {:http, reply_info})
      else
        :httpc.cancel_request(request_id)
      end
    end

    opts = [stream: :self, sync: false, receiver: receiver]

    {:ok, request_id} = :httpc.request(:get, request, http_opts, opts)

    try do
      {acc, collector} = Collectable.into(collectable)

      try do
        download_loop(%{
          request_id: request_id,
          total_size: nil,
          size: nil,
          acc: acc,
          collector: collector
        })
      catch
        kind, reason ->
          collector.(acc, :halt)
          :httpc.cancel_request(request_id)
          exception = Exception.normalize(kind, reason, __STACKTRACE__)
          {:error, Exception.message(exception), nil}
      else
        {:ok, state} ->
          acc = state.collector.(state.acc, :done)
          {:ok, acc}

        {:error, message, status} ->
          collector.(acc, :halt)
          :httpc.cancel_request(request_id)
          {:error, message, status}
      end
    catch
      kind, reason ->
        :httpc.cancel_request(request_id)
        exception = Exception.normalize(kind, reason, __STACKTRACE__)
        {:error, Exception.message(exception), nil}
    end
  end

  defp download_loop(state) do
    receive do
      {:http, reply_info} when elem(reply_info, 0) == state.request_id ->
        download_receive(state, reply_info)
    end
  end

  defp download_receive(_state, {_, {:error, error}}) do
    {:error, "reason: #{inspect(error)}", nil}
  end

  defp download_receive(state, {_, {{_, 200, _}, _headers, body}}) do
    acc = state.collector.(state.acc, {:cont, body})
    {:ok, %{state | acc: acc}}
  end

  defp download_receive(_state, {_, {{_, status, _}, _headers, _body}}) do
    {:error, "got HTTP status: #{status}", status}
  end

  defp download_receive(state, {_, :stream_start, headers}) do
    total_size = total_size(headers)
    download_loop(%{state | total_size: total_size, size: 0})
  end

  defp download_receive(state, {_, :stream, body_part}) do
    acc = state.collector.(state.acc, {:cont, body_part})
    state = %{state | acc: acc}

    part_size = byte_size(body_part)
    state = update_in(state.size, &(&1 + part_size))
    download_loop(state)
  end

  defp download_receive(state, {_, :stream_end, _headers}) do
    {:ok, state}
  end

  defp total_size(headers) do
    case List.keyfind(headers, ~c"content-length", 0) do
      {_, content_length} ->
        List.to_integer(content_length)

      _ ->
        nil
    end
  end

  defp http_ssl_opts() do
    # Use secure options, see https://gist.github.com/jonatanklosko/5e20ca84127f6b31bbe3906498e1a1d7

    cacert_opt =
      if cacertfile = Livebook.Config.cacertfile() do
        {:cacertfile, to_charlist(cacertfile)}
      else
        {:cacerts, :public_key.cacerts_get()}
      end

    [
      cacert_opt,
      verify: :verify_peer,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  @doc false
  def set_proxy_options() do
    http_proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
    https_proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")

    no_proxy =
      if no_proxy = System.get_env("NO_PROXY") || System.get_env("no_proxy") do
        no_proxy
        |> String.split(",")
        |> Enum.map(&String.to_charlist/1)
      else
        []
      end

    set_proxy_option(:proxy, http_proxy, no_proxy)
    set_proxy_option(:https_proxy, https_proxy, no_proxy)
  end

  defp set_proxy_option(proxy_scheme, proxy, no_proxy) do
    uri = URI.parse(proxy || "")

    if uri.host && uri.port do
      host = String.to_charlist(uri.host)
      :httpc.set_options([{proxy_scheme, {{host, uri.port}, no_proxy}}])
    end
  end
end
