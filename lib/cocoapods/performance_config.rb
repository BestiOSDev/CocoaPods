require 'cocoapods/config'

module Pod
  # Performance configuration options for CocoaPods
  #
  # This module provides various performance optimization settings that can be
  # enabled to improve CocoaPods performance.
  #
  module PerformanceConfig
    extend Config::Mixin

    # @return [Boolean] Whether to enable aggressive caching for file system operations
    #
    def self.enable_aggressive_caching?
      config.performance_enable_aggressive_caching
    end

    # @return [Boolean] Whether to enable parallel processing for dependency resolution
    #
    def self.enable_parallel_processing?
      config.performance_enable_parallel_processing
    end

    # @return [Boolean] Whether to enable memory optimization for large projects
    #
    def self.enable_memory_optimization?
      config.performance_enable_memory_optimization
    end

    # @return [Boolean] Whether to enable lazy loading for ActiveSupport extensions
    #
    def self.enable_lazy_loading?
      config.performance_enable_lazy_loading
    end

    # @return [Boolean] Whether to enable optimized file system operations
    #
    def self.enable_optimized_file_system?
      config.performance_enable_optimized_file_system
    end

    # @return [Integer] The maximum number of parallel workers for processing
    #
    def self.max_parallel_workers
      config.performance_max_parallel_workers || 4
    end

    # @return [Integer] The cache size limit for file system operations (in MB)
    #
    def self.file_system_cache_size_limit
      config.performance_file_system_cache_size_limit || 100
    end

    # @return [Boolean] Whether to enable verbose performance logging
    #
    def self.enable_performance_logging?
      config.performance_enable_logging
    end

    # Logs performance metrics if enabled
    #
    # @param  [String] operation
    #         The operation being performed
    #
    # @param  [Float] duration
    #         The duration of the operation in seconds
    #
    # @return [void]
    #
    def self.log_performance(operation, duration)
      return unless enable_performance_logging?
      UI.message "[PERF] #{operation}: #{duration.round(3)}s"
    end

    # Measures the performance of a block and logs it if enabled
    #
    # @param  [String] operation
    #         The operation being performed
    #
    # @yield  The block to measure
    #
    # @return [Object] The result of the block
    #
    def self.measure_performance(operation)
      start_time = Time.now
      result = yield
      duration = Time.now - start_time
      log_performance(operation, duration)
      result
    end

    # Clears performance caches
    #
    # @return [void]
    #
    def self.clear_caches
      return unless enable_aggressive_caching?
      # Clear file system caches
      if defined?(@@file_system_cache)
        @@file_system_cache.clear
      end
      if defined?(@@path_list_cache)
        @@path_list_cache.clear
      end
    end

    # Gets or creates a file system cache
    #
    # @return [Hash] The file system cache
    #
    def self.file_system_cache
      return {} unless enable_aggressive_caching?
      @@file_system_cache ||= {}
    end

    # Gets or creates a path list cache
    #
    # @return [Hash] The path list cache
    #
    def self.path_list_cache
      return {} unless enable_aggressive_caching?
      @@path_list_cache ||= {}
    end

    # Checks if a file system operation should be cached
    #
    # @param  [String] operation
    #         The operation being performed
    #
    # @return [Boolean] Whether the operation should be cached
    #
    def self.should_cache_file_system_operation?(operation)
      return false unless enable_aggressive_caching?
      return false if file_system_cache.size >= file_system_cache_size_limit
      
      # Cache expensive operations
      %w[glob read_file_system directory?].include?(operation)
    end

    # Caches a file system operation result
    #
    # @param  [String] key
    #         The cache key
    #
    # @param  [Object] value
    #         The value to cache
    #
    # @return [void]
    #
    def self.cache_file_system_operation(key, value)
      return unless should_cache_file_system_operation?(key)
      file_system_cache[key] = value
    end

    # Gets a cached file system operation result
    #
    # @param  [String] key
    #         The cache key
    #
    # @return [Object, nil] The cached value or nil if not found
    #
    def self.get_cached_file_system_operation(key)
      return nil unless enable_aggressive_caching?
      file_system_cache[key]
    end

    # Optimizes memory usage for large projects
    #
    # @return [void]
    #
    def self.optimize_memory_usage
      return unless enable_memory_optimization?
      
      # Force garbage collection
      GC.start
      
      # Clear unnecessary caches
      clear_caches
    end

    # Configures parallel processing if enabled
    #
    # @return [void]
    #
    def self.configure_parallel_processing
      return unless enable_parallel_processing?
      
      # Set thread pool size
      ThreadPool.max_workers = max_parallel_workers if defined?(ThreadPool)
    end

    # Thread pool for parallel processing
    #
    class ThreadPool
      attr_accessor :max_workers

      def initialize(max_workers = 4)
        @max_workers = max_workers
        @queue = Queue.new
        @workers = []
        start_workers
      end

      def submit(&block)
        @queue << block
      end

      def shutdown
        @max_workers.times { @queue << nil }
        @workers.each(&:join)
      end

      private

      def start_workers
        @max_workers.times do
          @workers << Thread.new do
            while (task = @queue.pop)
              task.call
            end
          end
        end
      end
    end
  end
end