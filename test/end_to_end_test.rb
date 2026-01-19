# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'pathname'

require_relative '../thaings'

# Stub for AsksClaude - returns canned response without calling Claude
class StubAsksClaude
  attr_reader :prompts_received

  def initialize(response: 'Test response from Claude')
    @prompts_received = []
    @response = response
  end

  def call(prompt)
    @prompts_received << prompt
    @response
  end
end

# Stub for UpdatesThings - records calls without opening URLs
class StubUpdatesThings
  attr_reader :calls

  def initialize
    @calls = []
  end

  def append_note(id, text)
    @calls << { method: :append_note, id: id, text: text }
  end

  def set_working_tag(id, current_tags)
    @calls << { method: :set_working_tag, id: id, tags: current_tags }
  end

  def set_ready_tag(id, current_tags)
    @calls << { method: :set_ready_tag, id: id, tags: current_tags }
  end
end

# Test helper for creating isolated test environments
module TestHelpers
  def setup
    super
    @test_root = Pathname(Dir.mktmpdir('thaings-test'))
    @config = ThaingsConfig.new(root: @test_root)

    # Create required directories
    @config.pending_dir.mkpath
    @config.queues_dir.mkpath
    @config.log_dir.mkpath

    # Create a minimal instructions file
    @config.instructions_file.write('You are a helpful assistant.')
  end

  def teardown
    FileUtils.rm_rf(@test_root) if @test_root&.exist?
    super
  end

  def config
    @config
  end

  def things_json(id:, title:, notes: '', tags: '')
    JSON.generate({
      'Type' => 'To-Do',
      'ID' => id,
      'Title' => title,
      'Notes' => notes,
      'Tags' => tags
    })
  end
end

class EndToEndTest < Minitest::Test
  include TestHelpers

  def test_receive_creates_queue_and_pending_marker
    store = QueueStore.new(config: config)
    log = NullLog.new

    input = ThingsInput.new(things_json(id: 'test123', title: 'My Task'))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Verify queue was created
    queue = store.find('test123')
    assert queue, 'Queue should exist'
    assert_equal 'test123', queue.id
    assert_equal 1, queue.messages.length
    assert_equal 'My Task', queue.messages.first.title

    # Verify pending marker was created
    assert config.pending_dir.join('test123').exist?, 'Pending marker should exist'
  end

  def test_receive_adds_message_to_existing_queue
    store = QueueStore.new(config: config)
    log = NullLog.new

    # First message
    input1 = ThingsInput.new(things_json(id: 'test123', title: 'First'))
    ReceivesThingsToDo.new(input1, store: store, log: log).call

    # Second message
    input2 = ThingsInput.new(things_json(id: 'test123', title: 'Second'))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    queue = store.find('test123')
    assert_equal 2, queue.messages.length
    assert_equal 'Second', queue.latest_message.title
  end

  def test_respond_processes_pending_queue
    store = QueueStore.new(config: config)
    log = NullLog.new
    things = StubUpdatesThings.new

    # Create a pending queue
    input = ThingsInput.new(things_json(id: 'test123', title: 'Process me'))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Verify it's processable
    queue = store.find('test123')
    assert queue.processable?, 'Queue should be processable'

    # Process it (with stubbed Claude)
    stub_claude = StubAsksClaude.new(response: 'Here is my answer')

    # We need to inject the stub Claude into the pipeline
    # For now, let's test the pieces we can without mocking AsksClaude
    # The full integration would require dependency injection for AsksClaude

    # Instead, test that RespondsToThingsToDo finds the pending queue
    ids = store.pending_ids
    assert_includes ids, 'test123'
  end

  def test_full_flow_with_stubbed_dependencies
    store = QueueStore.new(config: config)
    log = NullLog.new
    things = StubUpdatesThings.new

    # Receive a to-do
    input = ThingsInput.new(things_json(id: 'abc', title: 'Help me', notes: 'With this task'))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Load the queue
    queue = store.find('abc')
    assert queue.processable?

    # Build the context manually (simulating what ProcessesQueue does)
    message = queue.latest_message
    to_do = ToDo.from_message(message)
    ctx = ProcessingContext.new(queue: queue, message: message, to_do: to_do)

    # Run individual steps with stubs
    # Step 1: Set working tag
    SetWorkingTagStep.new(things: things).call(ctx)
    assert_equal :set_working_tag, things.calls.last[:method]
    assert_equal 'abc', things.calls.last[:id]

    # Step 2: Build prompt (no external deps)
    prompt = BuildsPrompt.new(to_do).call
    assert_includes prompt, 'Help me'
    assert_includes prompt, 'With this task'

    # Step 3: Simulate Claude response
    ctx = ctx.with(response: 'Here is my helpful answer')

    # Step 4: Mark processed
    MarkProcessedStep.new(store: store).call(ctx)

    # Verify pending marker is cleared (since we processed the latest)
    refute config.pending_dir.join('abc').exist?, 'Pending marker should be cleared'

    # Verify processed timestamp is set
    reloaded = store.find('abc')
    assert_equal message.received_at, reloaded.processed_at
    refute reloaded.processable?, 'Queue should not be processable after processing'

    # Step 5: Append response
    AppendResponseStep.new(things: things).call(ctx)
    append_call = things.calls.find { |c| c[:method] == :append_note }
    assert append_call
    assert_includes append_call[:text], 'Here is my helpful answer'

    # Step 6: Set ready tag
    SetReadyTagStep.new(things: things).call(ctx)
    assert_equal :set_ready_tag, things.calls.last[:method]
  end

  def test_new_message_during_processing_keeps_pending
    store = QueueStore.new(config: config)
    log = NullLog.new

    # Receive first message
    input1 = ThingsInput.new(things_json(id: 'race', title: 'First'))
    ReceivesThingsToDo.new(input1, store: store, log: log).call

    # Load queue and capture message (simulating start of processing)
    queue = store.find('race')
    captured_message = queue.latest_message

    # Receive second message DURING processing
    input2 = ThingsInput.new(things_json(id: 'race', title: 'Second'))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    # Mark the FIRST message as processed
    store.mark_processed(queue, captured_message.received_at)

    # Pending marker should STILL exist (because Second > First)
    assert config.pending_dir.join('race').exist?, 'Pending marker should remain'

    # Queue should still be processable
    reloaded = store.find('race')
    assert reloaded.processable?, 'Queue should still be processable'
    assert_equal 'Second', reloaded.latest_message.title
  end

  def test_queue_is_immutable_snapshot
    store = QueueStore.new(config: config)
    log = NullLog.new

    # Create initial queue
    input = ThingsInput.new(things_json(id: 'snap', title: 'Original'))
    ReceivesThingsToDo.new(input, store: store, log: log).call

    # Load snapshot
    snapshot = store.find('snap')
    original_count = snapshot.messages.length

    # Add another message
    input2 = ThingsInput.new(things_json(id: 'snap', title: 'New'))
    ReceivesThingsToDo.new(input2, store: store, log: log).call

    # Original snapshot should be unchanged
    assert_equal original_count, snapshot.messages.length
    assert_equal 'Original', snapshot.latest_message.title

    # Fresh load should have new message
    fresh = store.find('snap')
    assert_equal 2, fresh.messages.length
    assert_equal 'New', fresh.latest_message.title
  end

  def test_validates_id_rejects_path_traversal
    store = QueueStore.new(config: config)
    log = NullLog.new

    bad_input = ThingsInput.new(things_json(id: '../../../etc/passwd', title: 'Hack'))

    assert_raises(ValidatesId::Invalid) do
      ReceivesThingsToDo.new(bad_input, store: store, log: log).call
    end
  end

  def test_ignores_non_todo_types
    store = QueueStore.new(config: config)
    log = NullLog.new

    input = ThingsInput.new(JSON.generate({
      'Type' => 'Project',
      'ID' => 'proj123',
      'Title' => 'My Project'
    }))

    ReceivesThingsToDo.new(input, store: store, log: log).call

    # No queue should be created
    assert_nil store.find('proj123')
    assert_empty store.pending_ids
  end
end
