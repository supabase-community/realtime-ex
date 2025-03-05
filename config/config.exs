import Config

if config_env() == :dev do
  config :supabase_realtime, Support.Client,
    base_url: System.fetch_env!("SUPABASE_URL"),
    api_key: System.fetch_env!("SUPABASE_KEY"),
    env: config_env()
end
