# Minne

Multipart form parser for plug based applications that allows customizing the file handling behaviour.
To be used as a replacement for the built in :multipart handler.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `minne` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:minne, "~> 0.1.0"}
  ]
end
```

## Usage

Tweak your `Plug.Parsers` config to include `Minne`

### S3

Requires `ExAws.S3` and its dependencies.

Uploads each file directly to S3-compatible storage without writing it to the
server's local disk. Multipart parts are uploaded through a bounded asynchronous
window; when the window is full, request parsing waits for S3 and applies
backpressure instead of buffering the rest of the file.

```elixir
max_file_size = 100 * 1_024 * 1_024 * 1_024

plug Plug.Parsers,
       [
         parsers: [
           {Minne,
            length: max_file_size + 1_048_576,
            adapter: Minne.Adapter.S3,
            adapter_opts: [
              max_file_size: max_file_size,
              part_size: 16 * 1_024 * 1_024,
              max_parts: 10_000,
              max_in_flight_parts: 4,
              part_timeout: 300_000,
              complete_timeout: 300_000,
              abort_timeout: 30_000,
              bucket_function: &MyModule.fetch_upload_bucket_name/1,
              path_function: &MyModule.gen_upload_path/1
            ]}
         ],
         pass: ["*/*"],
         json_decoder: Phoenix.json_library()
       ]
```

The S3 adapter options are:

- `max_file_size` — required positive byte limit for one file.
- `part_size` — multipart part bytes; defaults to 5 MiB and must be between
  5 MiB and 5 GiB.
- `max_parts` — maximum parts accepted before aborting; defaults to 10,000 and
  cannot exceed 10,000.
- `max_in_flight_parts` — bounded concurrent part uploads; defaults to 4.
- `part_timeout` — deadline for each S3 part operation in milliseconds;
  defaults to five minutes and is enforced independently of inbound request
  progress.
- `complete_timeout` — multipart completion deadline in milliseconds; defaults
  to five minutes.
- `abort_timeout` — best-effort multipart abort deadline in milliseconds;
  defaults to 30 seconds. An abort failure or timeout does not replace the
  original upload failure.
- `bucket_function` and `path_function` — required one-argument functions that
  select the S3 bucket and `{object_key, private?}` respectively.

Initialization rejects configurations where `max_file_size` cannot fit within
`part_size * max_parts`. For example, a 100 GiB limit needs parts larger than
10.24 MiB to remain below 10,000 parts; 16 MiB allows at most 6,400 parts.
Memory used by active part uploads is bounded primarily by
`part_size * max_in_flight_parts` per request, plus parser and HTTP-client
overhead. Choose both values with expected concurrent requests and S3 connection
limits in mind.

At the end of each multipart form file, Minne uploads its final short part and
drains that file's in-flight window. The S3 multipart upload remains incomplete
until every request field passes terminal validation. This bounds concurrency
across multi-file requests without publishing an object that a later invalid
field should reject.

### Temp

This behaves almost identically to the built in `Plug.Upload`, and writes the files to temp.

```elixir
plug(Plug.Parsers,
  parsers: [
    {
      Minne,
      adapter: Minne.Adapter.Temp
    },
    :urlencoded,
    :json
  ],
  json_decoder: Jason
)
```

### From the Controller

The built-in `Plug.Parsers.MULTIPART` represents files parsed from the body as a `Plug.Upload` struct.
Minne does similar, but is instead a `Minne.Upload`, it is not a drop in replacment for `Plug.Upload`, but would not be hard to adapt code to use it.
