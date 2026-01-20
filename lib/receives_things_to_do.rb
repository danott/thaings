# frozen_string_literal: true

require_relative "thaings"

# Wire dependencies at the edge
config = ThaingsConfig.from_env
store = QueueStore.new(config: config)
log = Log.new(config.receive_log)

begin
  raw = $stdin.read.strip
  ReceivesThingsToDo.new(ThingsInput.new(raw), store: store, log: log).call
rescue => e
  $stderr.puts "#{e.class}: #{e.message}"
  exit 1
end
