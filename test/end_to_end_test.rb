# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "pathname"

require_relative "../lib/thaings"

# Stub for UpdatesThings - records updates without opening URLs
class StubUpdatesThings
  attr_reader :updates

  def initialize
    @updates = []
  end

  def update(id, to_do)
    @updates << { id: id, to_do: to_do }
  end

  def last_update
    @updates.last
  end

  def working_updates
    @updates.select { |u| u[:to_do].workflow_tag == "Working" }
  end

  def ready_updates
    @updates.select { |u| u[:to_do].workflow_tag == "Ready" }
  end
end

# Test helper for creating isolated test environments
module TestHelpers
  def setup
    super
    @test_root = Pathname(Dir.mktmpdir("thaings-test"))
    @config =
      ThaingsConfig.new(root: @test_root, things_auth_token: "test-token")

    # Create required directories
    @config.queue_dir.mkpath
    @config.to_dos_dir.mkpath
    @config.log_dir.mkpath

    # Create a minimal instructions file
    @config.instructions_file.write("You are a helpful assistant.")
  end

  def teardown
    FileUtils.rm_rf(@test_root) if @test_root&.exist?
    super
  end

  def config
    @config
  end

  def things_json(id:, title:, notes: "", tags: "")
    JSON.generate(
      {
        "Type" => "To-Do",
        "ID" => id,
        "Title" => title,
        "Notes" => notes,
        "Tags" => tags
      }
    )
  end
end

class EndToEndTest < Minitest::Test
  include TestHelpers

  def test_receive_creates_queue_and_pending_marker
    store = QueueStore.new(config: config)
    log = NullLog.new

    input = ThingsInput.new(things_json(id: "test123", title: "My Task"))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Verify queue was created
    queue = store.find("test123")
    assert queue, "Queue should exist"
    assert_equal "test123", queue.id
    assert_equal 1, queue.messages.length
    assert_equal "My Task", queue.messages.first.title

    # Verify pending marker was created
    assert config.queue_dir.join("test123").exist?,
           "Pending marker should exist"
  end

  def test_receive_adds_message_to_existing_queue
    store = QueueStore.new(config: config)
    log = NullLog.new

    # First message
    input1 = ThingsInput.new(things_json(id: "test123", title: "First"))
    ReceivesThingsToDo.new(input1, store: store, log: log).call

    # Second message
    input2 = ThingsInput.new(things_json(id: "test123", title: "Second"))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    queue = store.find("test123")
    assert_equal 2, queue.messages.length
    assert_equal "Second", queue.latest_message.title
  end

  def test_respond_finds_pending_queues
    store = QueueStore.new(config: config)
    log = NullLog.new

    # Create a pending queue
    input = ThingsInput.new(things_json(id: "test123", title: "Process me"))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Verify pending IDs include our queue
    ids = store.queued_ids
    assert_includes ids, "test123"
  end

  def test_to_do_transforms_are_immutable
    message =
      Message.new(
        received_at: "2024-01-01",
        data: {
          "Title" => "Test",
          "Notes" => "Original notes",
          "Tags" => "personal"
        }
      )
    to_do = ToDo.from_message(message)

    # marked_working returns new instance
    working = to_do.marked_working
    assert_equal "Working", working.workflow_tag
    assert_nil to_do.workflow_tag # original unchanged

    # with_response returns new instance with modified notes
    completed = to_do.with_response("My response")
    assert_includes completed.notes, "My response"
    assert_equal "Ready", completed.workflow_tag
    assert_equal "Original notes", to_do.notes # original unchanged
  end

  def test_with_response_appends_to_notes
    message =
      Message.new(
        received_at: "2024-01-01",
        data: {
          "Title" => "Test",
          "Notes" => "Original notes",
          "Tags" => ""
        }
      )
    to_do = ToDo.from_message(message)

    # Original notes unchanged
    assert_equal "Original notes", to_do.notes

    # with_response creates new ToDo with appended notes
    completed = to_do.with_response("Claude says hello")
    assert_includes completed.notes, "Original notes"
    assert_includes completed.notes, "Claude says hello"
    assert_includes completed.notes, "---" # separator
  end

  def test_to_do_final_tags_replaces_workflow_tag
    message =
      Message.new(
        received_at: "2024-01-01",
        data: {
          "Title" => "Test",
          "Notes" => "",
          "Tags" => "personal, Working, work"
        }
      )
    to_do = ToDo.from_message(message)

    # marked_working should replace existing Working tag
    working = to_do.marked_working
    assert_equal %w[personal work Working], working.final_tags

    # with_response sets Ready, removing Working
    completed = to_do.with_response("Done")
    assert_equal %w[personal work Ready], completed.final_tags
    refute_includes completed.final_tags, "Working"
  end

  def test_full_flow_with_stubbed_things
    store = QueueStore.new(config: config)
    log = NullLog.new
    things = StubUpdatesThings.new

    # Receive a to-do
    input =
      ThingsInput.new(
        things_json(id: "abc", title: "Help me", notes: "With this task")
      )
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Load the queue
    queue = store.find("abc")
    message = queue.latest_message
    to_do = ToDo.from_message(message)

    # Simulate what ProcessesQueue does (without actually calling Claude)

    # 1. Broadcast working state
    things.update(queue.id, to_do.marked_working)
    assert_equal 1, things.working_updates.length
    assert_equal "abc", things.working_updates.first[:id]

    # 2. Build prompt
    prompt = to_do.prompt
    assert_includes prompt, "Help me"
    assert_includes prompt, "With this task"

    # 3. Simulate Claude response and broadcast completed state
    completed = to_do.with_response("Here is my helpful answer")
    things.update(queue.id, completed)

    # Verify final state was broadcast
    assert_equal 1, things.ready_updates.length
    last = things.ready_updates.first[:to_do]
    assert_equal "Ready", last.workflow_tag
    assert_includes last.notes, "Here is my helpful answer"

    # 4. Mark processed
    store.mark_processed(queue, message.received_at)

    # Verify pending marker is cleared
    refute config.queue_dir.join("abc").exist?,
           "Pending marker should be cleared"
  end

  def test_new_message_during_processing_keeps_pending
    store = QueueStore.new(config: config)
    log = NullLog.new

    # Receive first message
    input1 = ThingsInput.new(things_json(id: "race", title: "First"))
    ReceivesThingsToDo.new(input1, store: store, log: log).call

    # Load queue and capture message (simulating start of processing)
    queue = store.find("race")
    captured_message = queue.latest_message

    # Receive second message DURING processing
    input2 = ThingsInput.new(things_json(id: "race", title: "Second"))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    # Mark the FIRST message as processed
    store.mark_processed(queue, captured_message.received_at)

    # Pending marker should STILL exist (because Second > First)
    assert config.queue_dir.join("race").exist?, "Pending marker should remain"

    # Latest message is the second one
    reloaded = store.find("race")
    assert_equal "Second", reloaded.latest_message.title
  end

  def test_queue_is_immutable_snapshot
    store = QueueStore.new(config: config)
    log = NullLog.new

    # Create initial queue
    input = ThingsInput.new(things_json(id: "snap", title: "Original"))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Load snapshot
    snapshot = store.find("snap")
    original_count = snapshot.messages.length

    # Add another message
    input2 = ThingsInput.new(things_json(id: "snap", title: "New"))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    # Original snapshot should be unchanged
    assert_equal original_count, snapshot.messages.length
    assert_equal "Original", snapshot.latest_message.title

    # Fresh load should have new message
    fresh = store.find("snap")
    assert_equal 2, fresh.messages.length
    assert_equal "New", fresh.latest_message.title
  end

  def test_validates_id_rejects_path_traversal
    store = QueueStore.new(config: config)
    log = NullLog.new

    bad_input =
      ThingsInput.new(things_json(id: "../../../etc/passwd", title: "Hack"))

    assert_raises(ArgumentError) do
      ReceivesThingsToDo.new(bad_input, store: store, log: log).call
    end
  end

  def test_ignores_non_todo_types
    store = QueueStore.new(config: config)
    log = NullLog.new

    input =
      ThingsInput.new(
        JSON.generate(
          { "Type" => "Project", "ID" => "proj123", "Title" => "My Project" }
        )
      )

    ReceivesThingsToDo.new(input, store: store, log: log).call

    # No queue should be created
    assert_nil store.find("proj123")
    assert_empty store.queued_ids
  end

  def test_rejects_todos_without_title
    store = QueueStore.new(config: config)
    log = NullLog.new

    input =
      ThingsInput.new(
        JSON.generate(
          {
            "Type" => "To-Do",
            "ID" => "empty123",
            "Title" => "",
            "Notes" => "Has notes but no title"
          }
        )
      )

    error =
      assert_raises(ThingsInput::InvalidInput) do
        ReceivesThingsToDo.new(input, store: store, log: log).call
      end

    assert_includes error.message, "missing a title"
    assert_nil store.find("empty123")
    assert_empty store.queued_ids
  end

  def test_accepts_todo_with_title_only
    store = QueueStore.new(config: config)
    log = NullLog.new

    input =
      ThingsInput.new(
        JSON.generate(
          { "Type" => "To-Do", "ID" => "title123", "Title" => "Just a title" }
        )
      )

    ReceivesThingsToDo.new(input, store: store, log: log).call

    queue = store.find("title123")
    assert queue, "Should accept to-do with only title"
  end
end

class LoadsEnvTest < Minitest::Test
  def setup
    @tmpdir = Pathname(Dir.mktmpdir("env-test"))
    @env_file = @tmpdir / ".env"
    @original_env = ENV.to_h
  end

  def teardown
    # Restore original ENV
    ENV.clear
    @original_env.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@tmpdir)
  end

  def test_basic_key_value
    @env_file.write("FOO=bar\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
  end

  def test_value_with_equals_sign
    @env_file.write("DATABASE_URL=postgres://host:5432?options=foo=bar\n")
    LoadsEnv.new(@env_file).call
    assert_equal "postgres://host:5432?options=foo=bar", ENV["DATABASE_URL"]
  end

  def test_double_quoted_value
    @env_file.write('FOO="hello world"' + "\n")
    LoadsEnv.new(@env_file).call
    assert_equal "hello world", ENV["FOO"]
  end

  def test_single_quoted_value
    @env_file.write("FOO='hello world'\n")
    LoadsEnv.new(@env_file).call
    assert_equal "hello world", ENV["FOO"]
  end

  def test_quoted_value_with_equals
    @env_file.write('URL="https://example.com?a=1&b=2"' + "\n")
    LoadsEnv.new(@env_file).call
    assert_equal "https://example.com?a=1&b=2", ENV["URL"]
  end

  def test_export_prefix
    @env_file.write("export FOO=bar\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
  end

  def test_export_with_quoted_value
    @env_file.write('export SECRET="my secret value"' + "\n")
    LoadsEnv.new(@env_file).call
    assert_equal "my secret value", ENV["SECRET"]
  end

  def test_inline_comment
    @env_file.write("FOO=bar # this is a comment\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
  end

  def test_quoted_value_preserves_hash
    @env_file.write('FOO="bar # not a comment"' + "\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar # not a comment", ENV["FOO"]
  end

  def test_ignores_comment_lines
    @env_file.write("# This is a comment\nFOO=bar\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
  end

  def test_ignores_empty_lines
    @env_file.write("\nFOO=bar\n\nBAZ=qux\n")
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
    assert_equal "qux", ENV["BAZ"]
  end

  def test_handles_missing_file
    missing = @tmpdir / "nonexistent"
    LoadsEnv.new(missing).call # Should not raise
  end

  def test_multiple_variables
    @env_file.write(<<~ENV)
      FOO=bar
      export BAZ="quoted value"
      SIMPLE=123 # with comment
    ENV
    LoadsEnv.new(@env_file).call
    assert_equal "bar", ENV["FOO"]
    assert_equal "quoted value", ENV["BAZ"]
    assert_equal "123", ENV["SIMPLE"]
  end
end
