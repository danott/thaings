# frozen_string_literal: true

require "time"
require "json"
require "fileutils"
require "logger"
require "pathname"
require "open3"
require "timeout"
require "uri"

# Encapsulates all thaings paths in one place
#
# Directory structure:
#   to-dos/
#     _queue/            # marker files - presence = has work
#       {id}
#     {id}/
#       messages/
#         {timestamp}.json
#       processed        # timestamp of last processed message
#   log/
#
class ThaingsConfig
  attr_reader :root

  def initialize(root: Pathname(__FILE__).dirname.parent.expand_path)
    @root = Pathname(root)
  end

  def to_dos_dir = root / "to-dos"
  def queue_dir = to_dos_dir / "_queue"
  def log_dir = root / "log"
  def daemon_log = log_dir / "daemon.log"
  def receive_log = log_dir / "receive.log"
  def env_file = root / ".env"
  def instructions_file = root / "to-do-instructions.txt"
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

    path
      .readlines
      .map(&:strip)
      .reject { |line| line.empty? || line.start_with?("#") }
      .map { |line| line.split("=", 2) }
      .select { |parts| parts.length == 2 }
      .each { |key, value| ENV[key] = value }
  end
end

# Append-only log writer
#
class Log
  attr_reader :logger

  def initialize(path)
    FileUtils.mkdir_p(File.dirname(path))
    @logger = Logger.new(path)
    logger.formatter = proc { |_, time, _, msg| "#{time.utc.iso8601} #{msg}\n" }
  end

  def write(tag, message)
    logger.info { "[#{tag}] #{message}" }
  end
end

# Null object for Log
#
class NullLog
  def write(_tag, _message) = nil
end

# File-based exclusive lock with block form
#
class Lock
  attr_reader :path

  def initialize(path)
    @path = path
  end

  def with_lock
    FileUtils.mkdir_p(File.dirname(path))
    file = File.open(path, File::RDWR | File::CREAT)
    return false unless file.flock(File::LOCK_EX | File::LOCK_NB)

    begin
      yield
    ensure
      file.flock(File::LOCK_UN)
      file.close
    end
    true
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

  def title = data["Title"]
  def notes = data["Notes"] || ""
  def checklist = data["Checklist Items"]

  def tags
    tags_str = data["Tags"] || ""
    tags_str.split(",").map(&:strip).reject(&:empty?)
  end
end

# The to-do state (immutable value object)
#
# Represents the complete desired state - content and workflow tag.
# Transforms return new instances. Broadcast the final state to Things.
#
class ToDo
  WORKFLOW_TAGS = %w[Working Ready].freeze

  attr_reader :title, :notes, :tags, :checklist, :workflow_tag

  def initialize(title:, notes:, tags:, checklist:, workflow_tag: nil)
    @title = title
    @notes = notes
    @tags = tags.freeze
    @checklist = checklist
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
    with(workflow_tag: "Working")
  end

  def with_response(text)
    with(
      notes: [notes.strip, "---", text.strip, "***", ""].join("\n\n"),
      workflow_tag: "Ready"
    )
  end

  # --- Computed state ---

  def prompt
    parts = []
    parts << title if title
    parts << "\n\n#{notes}" unless notes.empty?
    if checklist.is_a?(String) && !checklist.empty?
      parts << "\n\nChecklist:\n#{checklist}"
    end
    parts.join
  end

  def final_tags
    non_workflow_tags + [workflow_tag].compact
  end

  private

  def with(notes: nil, workflow_tag: nil)
    ToDo.new(
      title: title,
      notes: notes || self.notes,
      tags: tags,
      checklist: checklist,
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
  attr_reader :id, :dir, :messages

  def initialize(id:, dir:, messages: [])
    @id = id
    @dir = dir
    @messages = messages.freeze
  end

  def latest_message
    messages.last
  end

  # Paths (no I/O, just path construction)
  def messages_dir = dir / "messages"
  def processed_file = dir / "processed"
end

# Manages queues on disk with markers for fast lookup
#
# All filesystem I/O happens here. Queue objects are immutable snapshots.
#
# Storage:
#   to-dos/_queue/{id}              - marker file (presence = has work)
#   to-dos/{id}/messages/{ts}.json  - individual messages
#   to-dos/{id}/processed           - timestamp of last processed
#
class QueueStore
  attr_reader :config

  def initialize(config:)
    @config = config
  end

  # Find queued IDs - O(k) where k = queue size
  def queued_ids
    return [] unless config.queue_dir.exist?

    config.queue_dir.glob("*").map { |p| p.basename.to_s }
  end

  # Load a queue snapshot by ID
  def find(id)
    validate_id!(id)
    dir = config.to_dos_dir / id
    return nil unless dir.exist?

    load_queue(id, dir)
  end

  # Write a new message and add to queue
  def write_message(id, data, at: Time.now.utc)
    validate_id!(id)

    dir = config.to_dos_dir / id
    messages_dir = dir / "messages"
    messages_dir.mkpath

    timestamp = format_timestamp(at)
    file = messages_dir / "#{timestamp}.json"
    file.write(JSON.pretty_generate(data))

    enqueue(id)

    load_queue(id, dir)
  end

  # Mark a specific message as processed
  # Only dequeues if no newer messages arrived during processing
  def mark_processed(queue, timestamp)
    queue.processed_file.write(timestamp)

    # Read current state from disk to check if we're caught up
    current_latest = read_latest_message_at(queue.id)
    dequeue(queue.id) unless current_latest && current_latest > timestamp
  end

  private

  def validate_id!(id)
    return if id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]+\z/)

    raise ArgumentError, "Invalid to-do ID: #{id.inspect}"
  end

  def load_queue(id, dir)
    Queue.new(id: id, dir: dir, messages: load_messages(dir / "messages"))
  end

  def load_messages(messages_dir)
    return [] unless messages_dir.exist?

    messages_dir
      .glob("*.json")
      .sort_by(&:basename)
      .map do |file|
        data = JSON.parse(file.read)
        Message.new(received_at: file.basename(".json").to_s, data: data)
      end
  end

  def read_latest_message_at(id)
    dir = config.to_dos_dir / id
    messages_dir = dir / "messages"
    return nil unless messages_dir.exist?

    files = messages_dir.glob("*.json").sort_by(&:basename)
    files.last&.basename(".json")&.to_s
  end

  def enqueue(id)
    config.queue_dir.mkpath
    FileUtils.touch(config.queue_dir / id)
  end

  def dequeue(id)
    marker = config.queue_dir / id
    marker.delete if marker.exist?
  end

  def format_timestamp(time)
    time.utc.strftime("%Y-%m-%dT%H-%M-%S-%6NZ")
  end
end

# Parses and validates input from Things
#
class ThingsInput
  class InvalidInput < StandardError
  end

  def initialize(raw_input)
    @data = JSON.parse(raw_input)
  rescue JSON::ParserError => e
    raise InvalidInput, "Invalid JSON: #{e.message}"
  end

  def id
    value = @data["ID"]
    raise InvalidInput, "Missing ID field" if value.nil? || value.empty?

    value
  end

  def validate_has_content!
    title = @data["Title"].to_s.strip
    return unless title.empty?

    raise InvalidInput, "To-do is missing a title"
  end

  def data = @data
  def title = @data["Title"] || "(no title)"
  def to_do? = @data["Type"] == "To-Do"
end

# Receives a Things to-do, writes message file, adds to queue
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

    input.validate_has_content!
    store.write_message(input.id, input.data)
    log.write(input.id, "received: #{input.title}")
  end
end

# Asks Claude to respond to a prompt
#
class AsksClaude
  ALLOWED_TOOLS = %w[WebSearch WebFetch].freeze
  MAX_TURNS = 10
  TIMEOUT_SECONDS = 300

  attr_reader :dir, :instructions_file

  def initialize(dir:, instructions_file:)
    @dir = dir
    @instructions_file = instructions_file
  end

  def call(prompt)
    stdout, stderr, status = run(prompt)

    status.success? ? stdout : "Error: Claude execution failed.\n#{stderr}"
  rescue Timeout::Error
    "Error: Claude timed out after #{TIMEOUT_SECONDS} seconds."
  end

  private

  def run(prompt)
    Timeout.timeout(TIMEOUT_SECONDS) do
      stdout, stderr, status =
        Open3.capture3(
          "/opt/homebrew/bin/claude",
          "--continue",
          "--print",
          "--max-turns",
          MAX_TURNS.to_s,
          "--append-system-prompt-file",
          instructions_file.to_s,
          "--allowedTools",
          ALLOWED_TOOLS.join(","),
          "-p",
          prompt,
          chdir: dir.to_s
        )
      [stdout, stderr, status]
    end
  end
end

# Broadcasts to-do state to Things app via URL scheme
#
# Declarative: takes a ToDo and broadcasts its current state.
# The ToDo knows what it should look like; this just sends it.
#
class UpdatesThings
  class UpdateFailed < StandardError
  end

  def update(id, to_do)
    open_url(
      id,
      { "notes" => to_do.notes, "tags" => to_do.final_tags.join(",") }
    )
  end

  private

  def open_url(id, params)
    query =
      params
        .merge("id" => id, "auth-token" => auth_token)
        .map do |k, v|
          "#{k}=#{URI.encode_www_form_component(v).gsub("+", "%20")}"
        end
        .join("&")

    url = "things:///update?#{query}"
    return if system("open", "-g", url)

    raise UpdateFailed, "Failed to open Things URL: #{url[0, 50]}..."
  end

  def auth_token
    ENV.fetch("THINGS_AUTH_TOKEN") do
      raise "Missing THINGS_AUTH_TOKEN in ~/.thaings/.env"
    end
  end
end

# Processes a single queue through Claude
#
# Simple flow: compute state, broadcast state.
#
class ProcessesQueue
  attr_reader :queue, :store, :things, :log, :claude

  def initialize(queue, store:, things:, log:, claude:)
    @queue = queue
    @store = store
    @things = things
    @log = log
    @claude = claude
  end

  def call
    Lock.new(queue.dir / ".lock").with_lock { process }
  end

  private

  def process
    message = queue.latest_message
    unless message
      log.write(queue.id, "no messages - skipping")
      return
    end

    to_do = ToDo.from_message(message)
    log.write(queue.id, "processing #{message.received_at}")

    things.update(queue.id, to_do.marked_working)

    log.write(queue.id, "prompt: #{to_do.prompt.lines.first&.strip}")
    response = claude.call(to_do.prompt)

    completed = to_do.with_response(response)
    things.update(queue.id, completed)

    store.mark_processed(queue, message.received_at)
    log.write(queue.id, "done")
  end
end

# Entry point: wakes, finds queued to-dos, processes them
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
    log.write("daemon", "triggered")

    ids = store.queued_ids

    if ids.empty?
      log.write("daemon", "queue empty")
      return
    end

    log.write("daemon", "found #{ids.length} queued")

    ids.each do |id|
      queue = store.find(id)
      next unless queue

      claude =
        AsksClaude.new(dir: queue.dir, instructions_file: instructions_file)
      ProcessesQueue.new(
        queue,
        store: store,
        things: things,
        log: log,
        claude: claude
      ).call
    end

    log.write("daemon", "finished")
  end
end
