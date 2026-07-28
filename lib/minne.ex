defmodule Minne do
  @moduledoc """
  Parses multipart request bodies while streaming files through a configurable adapter.

  The optional policy settings `:allowed_file_fields`, `:allowed_scalar_fields`,
  `:required_file_count`, and `:max_file_size` restrict multipart forms. Scalar
  fields may be a map or keyword list from field name to its individual byte limit.
  When no policy settings are supplied, multipart fields retain their general,
  unrestricted behaviour.
  """

  @behaviour Plug.Parsers
  require Logger

  alias __MODULE__

  @tracker {__MODULE__, :uploads}

  @impl Plug.Parsers
  def init(opts) do
    adapter = Keyword.get(opts, :adapter) || raise "Must supply adapter in options"
    defaults = apply(adapter, :default_opts, [])
    {limit, opts} = Keyword.pop(opts, :length, defaults[:length])
    {read_length, opts} = Keyword.pop(opts, :read_length, defaults[:read_length])
    {headers_opts, opts} = Keyword.pop(opts, :headers, [])
    {limit, headers_opts, [length: read_length, read_length: read_length] ++ opts}
  end

  @impl Plug.Parsers
  def parse(conn, "multipart", subtype, _headers, opts)
      when subtype in ["form-data", "mixed"] do
    Process.put(@tracker, [])

    try do
      result = parse_multipart(conn, opts)

      case result do
        {:ok, _, _} -> :ok
        _ -> abort_tracked(opts)
      end

      result
    rescue
      e in [Plug.UploadError, Plug.Parsers.BadEncodingError] ->
        abort_tracked(opts)
        Logger.error("Minne: #{inspect(e)}")
        reraise e, __STACKTRACE__

      e ->
        abort_tracked(opts)
        Logger.error("Minne multipart parse failed: #{Exception.message(e)}")
        reraise Plug.Parsers.ParseError.exception(exception: e), __STACKTRACE__
    catch
      kind, reason ->
        abort_tracked(opts)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(@tracker)
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp parse_multipart(conn, {{module, fun, args}, headers, opts}) do
    parse_multipart(conn, {apply(module, fun, args), headers, opts})
  end

  defp parse_multipart(conn, {limit, headers_opts, opts}) do
    state = %{limit: limit, acc: [], uploads: [], file_count: 0}

    case parse_parts(Plug.Conn.read_part_headers(conn, headers_opts), state, opts, headers_opts) do
      {:ok, state, conn} ->
        validate_terminal!(state, opts)
        uploads = close_uploads(state.uploads, opts)
        acc = replace_uploads(state.acc, uploads)
        {:ok, Enum.reduce(acc, %{}, &Plug.Conn.Query.decode_pair/2), conn}

      {:too_large, conn} ->
        {:error, :too_large, conn}
    end
  end

  defp parse_parts({:done, conn}, state, _opts, _headers_opts), do: {:ok, state, conn}

  defp parse_parts({:ok, headers, conn}, state, opts, headers_opts) do
    case parse_part(headers, conn, state, opts) do
      {:ok, state, conn} ->
        parse_parts(Plug.Conn.read_part_headers(conn, headers_opts), state, opts, headers_opts)

      {:too_large, conn} ->
        {:too_large, conn}
    end
  end

  defp parse_part(headers, conn, state, opts) do
    case multipart_type(headers, opts) do
      {:binary, name} ->
        parse_scalar(name, headers, conn, state, opts, false)

      {:part, name} ->
        parse_scalar(name, headers, conn, state, opts, true)

      {:file, name, upload} ->
        parse_file(name, upload, conn, state, opts)

      {:empty_file, name} ->
        if policy?(opts) do
          raise "file field #{inspect(name)} has no filename"
        else
          {:ok, state, conn}
        end

      :skip ->
        if policy?(opts), do: raise("malformed or unnamed multipart field")
        {:ok, state, conn}
    end
  end

  defp parse_scalar(name, headers, conn, state, opts, unnamed?) do
    scalar_limit = scalar_limit!(name, opts)
    scalar_opts = scalar_read_opts(opts, scalar_limit)

    case read_scalar(
           Plug.Conn.read_part_body(conn, scalar_opts),
           state.limit,
           scalar_limit,
           scalar_opts,
           []
         ) do
      {:ok, body, limit, conn} ->
        if Keyword.get(opts, :validate_utf8, true) and not unnamed? do
          Plug.Conn.Utils.validate_utf8!(body, Plug.Parsers.BadEncodingError, "multipart body")
        end

        value = if unnamed?, do: %{headers: headers, body: body}, else: body
        {:ok, %{state | limit: limit, acc: [{name, value} | state.acc]}, conn}

      {:too_large, conn} ->
        {:too_large, conn}
    end
  end

  defp read_scalar({status, chunk, conn}, total, scalar, opts, acc)
       when status in [:more, :ok] do
    size = byte_size(chunk)

    if size > total or (is_integer(scalar) and size > scalar) do
      {:too_large, conn}
    else
      acc = [chunk | acc]
      total = total - size
      scalar = if is_integer(scalar), do: scalar - size, else: scalar

      if status == :ok do
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), total, conn}
      else
        read_scalar(Plug.Conn.read_part_body(conn, opts), total, scalar, opts, acc)
      end
    end
  end

  defp parse_file(name, upload, conn, state, opts) do
    try do
      validate_file_field!(name, state.file_count, opts)
    rescue
      error ->
        adapter(upload, :abort, [], opts)
        reraise error, __STACKTRACE__
    end

    upload = prepare_upload(upload, conn, opts)
    track(upload)

    case read_file(Plug.Conn.read_part_body(conn, opts), state.limit, 0, upload, opts) do
      {:ok, upload, limit, conn} ->
        track(upload)
        index = length(state.uploads)

        {:ok,
         %{
           state
           | limit: limit,
             file_count: state.file_count + 1,
             uploads: state.uploads ++ [upload],
             acc: [{name, {:pending_upload, index}} | state.acc]
         }, conn}

      {:too_large, conn, upload} ->
        track(upload)
        {:too_large, conn}
    end
  end

  defp read_file({status, chunk, conn}, total, file_size, upload, opts)
       when status in [:more, :ok] do
    size = byte_size(chunk)
    max_file_size = Keyword.get(opts, :max_file_size, :infinity)

    if size > total or (is_integer(max_file_size) and file_size + size > max_file_size) do
      {:too_large, conn, upload}
    else
      case adapter(upload, :write_part, [chunk, size, status == :ok], opts) do
        {:ok, upload} ->
          continue_file(status, conn, total - size, file_size + size, upload, opts)

        %Minne.Upload{} = upload ->
          continue_file(status, conn, total - size, file_size + size, upload, opts)

        {:error, reason} ->
          raise "upload adapter write failed: #{inspect(reason)}"
      end
    end
  end

  defp continue_file(:ok, conn, total, _file_size, upload, _opts),
    do: {:ok, upload, total, conn}

  defp continue_file(:more, conn, total, file_size, upload, opts) do
    track(upload)
    read_file(Plug.Conn.read_part_body(conn, opts), total, file_size, upload, opts)
  end

  defp prepare_upload(upload, conn, opts) do
    privacy = Map.get(conn.assigns, :privacy, :public)

    upload = %{
      upload
      | request_url: conn.request_path,
        content_encoding: get_header(conn.req_headers, "content-encoding"),
        private: privacy == :private
    }

    adapter(upload, :start, [], opts)
  end

  defp close_uploads(uploads, opts) do
    Enum.map(uploads, fn upload ->
      closed = adapter(upload, :close, [], opts)
      track(closed)
      closed
    end)
  end

  defp replace_uploads(acc, uploads) do
    Enum.map(acc, fn
      {name, {:pending_upload, index}} -> {name, Enum.at(uploads, index)}
      pair -> pair
    end)
  end

  defp validate_terminal!(state, opts) do
    case Keyword.fetch(opts, :required_file_count) do
      {:ok, count} when state.file_count != count -> raise "invalid multipart file count"
      _ -> :ok
    end
  end

  defp validate_file_field!(name, count, opts) do
    if fields = Keyword.get(opts, :allowed_file_fields) do
      unless name in fields, do: raise("unexpected multipart file field")
    end

    if required = Keyword.get(opts, :required_file_count) do
      if count >= required, do: raise("too many multipart file parts")
    end
  end

  defp scalar_limit!(name, opts) do
    case Keyword.fetch(opts, :allowed_scalar_fields) do
      :error ->
        :infinity

      {:ok, fields} ->
        fields =
          if Keyword.keyword?(fields),
            do: Map.new(fields, fn {k, v} -> {to_string(k), v} end),
            else: fields

        case Map.fetch(fields, name) do
          {:ok, limit} -> limit
          :error -> raise "unexpected multipart scalar field"
        end
    end
  end

  defp policy?(opts) do
    Enum.any?(
      [:allowed_file_fields, :allowed_scalar_fields, :required_file_count],
      &Keyword.has_key?(opts, &1)
    )
  end

  defp scalar_read_opts(opts, :infinity), do: opts

  defp scalar_read_opts(opts, limit) when is_integer(limit) and limit >= 0 do
    read_size = limit + 1

    opts
    |> Keyword.put(:length, read_size)
    |> Keyword.put(:read_length, read_size)
  end

  defp track(upload) do
    uploads = Process.get(@tracker, [])
    module = upload.adapter.__struct__

    Process.put(@tracker, [
      {module, upload} | Enum.reject(uploads, fn {_, old} -> same_upload?(old, upload) end)
    ])
  end

  defp same_upload?(left, right) do
    left.adapter.__struct__ == right.adapter.__struct__ and
      Map.get(left.adapter, :path) == Map.get(right.adapter, :path) and
      Map.get(left.adapter, :key) == Map.get(right.adapter, :key)
  end

  defp abort_tracked({_limit, _headers, opts}), do: abort_tracked(opts)

  defp abort_tracked(opts) do
    Enum.each(Process.get(@tracker, []), fn {module, upload} ->
      try do
        apply(module, :abort, [upload, opts[:adapter_opts]])
      rescue
        error -> Logger.error("Minne adapter abort failed: #{Exception.message(error)}")
      end
    end)
  end

  defp adapter(upload, fun, args, opts) do
    apply(upload.adapter.__struct__, fun, [upload | args] ++ [opts[:adapter_opts]])
  end

  defp multipart_type(headers, opts) do
    if disposition = get_header(headers, "content-disposition") do
      multipart_type_from_disposition(headers, disposition, opts)
    else
      case Keyword.fetch(opts, :include_unnamed_parts_at) do
        {:ok, name} when is_binary(name) -> {:part, name <> "[]"}
        :error -> :skip
      end
    end
  end

  defp multipart_type_from_disposition(headers, disposition, opts) do
    with [_, params] <- :binary.split(disposition, ";"),
         %{"name" => name} = params <- Plug.Conn.Utils.params(params) do
      case params do
        %{"filename" => ""} ->
          {:empty_file, name}

        %{"filename" => filename} ->
          {:file, name, create_upload(filename, headers, opts)}

        %{"filename*" => ""} ->
          {:empty_file, name}

        %{"filename*" => "utf-8''" <> filename} ->
          filename = URI.decode(filename)

          Plug.Conn.Utils.validate_utf8!(
            filename,
            Plug.Parsers.BadEncodingError,
            "multipart filename"
          )

          {:file, name, create_upload(filename, headers, opts)}

        %{} ->
          {:binary, name}
      end
    else
      _ -> :skip
    end
  end

  defp create_upload(filename, headers, opts) do
    upload =
      opts
      |> Keyword.get(:adapter, Minne.Adapter.Temp)
      |> struct()
      |> Minne.Upload.new()
      |> Map.merge(%{filename: filename, content_type: get_header(headers, "content-type")})

    adapter(upload, :init, [], opts)
  end

  def get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end
end
