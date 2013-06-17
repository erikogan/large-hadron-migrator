# Copyright (c) 2011 - 2013, SoundCloud Ltd., Rany Keddo, Tobias Bielohlawek, Tobias
# Schmidt

require 'lhm/command'
require 'lhm/sql_helper'
require 'pry'

module Lhm
  class Chunker
    include Command
    include SqlHelper

    attr_reader :connection

    # Copy from origin to destination in chunks of size `stride`. Sleeps for
    # `throttle` milliseconds between each stride.
    def initialize(migration, connection = nil, options = {})
      @migration = migration
      @connection = connection
      @stride = options[:stride] || 40_000
      @throttle = options[:throttle] || 100
      @start = options[:start] || select_start
      @limit = options[:limit] || select_limit
    end

    # Copies chunks of size `stride`, starting from `start` up to id `limit`.
    def copy_chunks(&block)
      lowest = @start
      while lowest <= @limit
        highest = highest_for(lowest)
        yield lowest, highest
        lowest = highest + 1
      end
    end

    def highest_for(lowest)
      [lowest - 1 + @stride, @limit].min
    end

    def copy(lowest, highest)
      "insert ignore into `#{ destination_name }` (#{ columns }) " +
      "select #{ columns } from `#{ origin_name }` " +
      "where `id` between #{ lowest } and #{ highest }"
    end

    def select_start
      start = connection.select_value("select min(id) from #{ origin_name }")
      start ? start.to_i : 0
    end

    def select_limit
      limit = connection.select_value("select max(id) from #{ origin_name }")
      limit ? limit.to_i : 0
    end

    def throttle_seconds
      @throttle / 1000.0
    end

  private

    def destination_name
      @migration.destination.name
    end

    def origin_name
      @migration.origin.name
    end

    def columns
      @columns ||= @migration.intersection.joined
    end

    def validate
      if @start && @limit && @start > @limit
        error("impossible chunk options (limit must be greater than start)")
      end
    end

    def execute
      copy_chunks do |lowest, highest|
        with_pry do
          affected_rows = @connection.update(copy(lowest, highest))

          if affected_rows > 0
            sleep(throttle_seconds)
          end

          print "."
        end
      end
      print "\n"
    end

    def with_pry
      pry_please = false
      old_handler = Signal.trap('SIGINT') { pry_please = true }

      yield

      if pry_please
        pry_please = false
        self.pry
      end

      Signal.trap('SIGINT', old_handler)
    end
  end
end
