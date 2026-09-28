defmodule Minne.TestS3Client do
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    Agent.start_link(fn -> initial_state([]) end,
      name: __MODULE__
    )
  end

  def reset(failures \\ [], opts \\ []) do
    Agent.update(__MODULE__, fn _ -> initial_state(failures, opts) end)
  end

  def state, do: Agent.get(__MODULE__, & &1)

  def put_object(_bucket, _key, body) do
    Agent.update(__MODULE__, &%{&1 | put_bodies: [body | &1.put_bodies]})
    %{}
  end

  def initiate_multipart_upload(_bucket, _key) do
    Agent.update(__MODULE__, &Map.update!(&1, :initiate_count, fn count -> count + 1 end))
    %{body: %{upload_id: "upload-id"}}
  end

  def upload_part(_bucket, _key, _upload_id, part_number, _chunk) do
    Agent.update(__MODULE__, fn state ->
      active = state.active_parts + 1

      %{
        state
        | active_parts: active,
          max_active_parts: max(active, state.max_active_parts),
          uploaded_parts: [part_number | state.uploaded_parts]
      }
    end)

    Process.sleep(state().part_delay)
    Agent.update(__MODULE__, &%{&1 | active_parts: &1.active_parts - 1})
    if :part in state().failures, do: raise("part failed")
    %{headers: [{"ETag", "etag-#{part_number}"}]}
  end

  def complete_multipart_upload(_bucket, _key, _upload_id, parts) do
    Agent.update(__MODULE__, fn state ->
      %{state | complete_count: state.complete_count + 1, completed_parts: parts}
    end)

    Process.sleep(state().complete_delay)
    if :complete in state().failures, do: raise("complete failed")
    %{}
  end

  def abort_multipart_upload(_bucket, _key, _upload_id) do
    Agent.update(__MODULE__, &Map.update!(&1, :abort_count, fn count -> count + 1 end))
    Process.sleep(state().abort_delay)
    if :abort in state().failures, do: raise("abort failed")
    %{}
  end

  defp initial_state(failures, opts \\ []) do
    %{
      abort_count: 0,
      abort_delay: Keyword.get(opts, :abort_delay, 0),
      active_parts: 0,
      completed_parts: [],
      complete_delay: Keyword.get(opts, :complete_delay, 0),
      complete_count: 0,
      failures: failures,
      initiate_count: 0,
      max_active_parts: 0,
      part_delay: Keyword.get(opts, :part_delay, 0),
      put_bodies: [],
      uploaded_parts: []
    }
  end
end

defmodule Minne.Adapter.S3Test do
  use ExUnit.Case, async: false

  alias Minne.Adapter.S3

  @chunk_size 5_242_880
  @gib 1_073_741_824

  setup_all do
    previous_client = Application.get_env(:minne, :s3_client)
    Application.put_env(:minne, :s3_client, Minne.TestS3Client)
    on_exit(fn -> Application.put_env(:minne, :s3_client, previous_client) end)
    start_supervised!(Minne.TestS3Client)
    :ok
  end

  setup do
    Minne.TestS3Client.reset()
    :ok
  end

  test "finalizes hashes when the upload is an exact chunk multiple" do
    bytes = String.duplicate("x", @chunk_size)

    upload =
      new_upload()
      |> write(bytes)
      |> S3.close([])

    assert upload.adapter.hashes.sha256 == sha256(bytes)
    assert byte_size(upload.adapter.hashes.sha256) == 64
    assert Minne.TestS3Client.state().complete_count == 1
    assert Minne.TestS3Client.state().abort_count == 0
  end

  test "publishes a small object only on close" do
    upload = new_upload() |> write("small")

    assert Minne.TestS3Client.state().put_bodies == []
    assert Minne.TestS3Client.state().initiate_count == 0

    upload = S3.close(upload, [])
    assert Minne.TestS3Client.state().put_bodies == ["small"]
    assert upload.adapter.hashes.sha256 == sha256("small")
  end

  test "enforces max size before publishing a small object" do
    upload = new_upload(max_file_size: 4)
    assert {:error, :too_large} = S3.write_part(upload, "small", 5, false, options())
    assert Minne.TestS3Client.state().put_bodies == []
  end

  test "accepts a 100 GiB budget with a 16 MiB part size" do
    upload =
      new_upload(
        max_file_size: 100 * @gib,
        part_size: 16 * 1_024 * 1_024,
        max_parts: 10_000,
        max_in_flight_parts: 4
      )

    assert upload.adapter.part_size == 16 * 1_024 * 1_024
    assert upload.adapter.max_parts == 10_000
    assert upload.adapter.max_in_flight_parts == 4
  end

  test "rejects a maximum size that exceeds the configured part budget" do
    upload = Minne.Upload.new(%S3{})

    assert {:error, message} =
             S3.init(
               upload,
               Keyword.merge(options(),
                 max_file_size: 100 * @gib,
                 part_size: 10 * 1_024 * 1_024,
                 max_parts: 10_000
               )
             )

    assert message =~ "max_file_size requires more than 10000 multipart parts"
  end

  test "bounds in-flight parts and completes them in part-number order" do
    Minne.TestS3Client.reset([], part_delay: 25)
    bytes = String.duplicate("x", @chunk_size)

    upload =
      new_upload(max_file_size: 3 * @chunk_size, max_in_flight_parts: 2)
      |> write(bytes)
      |> write(bytes)
      |> write(bytes)
      |> S3.close([])

    state = Minne.TestS3Client.state()
    assert state.max_active_parts == 2
    assert state.completed_parts == [{1, "etag-1"}, {2, "etag-2"}, {3, "etag-3"}]
    assert upload.adapter.parts_count == 3
  end

  test "times out a slow part and aborts its multipart upload" do
    Minne.TestS3Client.reset([], part_delay: 50)
    bytes = String.duplicate("x", @chunk_size)
    upload = new_upload(max_in_flight_parts: 1, part_timeout: 1)

    assert_raise RuntimeError, "multipart part upload timed out", fn -> write(upload, bytes) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "public abort aborts an initiated upload with no completed parts" do
    upload = new_upload() |> write(String.duplicate("x", @chunk_size))
    assert upload.adapter.upload_id == "upload-id"
    assert :ok = S3.abort(upload, [])
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "aborts the multipart upload when a part fails" do
    Minne.TestS3Client.reset([:part])
    upload = new_upload(max_in_flight_parts: 2) |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "part failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "preserves the part failure when abort also fails" do
    Minne.TestS3Client.reset([:part, :abort])
    upload = new_upload(max_in_flight_parts: 2) |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "part failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "preserves the part failure when abort times out" do
    Minne.TestS3Client.reset([:part], abort_delay: 50)

    upload =
      new_upload(max_in_flight_parts: 2, abort_timeout: 1)
      |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "part failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "aborts the multipart upload when completion fails" do
    Minne.TestS3Client.reset([:complete])
    upload = new_upload() |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "complete failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().complete_count == 1
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "aborts the multipart upload when completion times out" do
    Minne.TestS3Client.reset([], complete_delay: 50)

    upload =
      new_upload(complete_timeout: 1)
      |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "multipart completion timed out", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  defp new_upload(overrides \\ []) do
    upload =
      %S3{}
      |> Minne.Upload.new()
      |> Map.merge(%{filename: "sample.bin", content_type: "application/octet-stream"})
      |> S3.init(Keyword.merge(options(), overrides))

    S3.start(upload, Keyword.merge(options(), overrides))
  end

  defp write(upload, bytes) do
    assert {:ok, upload} = S3.write_part(upload, bytes, byte_size(bytes), false, options())
    upload
  end

  defp options do
    [
      max_file_size: 20 * 1_024 * 1_024,
      bucket_function: fn _upload -> "bucket" end,
      path_function: fn _upload -> {"key", false} end
    ]
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
