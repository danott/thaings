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
# Usage:
#   config = ThaingsConfig.new  # uses ~/.thaings
#   config = ThaingsConfig.new(root: '/tmp/test')  # for testing
#
#   config.to_dos_dir    # => Pathname
#   config.log_dir       # => Pathname
#   config.daemon_log    # => Pathname
#
class ThaingsConfig
  attr_reader :root

  def initialize(root: Pathname(Dir.home) / '.thaings')
    @root = Pathname(root)
  end

  def to_dos_dir = root / 'to-dos'
  def log_dir = root / 'log'
  def daemon_log = log_dir / 'daemon.log'
  def receive_log = log_dir / 'receive.log'
  def env_file = root / '.env'
  def instructions_file = root / 'to-do-instructions.txt'
end

# Loads environment variables from a file
#
# Usage:
#   LoadsEnv.new(config.env_file).call
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

# Default config instance
THAINGS_CONFIG = ThaingsConfig.new

# Append-only log writer backed by stdlib Logger
#
# Usage:
#   log = Log.new('path/to/file.log')
#   log.write('tag', 'message')
#   # => "2024-01-17T12:00:00Z [tag] message\n"
#
# Benefits over raw File.write:
#   - Thread-safe writes
#   - Automatic file handle management
#
class Log
  attr_reader :logger
  attr_reader :path

  def initialize(path)
    @path = path
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

# Null object for Log - useful for testing or when you don't want output
#
class NullLog
  def write(_tag, _message) = nil
end

# File-based exclusive lock with explicit acquire/release
#
# Usage:
#   lock = Lock.new('/path/to/.lock')
#   if lock.acquire
#     begin
#       do_work
#     ensure
#       lock.release
#     end
#   else
#     puts "Already locked"
#   end
#
class Lock
  attr_reader :path

  def initialize(path)
    @path = path
    @file = nil
  end

  def acquire
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

# A to-do (immutable value object)
#
# Minimal state: just messages and how many we've processed.
# Status is derived: processable when messages.length > messages_processed.
#
# "Working" state is ephemeral (only in memory during pipeline execution).
# This avoids stuck to-dos if the daemon crashes mid-processing.
#
class ToDo
  attr_reader :id, :dir, :messages_processed, :messages

  def initialize(id:, dir:, messages_processed: 0, messages: [])
    @id = id
    @dir = dir
    @messages_processed = messages_processed
    @messages = messages.freeze
  end

  # --- Transitions (return new ToDo) ---

  def with_message(data, at: Time.now.utc.iso8601)
    new_message = { 'received_at' => at, 'data' => data }
    ToDo.new(
      id: id, dir: dir,
      messages_processed: messages_processed,
      messages: messages + [new_message]
    )
  end

  def marked_processed
    ToDo.new(
      id: id, dir: dir,
      messages_processed: messages.length,
      messages: messages
    )
  end

  # --- Queries ---

  def processable?
    messages.length > messages_processed
  end

  def latest_message
    messages.last&.dig('data') || {}
  end

  def first_received_at
    messages.first&.dig('received_at')
  end

  def title
    latest_message['Title']
  end

  def notes
    latest_message['Notes'] || ''
  end

  def checklist
    latest_message['Checklist Items']
  end

  def tags
    tags_str = latest_message['Tags'] || ''
    tags_str.split(',').map(&:strip).reject(&:empty?)
  end

  # --- Paths ---

  def to_do_file = dir / 'to-do.json'
  def log_file = dir / 'to-do.log'
end

# Reads and writes to-dos to disk
#
# JSON format:
#   { "messages_processed": 1, "messages": [...] }
#
# Usage:
#   store = ToDoStore.new
#   to_do = store.find_or_create('abc123')
#   to_do = to_do.with_message(data)
#   store.save(to_do)
#
class ToDoStore
  attr_reader :root_dir

  def initialize(root_dir: THAINGS_CONFIG.to_dos_dir)
    @root_dir = root_dir
  end

  def find(id)
    ValidatesId.new(id).call
    dir = root_dir / id
    path = dir / 'to-do.json'
    return nil unless path.exist?

    data = JSON.parse(path.read(encoding: 'UTF-8'))
    from_hash(id, dir, data)
  end

  def find_or_create(id)
    find(id) || create(id)
  end

  def create(id)
    ValidatesId.new(id).call
    dir = root_dir / id
    dir.mkpath

    ToDo.new(id: id, dir: dir)
  end

  def all_ids
    return [] unless root_dir.exist?

    root_dir.glob('*/to-do.json').map do |path|
      path.dirname.basename.to_s
    end
  end

  def save(to_do)
    json = JSON.pretty_generate(to_hash(to_do))
    File.write(to_do.to_do_file, json, encoding: 'UTF-8')
  end

  private

  def from_hash(id, dir, data)
    ToDo.new(
      id: id,
      dir: dir,
      messages_processed: data['messages_processed'] || 0,
      messages: data['messages'] || []
    )
  end

  def to_hash(to_do)
    {
      'messages_processed' => to_do.messages_processed,
      'messages' => to_do.messages
    }
  end
end

# Immutable context that flows through a processing pipeline
#
# Carries the to-do plus any intermediate results (like Claude's response).
# Each step can return a new context with updated values.
#
# Usage:
#   ctx = ProcessingContext.new(to_do: to_do)
#   ctx = ctx.with(response: "Hello from Claude")
#   ctx.response  # => "Hello from Claude"
#
class ProcessingContext
  attr_reader :to_do, :response

  def initialize(to_do:, response: nil)
    @to_do = to_do
    @response = response
  end

  def with(to_do: nil, response: nil)
    ProcessingContext.new(
      to_do: to_do || self.to_do,
      response: response || self.response
    )
  end
end

# Runs a series of steps, threading a context through each
#
# Each step must respond to #call(context) and return a context.
# Steps are simple objects - easy to test in isolation.
#
# Usage:
#   pipeline = Pipeline.new([StepA.new, StepB.new])
#   result = pipeline.call(initial_context)
#
class Pipeline
  attr_reader :steps

  def initialize(steps)
    @steps = steps
  end

  def call(context)
    steps.reduce(context) { |ctx, step| step.call(ctx) }
  end
end

# Parses and validates input from Things
#
# Raises on invalid input instead of calling exit.
# Let the caller decide how to handle errors.
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

# Receives a Things to-do via stdin JSON, creates/updates to-do state
#
class ReceivesThingsToDo
  attr_reader :input, :store, :log

  def initialize(input, store: ToDoStore.new, log: Log.new(THAINGS_CONFIG.receive_log))
    @input = input
    @store = store
    @log = log
  end

  def call
    return unless input.to_do?

    to_do = store.find_or_create(input.id)
    to_do = to_do.with_message(input.data)
    store.save(to_do)

    log.write('receive', "#{input.id} - #{input.title}")
    Log.new(to_do.log_file).write('receive', 'Message received from Things')
  end
end

# Finds processable to-dos
#
class FindsProcessableToDos
  attr_reader :store

  def initialize(store: ToDoStore.new)
    @store = store
  end

  def call
    store.all_ids
      .map { |id| store.find(id) }
      .compact
      .select(&:processable?)
      .sort_by { |t| t.first_received_at || '' }
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
# Uses two safeguards:
# - --max-turns: graceful exit at turn boundaries (prevents runaway loops)
# - Timeout: hard ceiling on wall-clock time (prevents hung processes)
#
class AsksClaude
  ALLOWED_TOOLS = %w[WebSearch WebFetch].freeze
  MAX_TURNS = 10 # Enough for moderate research; may need adjustment based on real-world usage
  TIMEOUT_SECONDS = 300 # 5 minutes

  attr_reader :to_do_dir, :instructions_file

  def initialize(to_do_dir, instructions_file: THAINGS_CONFIG.instructions_file)
    @to_do_dir = to_do_dir
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
        chdir: to_do_dir.to_s
      )
      [stdout.force_encoding('UTF-8'), stderr.force_encoding('UTF-8'), status]
    end
  end
end

# Updates Things app via URL scheme
#
# Knows about Things-specific concepts like tags for workflow states.
#
class UpdatesThings
  TAG_WORKING = 'Working'
  TAG_READY = 'Ready'
  THAINGS_TAGS = [TAG_WORKING, TAG_READY].freeze

  class UpdateFailed < StandardError; end

  def append_note(id, text)
    note = "\n\n---\n\n#{text}\n\n***\n\n"

    open_url(id, 'append-notes' => note)
  end

  def set_working_tag(id, current_tags)
    set_workflow_tag(id, current_tags, TAG_WORKING)
  end

  def set_ready_tag(id, current_tags)
    set_workflow_tag(id, current_tags, TAG_READY)
  end

  private

  def set_workflow_tag(id, current_tags, new_tag)
    tags = without_thaings_tags(current_tags) + [new_tag]
    open_url(id, 'tags' => tags.join(','))
  end

  def without_thaings_tags(tags)
    tags.reject { |t| THAINGS_TAGS.include?(t) }
  end

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

# --- Pipeline Steps ---
#
# Each step transforms a ProcessingContext.
# Simple objects, easy to test in isolation.

# Updates Things to show "Working" tag
#
class SetWorkingTagStep
  def initialize(things:)
    @things = things
  end

  def call(ctx)
    @things.set_working_tag(ctx.to_do.id, ctx.to_do.tags)
    ctx
  end
end

# Builds prompt and asks Claude, stores response in context
#
class AskClaudeStep
  def initialize(log:)
    @log = log
  end

  def call(ctx)
    prompt = BuildsPrompt.new(ctx.to_do).call

    if prompt.strip.empty?
      @log.write('daemon', 'Skipped: no content to process')
      return ctx.with(response: 'Nothing to process - add a title or notes and try again.')
    end

    @log.write('daemon', "Prompt: #{prompt.lines.first&.strip}")
    response = AsksClaude.new(ctx.to_do.dir).call(prompt)
    ctx.with(response: response)
  end
end

# Marks all messages as processed and persists
#
class MarkProcessedStep
  def initialize(store:)
    @store = store
  end

  def call(ctx)
    processed = ctx.to_do.marked_processed
    @store.save(processed)
    ctx.with(to_do: processed)
  end
end

# Appends Claude's response to the Things note
#
class AppendResponseStep
  def initialize(things:)
    @things = things
  end

  def call(ctx)
    @things.append_note(ctx.to_do.id, ctx.response)
    ctx
  end
end

# Updates Things to show "Ready" tag
#
class SetReadyTagStep
  def initialize(things:)
    @things = things
  end

  def call(ctx)
    @things.set_ready_tag(ctx.to_do.id, ctx.to_do.tags)
    ctx
  end
end

# Processes a single to-do through Claude
#
# Lock wraps the pipeline (not a step in it).
# If locked, we skip. Otherwise, run all steps.
#
class ProcessesToDo
  attr_reader :to_do, :store, :things, :daemon_log

  def initialize(to_do, store: ToDoStore.new, things: UpdatesThings.new, daemon_log: Log.new(THAINGS_CONFIG.daemon_log))
    @to_do = to_do
    @store = store
    @things = things
    @daemon_log = daemon_log
  end

  def call
    lock = Lock.new(to_do.dir / '.lock')

    unless lock.acquire
      daemon_log.write('skip', "#{to_do.id} - already locked")
      return
    end

    begin
      daemon_log.write('start', "#{to_do.id} - processing")
      to_do_log.write('daemon', 'Started processing')

      pipeline.call(ProcessingContext.new(to_do: to_do))

      to_do_log.write('daemon', 'Completed')
      daemon_log.write('done', to_do.id)
    ensure
      lock.release
    end
  end

  private

  def to_do_log
    @to_do_log ||= Log.new(to_do.log_file)
  end

  def pipeline
    Pipeline.new([
      SetWorkingTagStep.new(things: things),
      AskClaudeStep.new(log: to_do_log),
      MarkProcessedStep.new(store: store),
      AppendResponseStep.new(things: things),
      SetReadyTagStep.new(things: things)
    ])
  end
end

# Entry point: wakes, finds processable to-dos, processes them
#
class RespondsToThingsToDo
  attr_reader :log

  def initialize(log: Log.new(THAINGS_CONFIG.daemon_log))
    @log = log
  end

  def call
    log.write('wake', 'Daemon triggered')

    to_dos = FindsProcessableToDos.new.call

    if to_dos.empty?
      log.write('idle', 'No to-dos to process')
      return
    end

    log.write('found', "#{to_dos.length} to-do(s) to process")

    to_dos.each { |to_do| ProcessesToDo.new(to_do).call }

    log.write('exit', 'Daemon finished')
  end
end
