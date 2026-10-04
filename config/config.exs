import Config

if config_env() == :test do
  config :logger, level: :warning

  config :ash,
    validate_domain_resource_inclusion?: false,
    validate_domain_config_inclusion?: false,
    disable_async?: true,
    default_string_length_count: :codepoints

  config :ash_rpc, ash_domains: [AshRpc.Test.Domain]

  config :ash_rpc, AshRpc.Test.Endpoint,
    pubsub_server: AshRpc.Test.PubSub,
    secret_key_base: String.duplicate("a", 64),
    server: false
end
