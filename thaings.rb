# frozen_string_literal: true

require 'time'
require 'json'
require 'fileutils'
require 'logger'
require 'pathname'

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
#   EnvLoader.new(config.env_file).load
#
class EnvLoader
  attr_reader :path

  def initialize(path)
    @path = Pathname(path)
  end

  def load
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

# A to-do's lifecycle state (immutable value object)
#
# States: pending, working, review
#
# Transitions:
#   pending              → working (picked up for processing)
#   working              → review  (Claude responded)
#   review + new_props   → working (user continues conversation)
#
class ToDoState
  attr_reader :status, :received_at, :started_at, :completed_at, :props_processed

  def initialize(data)
    @status = data['status']
    @received_at = data['received_at']
    @started_at = data['started_at']
    @completed_at = data['completed_at']
    @props_processed = data['props_processed'] || 0
  end

  def with(status: nil, started_at: nil, completed_at: nil, props_processed: nil)
    ToDoState.new(
      'status' => status || self.status,
      'received_at' => received_at,
      'started_at' => started_at || self.started_at,
      'completed_at' => completed_at || self.completed_at,
      'props_processed' => props_processed || self.props_processed
    )
  end

  def processable?(props_count)
    pending? || (review? && has_new_props?(props_count))
  end

  def pending?
    status == 'pending'
  end

  def working?
    status == 'working'
  end

  def review?
    status == 'review'
  end

  private

  def has_new_props?(props_count)
    props_count > props_processed
  end
end

# Validates a to-do ID to prevent path traversal attacks
#
# Usage:
#   ValidatesId.new(id).call  # => id (or raises)
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

# Simple data object for a to-do
#
# Just holds data. Use ToDoStore for persistence.
#
class ToDo
  attr_reader :id, :dir, :state, :props

  def initialize(id:, dir:, state:, props:)
    @id = id
    @dir = dir
    @state = state
    @props = props
  end

  # --- Queries ---

  def processable?
    state.processable?(props_count)
  end

  def props_count
    props.length
  end

  def received_at
    state.received_at
  end

  def latest_props
    props.last&.dig('data') || {}
  end

  def title
    latest_props['Title']
  end

  def notes
    latest_props['Notes'] || ''
  end

  def checklist
    latest_props['Checklist Items']
  end

  def tags
    tags_str = latest_props['Tags'] || ''
    tags_str.split(',').map(&:strip).reject(&:empty?)
  end

  # --- Paths ---

  def to_do_file
    dir / 'to-do.json'
  end

  def log_file
    dir / 'to-do.log'
  end
end

# Handles reading/writing to-dos to disk
#
# Usage:
#   store = ToDoStore.new
#   to_do = store.find_or_create('abc123')
#   store.append_props(to_do, data)
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
    build_to_do(id, dir, data)
  end

  def find_or_create(id)
    find(id) || create(id)
  end

  def create(id)
    ValidatesId.new(id).call
    dir = root_dir / id
    dir.mkpath

    data = empty_to_do_data
    build_to_do(id, dir, data)
  end

  def all_ids
    return [] unless root_dir.exist?

    root_dir.glob('*/to-do.json').map do |path|
      path.dirname.basename.to_s
    end
  end

  def save(to_do)
    data = to_hash(to_do)
    json = JSON.pretty_generate(data)
    File.write(to_do.to_do_file, json, encoding: 'UTF-8')
  end

  def append_props(to_do, new_data)
    new_props = to_do.props + [{
      'received_at' => Time.now.utc.iso8601,
      'data' => new_data
    }]

    ToDo.new(
      id: to_do.id,
      dir: to_do.dir,
      state: to_do.state,
      props: new_props
    )
  end

  def mark_working(to_do)
    new_state = to_do.state.with(
      status: 'working',
      started_at: Time.now.utc.iso8601
    )

    ToDo.new(id: to_do.id, dir: to_do.dir, state: new_state, props: to_do.props)
  end

  def mark_review(to_do)
    new_state = to_do.state.with(
      status: 'review',
      completed_at: Time.now.utc.iso8601,
      props_processed: to_do.props_count
    )

    ToDo.new(id: to_do.id, dir: to_do.dir, state: new_state, props: to_do.props)
  end

  private

  def build_to_do(id, dir, data)
    ToDo.new(
      id: id,
      dir: dir,
      state: ToDoState.new(data['state']),
      props: data['props'] || []
    )
  end

  def empty_to_do_data
    {
      'state' => {
        'status' => 'pending',
        'received_at' => Time.now.utc.iso8601,
        'started_at' => nil,
        'completed_at' => nil,
        'props_processed' => 0
      },
      'props' => []
    }
  end

  def to_hash(to_do)
    {
      'state' => {
        'status' => to_do.state.status,
        'received_at' => to_do.state.received_at,
        'started_at' => to_do.state.started_at,
        'completed_at' => to_do.state.completed_at,
        'props_processed' => to_do.state.props_processed
      },
      'props' => to_do.props
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
