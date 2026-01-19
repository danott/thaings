# frozen_string_literal: true

require_relative '../thaings'

# Wire dependencies at the edge
root = Pathname(__FILE__).dirname.parent.expand_path
config = ThaingsConfig.new(root: root)
LoadsEnv.new(config.env_file).call

store = QueueStore.new(config: config)
log = Log.new(config.daemon_log)
things = UpdatesThings.new

RespondsToThingsToDo.new(
  store: store,
  log: log,
  things: things,
  instructions_file: config.instructions_file
).call
