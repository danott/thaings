# frozen_string_literal: true

require 'time'
require 'json'
require 'fileutils'
require 'logger'
require 'pathname'
require 'open3'
require 'timeout'
require 'uri'

# Encapsulates all thaings paths in one place
#
# Directory structure:
#   ~/.thaings/
#     pending/           # marker files - presence = has work
#       {id}
#     queues/
#       {id}/
#         messages/
#           {timestamp}.json
#         processed      # timestamp of last processed message
#     log/
#
class ThaingsConfig
  attr_reader :root

  def initialize(root: Pathname(Dir.home) / '.thaings')
    @root = Pathname(root)
  end

  def pending_dir = root / 'pending'
  def queues_dir = root / 'queues'
  def log_dir = root / 'log'
  def daemon_log = log_dir / 'daemon.log'
  def receive_log = log_dir / 'receive.log'
  def env_file = root / '.env'
  def instructions_file = root / 'to-do-instructions.txt'
end

# Loads environment variables from a file
#
class LoadsEnv
  attr_reader :path

  def initialize(path)
    @path = Pathname(path)
  end

  def call
    return unless path.exist?

    parse_lines.each { |key, value| ENV[key] = value }
  end

  private

  def parse_lines
    path.readlines
      .map(&:strip)
      .reject { |line| line.empty? || line.start_with?('#') }
      .map { |line| line.split('=', 2) }
      .select { |parts| parts.length == 2 }
  end
end

# Append-only log writer backed by stdlib Logger
#
class Log
  attr_reader :logger, :path

  def initialize(path)
    @path = path
    FileUtils.mkdir_p(File.dirname(path))
    @logger = Logger.new(path)
    logger.formatter = method(:format_line)
  end

  def write(tag, message)
    logger.info { "[#{tag}] #{message}" }
  end

  private

  def format_line(_severity, time, _progname, msg)
    "#{time.utc.iso8601} #{msg}\n"
  end
end

# Null object for Log
#
class NullLog
  def write(_tag, _message) = nil
end

# File-based exclusive lock with explicit acquire/release
#
class Lock
  attr_reader :path

  def initialize(path)
    @path = path
    @file = nil
  end

  def acquire
    FileUtils.mkdir_p(File.dirname(path))
    @file = File.open(path, File::RDWR | File::CREAT)
    @file.flock(File::LOCK_EX | File::LOCK_NB)
  end

  def release
    return unless @file

    @file.flock(File::LOCK_UN)
    @file.close
    @file = nil
  end
end

# Validates a to-do ID to prevent path traversal attacks
#
class ValidatesId
  PATTERN = /\A[A-Za-z0-9_-]+\z/

  class Invalid < ArgumentError; end

  attr_reader :id

  def initialize(id)
    @id = id
  end

  def call
    raise Invalid, "Invalid to-do ID: #{id.inspect}" unless valid?
    id
  end

  private

  def valid?
    id.is_a?(String) && id.match?(PATTERN)
  end
end

# Immutable snapshot from Things
#
# What we received at a point in time.
#
class Message
  attr_reader :received_at, :data

  def initialize(received_at:, data:)
    @received_at = received_at
    @data = data.freeze
  end

  def title = data['Title']
  def notes = data['Notes'] || ''
  def checklist = data['Checklist Items']

  def tags
    tags_str = data['Tags'] || ''
    tags_str.split(',').map(&:strip).reject(&:empty?)
  end
end

# The to-do state (immutable value object)
#
# Represents the complete desired state - content, response, workflow tag.
# Transforms return new instances. Broadcast the final state to Things.
#
class ToDo
  WORKFLOW_TAGS = %w[Working Ready].freeze

  attr_reader :title, :notes, :tags, :checklist, :response, :workflow_tag

  def initialize(title:, notes:, tags:, checklist:, response: nil, workflow_tag: nil)
    @title = title
    @notes = notes
    @tags = tags.freeze
    @checklist = checklist
    @response = response
    @workflow_tag = workflow_tag
  end

  def self.from_message(message)
    new(
      title: message.title,
      notes: message.notes,
      tags: message.tags,
      checklist: message.checklist
    )
  end

  # --- Transforms (return new ToDo) ---

  def marked_working
    with(workflow_tag: 'Working')
  end

  def with_response(text)
    with(response: text, workflow_tag: 'Ready')
  end

  # --- Computed state ---

  def full_notes
    return notes unless response
    "#{notes}\n\n---\n\n#{response}\n\n***\n\n"
  end

  def final_tags
    non_workflow_tags + [workflow_tag].compact
  end

  private

  def with(response: nil, workflow_tag: nil)
    ToDo.new(
      title: title,
      notes: notes,
      tags: tags,
      checklist: checklist,
      response: response || self.response,
      workflow_tag: workflow_tag || self.workflow_tag
    )
  end

  def non_workflow_tags
    tags.reject { |t| WORKFLOW_TAGS.include?(t) }
  end
end

# Processing state for one to-do ID (immutable value object)
#
# All state captured at construction - no filesystem reads after that.
# QueueStore handles all I/O and returns Queue snapshots.
#
class Queue
  attr_reader :id, :dir, :messages, :processed_at

  def initialize(id:, dir:, messages: [], processed_at: '')
    @id = id
    @dir = dir
    @messages = messages.freeze
    @processed_at = processed_at
  end

  def processable?
    latest_message_at && latest_message_at > processed_at
  end

  def latest_message
    messages.last
  end

  def latest_message_at
    latest_message&.received_at
  end

  # Paths (no I/O, just path construction)
  def messages_dir = dir / 'messages'
  def processed_file = dir / 'processed'
  def log_file = dir / 'queue.log'
end

# Manages queues on disk with pending markers for fast lookup
#
# All filesystem I/O happens here. Queue objects are immutable snapshots.
#
# Storage:
#   pending/{id}                    - marker file (presence = has work)
#   queues/{id}/messages/{ts}.json  - individual messages
#   queues/{id}/processed           - timestamp of last processed
#
class QueueStore
  attr_reader :config

  def initialize(config:)
    @config = config
  end

  # Find pending queue IDs - O(k) where k = pending count
  def pending_ids
    return [] unless config.pending_dir.exist?

    config.pending_dir.glob('*').map { |p| p.basename.to_s }
  end

  # Load a queue snapshot by ID
  def find(id)
    ValidatesId.new(id).call
    dir = config.queues_dir / id
    return nil unless dir.exist?

    load_queue(id, dir)
  end

  # Write a new message and mark as pending
  def write_message(id, data, at: Time.now.utc)
    ValidatesId.new(id).call

    dir = config.queues_dir / id
    messages_dir = dir / 'messages'
    messages_dir.mkpath

    timestamp = format_timestamp(at)
    file = messages_dir / "#{timestamp}.json"
    file.write(JSON.pretty_generate(data), encoding: 'UTF-8')

    touch_pending(id)

    load_queue(id, dir)
  end

  # Mark a specific message as processed
  # Only clears pending if no newer messages arrived during processing
  def mark_processed(queue, timestamp)
    queue.processed_file.write(timestamp)

    # Read current state from disk to check if we're caught up
    current_latest = read_latest_message_at(queue.id)
    clear_pending(queue.id) unless current_latest && current_latest > timestamp
  end

  private

  def load_queue(id, dir)
    Queue.new(
      id: id,
      dir: dir,
      messages: load_messages(dir / 'messages'),
      processed_at: load_processed_at(dir / 'processed')
    )
  end

  def load_messages(messages_dir)
    return [] unless messages_dir.exist?

    messages_dir.glob('*.json').sort_by(&:basename).map do |file|
      data = JSON.parse(file.read(encoding: 'UTF-8'))
      Message.new(received_at: file.basename('.json').to_s, data: data)
    end
  end

  def load_processed_at(processed_file)
    processed_file.exist? ? processed_file.read.strip : ''
  end

  def read_latest_message_at(id)
    dir = config.queues_dir / id
    messages_dir = dir / 'messages'
    return nil unless messages_dir.exist?

    files = messages_dir.glob('*.json').sort_by(&:basename)
    files.last&.basename('.json')&.to_s
  end

  def touch_pending(id)
    config.pending_dir.mkpath
    FileUtils.touch(config.pending_dir / id)
  end

  def clear_pending(id)
    marker = config.pending_dir / id
    marker.delete if marker.exist?
  end

  def format_timestamp(time)
    time.utc.strftime('%Y-%m-%dT%H-%M-%S-%6NZ')
  end
end

# Parses and validates input from Things
#
class ThingsInput
  class InvalidInput < StandardError; end

  attr_reader :raw_input

  def initialize(raw_input)
    @raw_input = raw_input
  end

  def data
    @data ||= parse_json
  end

  def id
    value = data['ID']
    raise InvalidInput, 'Missing ID field' if value.nil? || value.empty?

    value
  end

  def title
    data['Title'] || '(no title)'
  end

  def to_do?
    data['Type'] == 'To-Do'
  end

  private

  def parse_json
    JSON.parse(raw_input)
  rescue JSON::ParserError => e
    raise InvalidInput, "Invalid JSON: #{e.message}"
  end
end

# Receives a Things to-do, writes message file, marks pending
#
class ReceivesThingsToDo
  attr_reader :input, :store, :log

  def initialize(input, store:, log:)
    @input = input
    @store = store
    @log = log
  end

  def call
    return unless input.to_do?

    queue = store.write_message(input.id, input.data)

    log.write('receive', "#{input.id} - #{input.title}")
    Log.new(queue.log_file).write('receive', 'Message received from Things')
  end
end

# Builds a prompt from to-do properties
#
class BuildsPrompt
  attr_reader :to_do

  def initialize(to_do)
    @to_do = to_do
  end

  def call
    parts = []
    parts << to_do.title if to_do.title
    parts << "\n\n#{to_do.notes}" unless to_do.notes.empty?
    parts << "\n\nChecklist:\n#{to_do.checklist}" if checklist_present?
    parts.join
  end

  private

  def checklist_present?
    to_do.checklist.is_a?(String) && !to_do.checklist.empty?
  end
end

# Asks Claude to respond to a prompt
#
class AsksClaude
  ALLOWED_TOOLS = %w[WebSearch WebFetch].freeze
  MAX_TURNS = 10
  TIMEOUT_SECONDS = 300

  attr_reader :queue_dir, :instructions_file

  def initialize(queue_dir, instructions_file:)
    @queue_dir = queue_dir
    @instructions_file = instructions_file
  end

  def call(prompt)
    stdout, stderr, process = run(prompt)

    if process.success?
      stdout
    else
      "Error: Claude execution failed.\n#{stderr}"
    end
  rescue Timeout::Error
    "Error: Claude timed out after #{TIMEOUT_SECONDS} seconds."
  end

  private

  def run(prompt)
    Timeout.timeout(TIMEOUT_SECONDS) do
      stdout, stderr, status = Open3.capture3(
        '/opt/homebrew/bin/claude',
        '--continue',
        '--print',
        '--max-turns', MAX_TURNS.to_s,
        '--append-system-prompt-file', instructions_file.to_s,
        '--allowedTools', ALLOWED_TOOLS.join(','),
        '-p', prompt,
        chdir: queue_dir.to_s
      )
      [stdout.force_encoding('UTF-8'), stderr.force_encoding('UTF-8'), status]
    end
  end
end

# Broadcasts to-do state to Things app via URL scheme
#
# Declarative: takes a ToDo and broadcasts its current state.
# The ToDo knows what it should look like; this just sends it.
#
class UpdatesThings
  class UpdateFailed < StandardError; end

  def update(id, to_do)
    params = {}
    params['notes'] = to_do.full_notes if to_do.response
    params['tags'] = to_do.final_tags.join(',') if to_do.workflow_tag

    open_url(id, params) unless params.empty?
  end

  private

  def open_url(id, params)
    query = params.merge('id' => id, 'auth-token' => auth_token)
      .map { |k, v| "#{k}=#{URI.encode_www_form_component(v).gsub('+', '%20')}" }
      .join('&')

    url = "things:///update?#{query}"
    return if system('open', '-g', url)

    raise UpdateFailed, "Failed to open Things URL: #{url[0, 50]}..."
  end

  def auth_token
    ENV.fetch('THINGS_AUTH_TOKEN') { raise 'Missing THINGS_AUTH_TOKEN in ~/.thaings/.env' }
  end
end

# Processes a single queue through Claude
#
# Simple flow: compute state, broadcast state.
# No pipeline, no steps - just clear, linear code.
#
class ProcessesQueue
  attr_reader :queue, :store, :things, :daemon_log, :instructions_file

  def initialize(queue, store:, things:, daemon_log:, instructions_file:)
    @queue = queue
    @store = store
    @things = things
    @daemon_log = daemon_log
    @instructions_file = instructions_file
  end

  def call
    lock = Lock.new(queue.dir / '.lock')

    unless lock.acquire
      daemon_log.write('skip', "#{queue.id} - already locked")
      return
    end

    begin
      process
    ensure
      lock.release
    end
  end

  private

  def process
    message = queue.latest_message
    unless message
      daemon_log.write('skip', "#{queue.id} - no messages")
      return
    end

    to_do = ToDo.from_message(message)
    daemon_log.write('start', "#{queue.id} - processing #{message.received_at}")
    queue_log.write('daemon', "Started processing message #{message.received_at}")

    # Broadcast "working" state
    things.update(queue.id, to_do.marked_working)

    # Ask Claude
    prompt = BuildsPrompt.new(to_do).call
    response = if prompt.strip.empty?
                 queue_log.write('daemon', 'Skipped: no content to process')
                 'Nothing to process - add a title or notes and try again.'
               else
                 queue_log.write('daemon', "Prompt: #{prompt.lines.first&.strip}")
                 AsksClaude.new(queue.dir, instructions_file: instructions_file).call(prompt)
               end

    # Compute final state and broadcast
    completed = to_do.with_response(response)
    things.update(queue.id, completed)

    # Mark processed (clears pending if caught up)
    store.mark_processed(queue, message.received_at)

    queue_log.write('daemon', 'Completed')
    daemon_log.write('done', queue.id)
  end

  def queue_log
    @queue_log ||= Log.new(queue.log_file)
  end
end

# Entry point: wakes, finds pending queues, processes them
#
class RespondsToThingsToDo
  attr_reader :store, :log, :things, :instructions_file

  def initialize(store:, log:, things:, instructions_file:)
    @store = store
    @log = log
    @things = things
    @instructions_file = instructions_file
  end

  def call
    log.write('wake', 'Daemon triggered')

    ids = store.pending_ids

    if ids.empty?
      log.write('idle', 'No pending queues')
      return
    end

    log.write('found', "#{ids.length} pending queue(s)")

    ids.each do |id|
      queue = store.find(id)
      next unless queue

      ProcessesQueue.new(
        queue,
        store: store,
        things: things,
        daemon_log: log,
        instructions_file: instructions_file
      ).call
    end

    log.write('exit', 'Daemon finished')
  end
end
