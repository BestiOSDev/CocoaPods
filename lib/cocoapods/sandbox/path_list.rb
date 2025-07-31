require 'active_support/multibyte/unicode'

module Pod
  class Sandbox
    # A list of files and directories relative to a root directory.
    #
    # This class is used to perform glob operations in a more efficient way
    # by reading the file system once and caching the results.
    #
    class PathList
      # @return [Pathname] The root directory of the path list.
      #
      attr_reader :root

      # @return [Array<String>] The list of files relative to the root.
      #
      attr_reader :files

      # @return [Array<String>] The list of directories relative to the root.
      #
      attr_reader :dirs

      # Initialize a new instance
      #
      # @param  [Pathname] root @see #root
      #
      def initialize(root)
        root_dir = root.to_s.unicode_normalize(:nfkc)
        @root = Pathname.new(root_dir)
        @files = nil
        @dirs = nil
        @glob_cache = {}
        @directory_cache = {}
      end

      # @return [Array<String>] The list of files relative to the root.
      #
      def files
        read_file_system unless @files
        @files
      end

      # @return [Array<String>] The list of directories relative to the root.
      #
      def dirs
        read_file_system unless @dirs
        @dirs
      end

      # Reads the file system and populates the files and directories lists.
      # This method is optimized to reduce file system calls and improve performance.
      #
      # @return [void]
      #
      def read_file_system
        unless root.exist?
          raise Informative, "Attempt to read non existent folder `#{root}`."
        end

        dirs = []
        files = []
        root_length = root.cleanpath.to_s.length + File::SEPARATOR.length
        escaped_root = escape_path_for_glob(root)

        # Use a more efficient approach to avoid multiple Dir.glob calls
        begin
          # Use Dir.entries for better performance on large directories
          entries = Dir.entries(escaped_root)
          entries.each do |entry|
            next if entry == '.' || entry == '..'
            
            full_path = File.join(escaped_root, entry)
            relative_path = full_path.slice(root_length, full_path.length - root_length)
            next if relative_path.nil?

            if File.directory?(full_path)
              dirs << relative_path
              # Recursively add subdirectories and files
              subdir_entries = Dir.entries(full_path)
              subdir_entries.each do |subentry|
                next if subentry == '.' || subentry == '..'
                sub_path = File.join(relative_path, subentry)
                sub_full_path = File.join(full_path, subentry)
                if File.directory?(sub_full_path)
                  dirs << sub_path
                else
                  files << sub_path
                end
              end
            else
              files << relative_path
            end
          end
        rescue Errno::ENOTDIR
          # Fallback to original Dir.glob method if the path is not a directory
          Dir.glob(escaped_root + '**/*', File::FNM_DOTMATCH).each do |f|
            directory = File.directory?(f)
            # Ignore `.` and `..` directories
            next if directory && f =~ /\.\.?$/

            f = f.slice(root_length, f.length - root_length)
            next if f.nil?

            (directory ? dirs : files) << f
          end
        end

        dirs.sort_by!(&:upcase)
        files.sort_by!(&:upcase)

        @dirs = dirs
        @files = files
        @glob_cache = {}
      end

      #-----------------------------------------------------------------------#

      public

      # @!group Globbing

      # Similar to {glob} but returns the absolute paths.
      #
      # @param  [String,Array<String>] patterns
      #         @see #relative_glob
      #
      # @param  [Hash] options
      #         @see #relative_glob
      #
      # @return [Array<Pathname>]
      #
      def glob(patterns, options = {})
        cache_key = options.merge(:patterns => patterns)
        @glob_cache[cache_key] ||= relative_glob(patterns, options).map { |p| root.join(p) }
      end

      # The list of relative paths that are case insensitively matched by a
      # given pattern. This method emulates {Dir#glob} with the
      # {File::FNM_CASEFOLD} option.
      #
      # @param  [String,Array<String>] patterns
      #         A single {Dir#glob} like pattern, or a list of patterns.
      #
      # @param  [Hash] options
      #
      # @option options [String] :dir_pattern
      #         An optional pattern to append to a pattern, if it is the path
      #         to a directory.
      #
      # @option options [Array<String>] :exclude_patterns
      #         Exclude specific paths given by those patterns.
      #
      # @option options [Array<String>] :include_dirs
      #         Additional paths to take into account for matching.
      #
      # @return [Array<Pathname>]
      #
      def relative_glob(patterns, options = {})
        return [] if patterns.empty?

        dir_pattern = options[:dir_pattern]
        exclude_patterns = options[:exclude_patterns]
        include_dirs = options[:include_dirs]

        if include_dirs
          full_list = files + dirs
        else
          full_list = files
        end
        patterns_array = Array(patterns)
        exact_matches = (full_list & patterns_array).to_set

        unless patterns_array.empty?
          list = patterns_array.flat_map do |pattern|
            if exact_matches.include?(pattern)
              pattern
            else
              if directory?(pattern) && dir_pattern
                pattern += '/' unless pattern.end_with?('/')
                pattern += dir_pattern
              end
              expanded_patterns = dir_glob_equivalent_patterns(pattern)
              full_list.select do |path|
                expanded_patterns.any? do |p|
                  File.fnmatch(p, path, File::FNM_CASEFOLD | File::FNM_PATHNAME)
                end
              end
            end
          end

          if exclude_patterns
            list = list.reject do |path|
              exclude_patterns.any? do |pattern|
                File.fnmatch(pattern, path, File::FNM_CASEFOLD | File::FNM_PATHNAME)
              end
            end
          end

          list
        else
          []
        end
      end

      #-----------------------------------------------------------------------#

      private

      # @!group Private methods

      # Checks if a sub path is a directory.
      #
      # @param  [String] sub_path
      #         The sub path to check.
      #
      # @return [Boolean] Whether the sub path is a directory.
      #
      def directory?(sub_path)
        sub_path = sub_path.to_s.downcase.sub(/\/$/, '')
        @directory_cache[sub_path] ||= dirs.any? do |dir|
          dir.downcase.sub(/\/$/, '') == sub_path
        end
      end

      # Converts a {Dir.glob} pattern to patterns that {File.fnmatch} can handle.
      # This method is used to convert patterns that use the `**` globbing
      # feature to patterns that can be used with {File.fnmatch}.
      #
      # @param  [String] pattern
      #         The pattern to convert.
      #
      # @return [Array<String>] The converted patterns.
      #
      def dir_glob_equivalent_patterns(pattern)
        pattern = pattern.gsub('/**/', '{/**/,/}')
        if pattern.include?('**')
          patterns = []
          if pattern.include?('/**/')
            patterns << pattern.gsub('/**/', '/')
            patterns << pattern.gsub('/**/', '/**/')
          else
            patterns << pattern
          end
          patterns
        else
          [pattern]
        end
      end

      # Escapes a path for use with {Dir.glob}.
      #
      # @param  [Pathname] path
      #         The path to escape.
      #
      # @return [String] The escaped path.
      #
      def escape_path_for_glob(path)
        result = path.to_s
        # Escape special glob characters
        result = result.gsub(/[\[\]{}?*]/, '\\\\\0')
        result
      end
    end
  end
end
