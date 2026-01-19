# frozen_string_literal: true

require_relative '../thaings'

# Wire dependencies at the edge
config = ThaingsConfig.new
store = QueueStore.new(config: config)
log = Log.new(config.receive_log)

begin
  raw = $stdin.read.force_encoding('UTF-8').strip
  ReceivesThingsToDo.new(ThingsInput.new(raw), store: store, log: log).call
rescue ThingsInput::InvalidInput => e
  $stderr.puts e.message
  exit 1
end
