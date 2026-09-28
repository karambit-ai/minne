defmodule Minne.Adapter.S3 do
  @moduledoc """
  Streams multipart form files to an S3-compatible object store.

  Multipart uploads retain at most `max_in_flight_parts * part_size` bytes in
  S3 upload tasks per request. Once the configured window is full, parsing
  waits for the oldest part and therefore applies backpressure to the inbound
  request.
  """

  require Logger
  @behaviour Minne.Adapter

  @min_part_size 5_242_880
  @max_part_size 5_368_709_120
  @default_max_parts 10_000
  @default_max_in_flight_parts 4
  @default_part_timeout 300_000
  @default_complete_timeout 300_000
  @default_abort_timeout 30_000

  defstruct key: "",
            bucket: "",
            parts: [],
            in_flight_parts: [],
            parts_count: 0,
            upload_id: nil,
            hashes: %{},
            max_file_size: 0,
            part_size: @min_part_size,
            max_parts: @default_max_parts,
            max_in_flight_parts: @default_max_in_flight_parts,
            part_timeout: @default_part_timeout,
            complete_timeout: @default_complete_timeout,
            abort_timeout: @default_abort_timeout,
            path_function: nil,
            bucket_function: nil,
            private: nil

  @impl Minne.Adapter
  def default_opts, do: [length: 16_000_000_000, read_length: @min_part_size]

  @impl Minne.Adapter
  def init(upload, opts) do
    part_size = Keyword.get(opts, :part_size, @min_part_size)
    max_parts = Keyword.get(opts, :max_parts, @default_max_parts)
    max_in_flight_parts = Keyword.get(opts, :max_in_flight_parts, @default_max_in_flight_parts)
    part_timeout = Keyword.get(opts, :part_timeout, @default_part_timeout)
    complete_timeout = Keyword.get(opts, :complete_timeout, @default_complete_timeout)
    abort_timeout = Keyword.get(opts, :abort_timeout, @default_abort_timeout)

    with {:ok, bucket_function} <- required_function(opts, :bucket_function),
         {:ok, path_function} <- required_function(opts, :path_function),
         {:ok, max_file_size} <- positive_integer(opts, :max_file_size),
         :ok <- integer_between(part_size, @min_part_size, @max_part_size, :part_size),
         :ok <- integer_between(max_parts, 1, @default_max_parts, :max_parts),
         :ok <-
           integer_between(
             max_in_flight_parts,
             1,
             max_parts,
             :max_in_flight_parts
           ),
         :ok <- positive(part_timeout, :part_timeout),
         :ok <- positive(complete_timeout, :complete_timeout),
         :ok <- positive(abort_timeout, :abort_timeout),
         :ok <- validate_part_budget(max_file_size, part_size, max_parts) do
      adapter = %{
        upload.adapter
        | bucket_function: bucket_function,
          path_function: path_function,
          max_file_size: max_file_size,
          part_size: part_size,
          max_parts: max_parts,
          max_in_flight_parts: max_in_flight_parts,
          part_timeout: part_timeout,
          complete_timeout: complete_timeout,
          abort_timeout: abort_timeout,
          hashes: new_hashes()
      }

      %{upload | adapter: adapter}
    end
  end

  @impl Minne.Adapter
  def start(upload, _opts) do
    {key, private?} = upload.adapter.path_function.(upload)
    bucket = upload.adapter.bucket_function.(upload)
    Logger.info("Minne: buffering upload for: #{bucket}/#{key}")
    %{upload | adapter: %{upload.adapter | key: key, bucket: bucket, private: private?}}
  end

  @impl Minne.Adapter
  def write_part(upload, chunk, size, final?, _opts) do
    if upload.size + size > upload.adapter.max_file_size do
      abort(upload, [])
      {:error, :too_large}
    else
      upload = %{
        upload
        | size: upload.size + size,
          remainder_bytes: upload.remainder_bytes <> chunk,
          adapter: update_hashes(upload.adapter, chunk)
      }

      case flush_full_parts(upload) do
        {:ok, upload} ->
          finish_write(upload, final?)

        {:error, reason, upload} ->
          abort(upload, [])
          {:error, reason}
      end
    end
  end

  defp finish_write(upload, false), do: {:ok, upload}

  defp finish_write(upload, true) do
    case flush_remainder(upload) do
      {:ok, upload} ->
        {:ok, drain_all(upload)}

      {:error, reason, upload} ->
        abort(upload, [])
        {:error, reason}
    end
  end

  @impl Minne.Adapter
  def close(%{adapter: %{upload_id: nil}} = upload, _opts) do
    if upload.size > upload.adapter.max_file_size, do: raise("upload exceeds max_file_size")
    client().put_object(upload.adapter.bucket, upload.adapter.key, upload.remainder_bytes)

    %{
      upload
      | remainder_bytes: "",
        adapter: finalize_hashes(upload.adapter)
    }
  end

  def close(upload, _opts) do
    upload =
      case flush_remainder(upload) do
        {:ok, upload} ->
          upload

        {:error, reason, upload} ->
          abort(upload, [])
          raise "multipart upload failed: #{inspect(reason)}"
      end

    upload = drain_all(upload)

    try do
      parts = Enum.reverse(upload.adapter.parts)

      run_operation(
        fn ->
          client().complete_multipart_upload(
            upload.adapter.bucket,
            upload.adapter.key,
            upload.adapter.upload_id,
            parts
          )
        end,
        upload.adapter.complete_timeout,
        "multipart completion timed out"
      )

      adapter = upload.adapter |> Map.put(:parts, parts) |> finalize_hashes()
      %{upload | adapter: adapter}
    rescue
      error ->
        abort(upload, [])
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        abort(upload, [])
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @impl Minne.Adapter
  def abort(%{adapter: %{upload_id: nil}}, _opts), do: :ok

  def abort(upload, _opts) do
    Enum.each(upload.adapter.in_flight_parts, fn entry ->
      Task.shutdown(entry.task, :brutal_kill)
    end)

    run_operation(
      fn ->
        client().abort_multipart_upload(
          upload.adapter.bucket,
          upload.adapter.key,
          upload.adapter.upload_id
        )
      end,
      upload.adapter.abort_timeout,
      "multipart abort timed out"
    )

    :ok
  rescue
    error ->
      Logger.error("Minne: failed to abort multipart upload: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("Minne: failed to abort multipart upload: #{inspect({kind, reason})}")
      :ok
  end

  defp flush_full_parts(upload)
       when byte_size(upload.remainder_bytes) < upload.adapter.part_size,
       do: {:ok, upload}

  defp flush_full_parts(upload) do
    part_size = upload.adapter.part_size
    <<chunk::binary-size(^part_size), remainder::binary>> = upload.remainder_bytes

    case enqueue_part(%{upload | remainder_bytes: remainder}, chunk) do
      {:ok, upload} -> flush_full_parts(upload)
      {:error, reason, upload} -> {:error, reason, upload}
    end
  end

  defp flush_remainder(%{remainder_bytes: ""} = upload), do: {:ok, upload}

  defp flush_remainder(upload) do
    chunk = upload.remainder_bytes
    enqueue_part(%{upload | remainder_bytes: ""}, chunk)
  end

  defp ensure_upload_id(%{adapter: %{upload_id: nil} = adapter} = upload) do
    %{body: %{upload_id: upload_id}} =
      client().initiate_multipart_upload(adapter.bucket, adapter.key)

    %{upload | adapter: %{adapter | upload_id: upload_id}}
  end

  defp ensure_upload_id(upload), do: upload

  defp enqueue_part(upload, chunk) do
    upload = ensure_upload_id(upload)
    count = upload.adapter.parts_count + 1

    if count > upload.adapter.max_parts do
      {:error, :too_many_parts, upload}
    else
      entry = upload_async(upload, count, chunk)

      adapter = %{
        upload.adapter
        | parts_count: count,
          in_flight_parts: upload.adapter.in_flight_parts ++ [entry]
      }

      upload = %{upload | adapter: adapter}

      if length(adapter.in_flight_parts) >= adapter.max_in_flight_parts,
        do: {:ok, drain_one(upload)},
        else: {:ok, upload}
    end
  end

  defp upload_async(upload, number, chunk) do
    task =
      Task.async(fn ->
        try do
          %{headers: headers} =
            run_operation(
              fn ->
                client().upload_part(
                  upload.adapter.bucket,
                  upload.adapter.key,
                  upload.adapter.upload_id,
                  number,
                  chunk
                )
              end,
              upload.adapter.part_timeout,
              "multipart part upload timed out"
            )

          {:ok, {number, Minne.get_header(headers, "ETag")}}
        rescue
          error -> {:error, :error, error, __STACKTRACE__}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end
      end)

    %{task: task}
  end

  defp drain_all(%{adapter: %{in_flight_parts: []}} = upload), do: upload
  defp drain_all(upload), do: upload |> drain_one() |> drain_all()

  defp drain_one(upload) do
    [entry | remaining] = upload.adapter.in_flight_parts
    upload = put_in(upload.adapter.in_flight_parts, remaining)

    try do
      part = await_part(entry.task, upload.adapter.part_timeout)
      update_in(upload.adapter.parts, &[part | &1])
    rescue
      error ->
        abort(upload, [])
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        abort(upload, [])
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp await_part(task, timeout) do
    case Task.yield(task, timeout + 1_000) do
      {:ok, {:ok, part}} ->
        part

      {:ok, {:error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:exit, reason} ->
        exit(reason)

      nil ->
        raise_part_timeout(task)
    end
  end

  defp raise_part_timeout(task) do
    Task.shutdown(task, :brutal_kill)
    raise "multipart part upload timed out"
  end

  defp run_operation(function, timeout, timeout_message) do
    task =
      Task.async(fn ->
        try do
          {:ok, function.()}
        rescue
          error -> {:error, :error, error, __STACKTRACE__}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:exit, reason} ->
        exit(reason)

      nil ->
        Task.shutdown(task, :brutal_kill)
        raise timeout_message
    end
  end

  defp required_function(opts, key) do
    case Keyword.get(opts, key) do
      function when is_function(function, 1) -> {:ok, function}
      _other -> {:error, "#{key} is required to use minne's s3 adapter"}
    end
  end

  defp positive_integer(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp integer_between(value, minimum, maximum, _key)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp integer_between(_value, minimum, maximum, key),
    do: {:error, "#{key} must be an integer between #{minimum} and #{maximum}"}

  defp positive(value, _key) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, key), do: {:error, "#{key} must be a positive integer"}

  defp validate_part_budget(max_file_size, part_size, max_parts) do
    required_parts = div(max_file_size + part_size - 1, part_size)

    if required_parts <= max_parts,
      do: :ok,
      else: {:error, "max_file_size requires more than #{max_parts} multipart parts"}
  end

  defp new_hashes do
    %{
      sha256: :crypto.hash_init(:sha256),
      sha1: :crypto.hash_init(:sha),
      md5: :crypto.hash_init(:md5)
    }
  end

  defp update_hashes(%{hashes: hashes} = adapter, chunk) do
    hashes = %{
      sha256: :crypto.hash_update(hashes.sha256, chunk),
      sha1: :crypto.hash_update(hashes.sha1, chunk),
      md5: :crypto.hash_update(hashes.md5, chunk)
    }

    %{adapter | hashes: hashes}
  end

  defp finalize_hashes(%{hashes: %{sha256: digest}} = adapter) when is_binary(digest),
    do: adapter

  defp finalize_hashes(%{hashes: hashes} = adapter) do
    hashes = %{
      sha256: encode_hash(hashes.sha256),
      sha1: encode_hash(hashes.sha1),
      md5: encode_hash(hashes.md5)
    }

    %{adapter | hashes: hashes}
  end

  defp encode_hash(state), do: state |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp client, do: Application.get_env(:minne, :s3_client, Minne.Clients.S3)
end
