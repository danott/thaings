# frozen_string_literal: true

require "time"
require "json"
require "fileutils"
require "logger"
require "pathname"
require "open3"
require "timeout"
require "uri"

class ClaudeConfig
  DEFAULT_SYSTEM_PROMPT_FILE = "default-system-prompt.md"
  DEFAULT_MAX_TURNS = 10
  DEFAULT_TIMEOUT_SECONDS = 300
  DEFAULT_ALLOWED_TOOLS = "WebSearch,WebFetch"
  DEFAULT_PATH = "/opt/homebrew/bin/claude"

  attr_reader :system_prompt_file,
              :max_turns,
              :timeout_seconds,
              :allowed_tools,
              :path

  def self.from_env(root:)
    default_system_prompt_file = (root / DEFAULT_SYSTEM_PROMPT_FILE).to_s

    new(
      system_prompt_file:
        ENV.fetch("THAINGS_SYSTEM_PROMPT_FILE", default_system_prompt_file),
      max_turns: ENV.fetch("THAINGS_MAX_TURNS", DEFAULT_MAX_TURNS).to_i,
      timeout_seconds:
        ENV.fetch("THAINGS_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS).to_i,
      allowed_tools: ENV.fetch("THAINGS_ALLOWED_TOOLS", DEFAULT_ALLOWED_TOOLS),
      path: ENV.fetch("THAINGS_CLAUDE_PATH", DEFAULT_PATH)
    )
  end

  def initialize(
    system_prompt_file:,
    max_turns: DEFAULT_MAX_TURNS,
    timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
    allowed_tools: DEFAULT_ALLOWED_TOOLS,
    path: DEFAULT_PATH
  )
    @system_prompt_file = Pathname(system_prompt_file).expand_path
    @max_turns = max_turns
    @timeout_seconds = timeout_seconds
    @allowed_tools = allowed_tools
    @path = path
  end
end

class ThaingsConfig
  attr_reader :root, :things_auth_token, :claude_config

  def self.from_env
    root = Pathname(__FILE__).dirname.parent.expand_path
    env_file = root / ".env"
    LoadsEnv.new(env_file).call

    things_auth_token =
      ENV.fetch("THAINGS_THINGS_AUTH_TOKEN") do
        raise "Missing THAINGS_THINGS_AUTH_TOKEN in #{env_file}"
      end

    new(
      root: root,
      things_auth_token: things_auth_token,
      claude_config: ClaudeConfig.from_env(root: root)
    )
  end

  def initialize(root:, things_auth_token:, claude_config:)
    @root = Pathname(root)
    @things_auth_token = things_auth_token
    @claude_config = claude_config
  end

  def to_dos_dir = root / "to-dos"
  def queue_dir = to_dos_dir / "_queue"
  def log_dir = root / "log"
  def daemon_log = log_dir / "daemon.log"
  def receive_log = log_dir / "receive.log"
  def env_file = root / ".env"
end

# Loads environment variables from a file
#
# Handles standard .env conventions:
#   - Comments (lines starting with #)
#   - export prefix (export FOO=bar)
#   - Quoted values (FOO="bar" or FOO='bar')
#   - Inline comments (FOO=bar # comment) - only outside quotes
#   - Values containing equals signs (FOO=a=b=c)
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
      .each { |line| parse_and_set(line) }
  end

  private

  def parse_and_set(line)
    # Handle export prefix
    line = line.sub(/\Aexport\s+/, "")

    # Split on first =
    key, value = line.split("=", 2)
    return unless key && value

    key = key.strip
    return if key.empty?

    ENV[key] = parse_value(value)
  end

  def parse_value(value)
    value = value.strip

    # Handle double-quoted values
    return extract_quoted(value, '"') if value.start_with?('"')

    # Handle single-quoted values
    return extract_quoted(value, "'") if value.start_with?("'")

    # Unquoted: strip inline comments
    value.sub(/\s+#.*\z/, "")
  end

  def extract_quoted(value, quote)
    # Find the closing quote
    end_index = value.index(quote, 1)
    return value unless end_index

    value[1...end_index]
  end
end

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

  def title = data.fetch("Title")
  def notes = data.fetch("Notes", "")
  def checklist = data.fetch("Checklist Items", nil)

  def tags
    tags_str = data.fetch("Tags", "")
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

  def marked_working
    with(workflow_tag: "Working")
  end

  def with_response(text)
    with(
      notes: [notes.strip, "---", text.strip, "***", ""].join("\n\n"),
      workflow_tag: "Ready"
    )
  end

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

  def queued_ids
    return [] unless config.queue_dir.exist?

    config.queue_dir.glob("*").map { |p| p.basename.to_s }
  end

  def find(id)
    validate_id!(id)
    dir = config.to_dos_dir / id
    return nil unless dir.exist?

    load_queue(id, dir)
  end

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

class ThingsInput
  class InvalidInput < StandardError
  end

  def initialize(raw_input)
    @data = JSON.parse(raw_input)
  rescue JSON::ParserError => e
    raise InvalidInput, "Invalid JSON: #{e.message}"
  end

  attr_reader :data

  def id
    value = data.fetch("ID", nil)
    raise InvalidInput, "Missing ID field" if value.nil? || value.empty?

    value
  end

  def validate_has_content!
    title_value = data.fetch("Title", "").to_s.strip
    return unless title_value.empty?

    raise InvalidInput, "To-do is missing a title"
  end

  def title = data.fetch("Title", "(no title)")
  def to_do? = data.fetch("Type", nil) == "To-Do"
end

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

class AsksClaude
  attr_reader :dir, :config

  def initialize(dir:, config:)
    @dir = dir
    @config = config
  end

  def call(prompt)
    stdout, stderr, status = run(prompt)

    status.success? ? stdout : "Error: Claude execution failed.\n#{stderr}"
  rescue Timeout::Error
    "Error: Claude timed out after #{config.timeout_seconds} seconds."
  end

  private

  def run(prompt)
    Timeout.timeout(config.timeout_seconds) do
      stdout, stderr, status =
        Open3.capture3(
          config.path,
          "--continue",
          "--max-turns",
          config.max_turns.to_s,
          "--append-system-prompt-file",
          config.system_prompt_file.to_s,
          "--allowedTools",
          config.allowed_tools,
          "--print",
          prompt,
          chdir: dir.to_s
        )
      [stdout, stderr, status]
    end
  end
end

# Declarative: takes a ToDo and broadcasts its current state.
# The ToDo knows what it should look like; this just sends it.
class UpdatesThings
  class UpdateFailed < StandardError
  end

  attr_reader :config

  def initialize(config:)
    @config = config
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
        .merge("id" => id, "auth-token" => config.things_auth_token)
        .map do |k, v|
          "#{k}=#{URI.encode_www_form_component(v).gsub("+", "%20")}"
        end
        .join("&")

    url = "things:///update?#{query}"
    return if system("open", "-g", url)

    raise UpdateFailed, "Failed to open Things URL: #{url[0, 50]}..."
  end
end

# Simple flow: compute state, broadcast state.
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
    locked = Lock.new(queue.dir / ".lock").with_lock { process }
    log.write(queue.id, "SKIPPED: lock held by another process") unless locked
    locked
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

class RespondsToThingsToDo
  attr_reader :store, :log, :things, :claude_config

  def initialize(store:, log:, things:, claude_config:)
    @store = store
    @log = log
    @things = things
    @claude_config = claude_config
  end

  def call
    log.write("daemon", "triggered")

    ids = store.queued_ids

    if ids.empty?
      log.write("daemon", "queue empty")
      return
    end

    log.write("daemon", "found #{ids.length} queued")

    failed = []

    ids.each do |id|
      queue = store.find(id)
      next unless queue

      claude = AsksClaude.new(dir: queue.dir, config: claude_config)

      begin
        ProcessesQueue.new(
          queue,
          store: store,
          things: things,
          log: log,
          claude: claude
        ).call
      rescue => e
        log.write(id, "UNEXPECTED ERROR: #{e.class}: #{e.message}")
        log.write(id, "  #{e.backtrace.first(3).join("\n  ")}")
        failed << id
      end
    end

    if failed.any?
      log.write(
        "daemon",
        "finished with #{failed.length} FAILED: #{failed.join(", ")}"
      )
    else
      log.write("daemon", "finished")
    end
  end
end
