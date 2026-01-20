# frozen_string_literal: true

require_relative "thaings"

# Wire dependencies at the edge
config = ThaingsConfig.from_env

store = QueueStore.new(config: config)
log = Log.new(config.daemon_log)
things = UpdatesThings.new(config: config)

RespondsToThingsToDo.new(
  store: store,
  log: log,
  things: things,
  instructions_file: config.instructions_file
).call
