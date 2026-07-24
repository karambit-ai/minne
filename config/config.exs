import Config

if config_env() == :test do
  config :minne, :s3_client, Minne.TestS3Client
end
