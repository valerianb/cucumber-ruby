# frozen_string_literal: true

require 'base64'
require 'cucumber/formatter/io'
require 'cucumber/formatter/query/hook_by_test_step'
require 'cucumber/formatter/query/pickle_by_test'
require 'cucumber/formatter/query/pickle_step_by_test_step'
require 'cucumber/formatter/query/step_definitions_by_test_step'

module Cucumber
  module Formatter
    # The formatter used for <tt>--format message</tt>
    class Message
      include Io

      def initialize(config)
        @config = config
        @hook_by_test_step = Query::HookByTestStep.new(config)
        @pickle_by_test = Query::PickleByTest.new(config)
        @pickle_step_by_test_step = Query::PickleStepByTestStep.new(config)
        @step_definitions_by_test_step = Query::StepDefinitionsByTestStep.new(config)

        @io = ensure_io(config.out_stream)
        config.on_event :envelope, &method(:on_envelope)
        config.on_event :gherkin_source_read, &method(:on_gherkin_source_read)
        config.on_event :test_case_ready, &method(:on_test_case_ready)
        config.on_event :test_run_started, &method(:on_test_run_started)
        config.on_event :test_case_started, &method(:on_test_case_started)
        config.on_event :test_step_started, &method(:on_test_step_started)
        config.on_event :test_step_finished, &method(:on_test_step_finished)
        config.on_event :test_case_finished, &method(:on_test_case_finished)
        config.on_event :test_run_finished, &method(:on_test_run_finished)

        @test_case_id_by_step = {}
        @current_test_case_started_id = nil
        @current_test_step_id = nil
      end

      def embed(src, media_type, _label)
        attachment_data = {
          test_step_id: @current_test_step_id,
          test_case_started_id: @current_test_case_started_id,
          media_type: media_type
        }

        if media_type == 'text/plain'
          attachment_data[:text] = src
        elsif src.respond_to? :read
          attachment_data[:binary] = Base64.encode64(src.read)
        else
          attachment_data[:binary] = Base64.encode64(src)
        end

        message = Cucumber::Messages::Envelope.new(
          attachment: Cucumber::Messages::Attachment.new(**attachment_data)
        )

        output_envelope(message)
      end

      private

      def output_envelope(envelope)
        envelope.write_ndjson_to(@io)
      end

      def on_envelope(event)
        output_envelope(event.envelope)
      end

      def on_gherkin_source_read(event)
        message = Cucumber::Messages::Envelope.new(
          source: Cucumber::Messages::Source.new(
            uri: event.path,
            data: event.body,
            media_type: 'text/x.cucumber.gherkin+plain'
          )
        )

        output_envelope(message)
      end

      def on_test_case_ready(event)
        event.test_case.test_steps.each do |step|
          @test_case_id_by_step[step.id] = event.test_case.id
        end

        message = Cucumber::Messages::Envelope.new(
          test_case: Cucumber::Messages::TestCase.new(
            id: event.test_case.id,
            pickle_id: @pickle_by_test.pickle_id(event.test_case),
            test_steps: event.test_case.test_steps.map do |step|
              if step.hook?
                Cucumber::Messages::TestCase::TestStep.new(
                  id: step.id,
                  hook_id: @hook_by_test_step.hook_id(step)
                )
              else
                Cucumber::Messages::TestCase::TestStep.new(
                  id: step.id,
                  pickle_step_id: @pickle_step_by_test_step.pickle_step_id(step),
                  step_definition_ids: @step_definitions_by_test_step.step_definition_ids(step)
                )
              end
            end
          )
        )

        output_envelope(message)
      end

      def on_test_run_started(*)
        message = Cucumber::Messages::Envelope.new(
          test_run_started: Cucumber::Messages::TestRunStarted.new
        )

        output_envelope(message)
      end

      def on_test_case_started(event)
        test_case_started_id = "#{event.test_case.id}-0"
        @current_test_case_started_id = test_case_started_id

        message = Cucumber::Messages::Envelope.new(
          test_case_started: Cucumber::Messages::TestCaseStarted.new(
            id: test_case_started_id,
            test_case_started_id: event.test_case.id
          )
        )

        output_envelope(message)
      end

      def on_test_step_started(event)
        test_case_id = @test_case_id_by_step[event.test_step.id]
        @current_test_step_id = event.test_step.id

        message = Cucumber::Messages::Envelope.new(
          test_step_started: Cucumber::Messages::TestStepStarted.new(
            test_step_id: event.test_step.id,
            test_case_started_id: "#{test_case_id}-0"
          )
        )

        output_envelope(message)
      end

      def on_test_step_finished(event)
        test_case_id = @test_case_id_by_step[event.test_step.id]

        message = Cucumber::Messages::Envelope.new(
          test_step_finished: Cucumber::Messages::TestStepFinished.new(
            test_step_id: event.test_step.id,
            test_case_started_id: "#{test_case_id}-0",
            test_result: event.result.to_message
          )
        )

        output_envelope(message)
      end

      def on_test_case_finished(event)
        message = Cucumber::Messages::Envelope.new(
          test_case_finished: Cucumber::Messages::TestCaseFinished.new(
            test_case_started_id: "#{event.test_case.id}-0"
          )
        )

        output_envelope(message)
      end

      def on_test_run_finished(*)
        message = Cucumber::Messages::Envelope.new(
          test_run_finished: Cucumber::Messages::TestRunFinished.new
        )

        output_envelope(message)
      end
    end
  end
end