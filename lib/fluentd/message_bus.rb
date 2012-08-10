#
# Fluentd
#
# Copyright (C) 2011-2012 FURUHASHI Sadayuki
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Fluentd


  class MessageBus < AgentGroup
    include Collector

    def initialize
      super
      @match_cache = {}
      @matches = []
      @default_collector = Collectors::NoMatchCollector.new
    end

    attr_accessor :default_collector

    def configure(conf)
      conf.elements.select {|e|
        e.name == 'source' || e.name == 'match' || e.name == 'filter'
      }.each {|e|
        case e.name
        when 'source'
          type = e['type']
          raise ConfigError, "Missing 'type' parameter" unless type
          add_source(type, e)

        when 'filter'
          pattern = MatchPattern.create(e.arg.empty? ? '**' : e.arg)
          type = e['type']
          raise ConfigError, "Missing 'type' parameter" unless type
          add_filter(type, pattern, e)

        when 'match'
          pattern = MatchPattern.create(e.arg.empty? ? '**' : e.arg)
          type = e['type'] || 'redirect'
          add_output(type, pattern, e)
        end
      }
    end

    def add_source(type, e)
      #$log.info "adding source", :type=>type
      agent = Plugin.new_input(type)
      configure_agent(agent, e)
    end

    def add_output(type, pattern, e)
      #$log.info "adding match", :pattern=>patstr, :type=>type
      agent = Plugin.new_output(type)
      configure_agent(agent, e)

      @matches << Match.new(pattern, agent)
    end

    def add_filter(type, pattern, e)
      #$log.info "adding filter", :pattern=>patstr, :type=>type
      agent = Plugin.new_filter(type)
      configure_agent(agent, e)

      @matches << FilterMatch.new(pattern, agent)
    end

    # override
    def open(tag, &block)
      collector = @match_cache[tag]
      unless collector
        collector = match(tag) || @default_collector
        if @match_cache.size < 1024  # TODO size limit
          @match_cache[tag] = collector
        end
      end
      collector.open(tag, &block)
    end

    private

    def match(tag)
      collectors = []
      @matches.each {|m|
        if m.pattern.match?(m)
          collectors << m.collector
          unless m.filter?
            if collectors.size == 1
              return collectors[0]
            else
              return Collectors::FilteringCollector.new(collectors)
            end
          end
        end
      }
      return nil
    end

    class Match
      def initialize(pattern, collector)
        @pattern = pattern
        @collector = collector
      end

      attr_reader :pattern, :collector

      def filter?
        false
      end
    end

    class FilterMatch < Match
      def filter?
        true
      end
    end

    def configure_agent(agent, e)
      add_agent(agent)

      if agent.is_a?(StreamSource)
        bus = MessageBus.new
        add_agent_group(bus)

        bus.configure(e)
        bus.default_collector = self

        agent.setup_internal_bus(bus)
      end

      agent.configure(e)
      agent = nil

    ensure
      agent.shutdown if agent
    end
  end


  class LabeledMessageBus < MessageBus
    def initialize
      super
      @labels = {}
    end

    def configure(conf)
      super

      conf.elements.select {|e|
        e.name == 'label'
      }.each {|e|
        add_label(e)
      }
    end

    def open(tag, label=nil)
      return ensure_close(open(tag), &proc) if block_given?
      if label
        if bus = @labels[label]
          return bus.open(tag)
        else
          raise "unknown label: #{label}"  # TODO error
        end
      else
        # default label
        super(tag)
      end
    end

    def add_label(e)
      label = e.arg  # TODO validate label

      bus = MessageBus.new
      bus.configure(e)

      @labels[label] = bus

      add_agent_group(bus)
      self
    end
  end
end

