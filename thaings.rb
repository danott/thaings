# frozen_string_literal: true

require 'time'
require 'json'
require 'fileutils'

THAINGS_ROOT = File.expand_path('~/.thaings')
THAINGS_TASKS_DIR = File.join(THAINGS_ROOT, 'tasks')
THAINGS_TASK_ENV_BOILERPLATE_DIR = File.join(THAINGS_ROOT, 'task-env-boilerplate')

# Append-only log writer
#
# Usage:
#   log = Log.new('path/to/file.log')
#   log.write('tag', 'message')
#   # => "2024-01-17T12:00:00Z [tag] message\n"
#
class Log
  def initialize(path)
    @path = path
  end

  def write(tag, message)
    File.open(@path, 'a') { |f| f.write(line(tag, message)) }
  end

  private

  def line(tag, message)
    "#{timestamp} [#{tag}] #{message}\n"
  end

  def timestamp
    Time.now.utc.iso8601
  end
end

# A task's lifecycle state
#
# States: waiting, working, success, blocked
#
# Transitions:
#   waiting              → working (picked up for processing)
#   working              → success (Claude responded Done:)
#   working              → blocked (Claude responded Blocked: or errored)
#   success + new_props  → working (user continues conversation)
#   blocked + new_props  → working (user provides info)
#
class TaskState
  STATUSES = %w[waiting working success blocked].freeze

  attr_reader :status

  def initialize(data)
    @data = data
    @status = data['status']
    @props_processed = data['props_processed'] || 0
  end

  def processable?(props_count)
    waiting? || (finished? && has_new_props?(props_count))
  end

  def waiting?
    status == 'waiting'
  end

  def working?
    status == 'working'
  end

  def finished?
    status == 'success' || status == 'blocked'
  end

  def has_new_props?(props_count)
    props_count > @props_processed
  end
end

# Domain object for a task from Things
#
# Usage:
#   task = Task.find_or_create('abc123')
#   task.append_props(data_from_things)
#   task.save!
#
class Task
  attr_reader :id, :dir, :state

  def self.find(id)
    dir = File.join(THAINGS_TASKS_DIR, id)
    path = File.join(dir, 'task.json')
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path, encoding: 'UTF-8'))
    new(id: id, dir: dir, data: data)
  end

  def self.find_or_create(id)
    find(id) || create(id)
  end

  def self.create(id)
    dir = File.join(THAINGS_TASKS_DIR, id)
    FileUtils.mkdir_p(dir)

    data = {
      'state' => {
        'status' => 'waiting',
        'received_at' => Time.now.utc.iso8601,
        'started_at' => nil,
        'completed_at' => nil,
        'result' => nil,
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
    @state = TaskState.new(data['state'])
  end

  # --- Queries ---

  def processable?
    state.processable?(props_count)
  end

  def props_count
    props.length
  end

  def received_at
    @data.dig('state', 'received_at')
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

  def non_status_tags
    tags.reject { |t| TaskState::STATUSES.include?(t.downcase) }
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

  def mark_finished!(status, result)
    update_state(
      'status' => status,
      'completed_at' => now,
      'result' => result,
      'props_processed' => props_count
    )
  end

  def save!
    json = JSON.pretty_generate(@data)
    File.write(task_file, json, encoding: 'UTF-8')
  end

  # --- Paths ---

  def task_file
    File.join(dir, 'task.json')
  end

  def log_file
    File.join(dir, 'task.log')
  end

  private

  def props
    @data['props'] ||= []
  end

  def update_state(updates)
    @data['state'].merge!(updates)
    @state = TaskState.new(@data['state'])
  end

  def now
    Time.now.utc.iso8601
  end
end
