# frozen_string_literal: true

require 'time'
require 'json'
require 'fileutils'
require 'logger'

THAINGS_ROOT = File.expand_path('~/.thaings')
THAINGS_TO_DOS_DIR = File.join(THAINGS_ROOT, 'to-dos')

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

# A to-do's lifecycle state
#
# States: pending, working, review
#
# Transitions:
#   pending              → working (picked up for processing)
#   working              → review  (Claude responded)
#   review + new_props   → working (user continues conversation)
#
# Tags in Things:
#   Working → pending/working (agent's turn)
#   Ready   → review (human's turn)
#
class ToDoState
  TAG_PENDING = 'Working'
  TAG_REVIEW = 'Ready'
  THAINGS_TAGS = [TAG_PENDING, TAG_REVIEW].freeze

  attr_reader :status, :props_processed

  def initialize(data)
    @status = data['status']
    @props_processed = data['props_processed'] || 0
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

# Domain object for a to-do from Things
#
# Usage:
#   to_do = ToDo.find_or_create('abc123')
#   to_do.append_props(data_from_things)
#   to_do.save!
#
class ToDo
  ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

  class InvalidIdError < ArgumentError; end

  attr_reader :id, :dir, :state, :data

  def self.validate_id!(id)
    return if id.is_a?(String) && id.match?(ID_PATTERN)

    raise InvalidIdError, "Invalid to-do ID: #{id.inspect}"
  end

  def self.find(id)
    validate_id!(id)
    dir = File.join(THAINGS_TO_DOS_DIR, id)
    path = File.join(dir, 'to-do.json')
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path, encoding: 'UTF-8'))
    new(id: id, dir: dir, data: data)
  end

  def self.find_or_create(id)
    find(id) || create(id)
  end

  def self.create(id)
    validate_id!(id)
    dir = File.join(THAINGS_TO_DOS_DIR, id)
    FileUtils.mkdir_p(dir)

    data = {
      'state' => {
        'status' => 'pending',
        'received_at' => Time.now.utc.iso8601,
        'started_at' => nil,
        'completed_at' => nil,
        'props_processed' => 0
      },
      'props' => []
    }

    new(id: id, dir: dir, data: data)
  end

  def initialize(id:, dir:, data:)
    @id = id
    @dir = dir
    @data = data
    @state = ToDoState.new(data['state'])
  end

  # --- Queries ---

  def processable?
    state.processable?(props_count)
  end

  def props_count
    props.length
  end

  def received_at
    data.dig('state', 'received_at')
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

  def non_thaings_tags
    tags.reject { |t| ToDoState::THAINGS_TAGS.include?(t) }
  end

  # --- Commands ---

  def append_props(data)
    props << {
      'received_at' => now,
      'data' => data
    }
  end

  def mark_working!
    update_state('status' => 'working', 'started_at' => now)
  end

  def mark_review!
    update_state(
      'status' => 'review',
      'completed_at' => now,
      'props_processed' => props_count
    )
  end

  def save!
    json = JSON.pretty_generate(data)
    File.write(to_do_file, json, encoding: 'UTF-8')
  end

  # --- Paths ---

  def to_do_file
    File.join(dir, 'to-do.json')
  end

  def log_file
    File.join(dir, 'to-do.log')
  end

  private

  def props
    data['props'] ||= []
  end

  def update_state(updates)
    data['state'].merge!(updates)
    @state = ToDoState.new(data['state'])
  end

  def now
    Time.now.utc.iso8601
  end
end
