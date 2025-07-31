require 'cocoapods/podfile'

module Pod
  class Installer
    # Analyzes the Podfile, the Lockfile, and the sandbox manifest to generate
    # the information relative to a CocoaPods installation.
    #
    class Analyzer
      include Config::Mixin

      autoload :AnalysisResult,            'cocoapods/installer/analyzer/analysis_result'
      autoload :LockingDependencyAnalyzer, 'cocoapods/installer/analyzer/locking_dependency_analyzer'
      autoload :PodfileDependencyCache,    'cocoapods/installer/analyzer/podfile_dependency_cache'
      autoload :PodVariant,                'cocoapods/installer/analyzer/pod_variant'
      autoload :PodVariantSet,             'cocoapods/installer/analyzer/pod_variant_set'
      autoload :SandboxAnalyzer,           'cocoapods/installer/analyzer/sandbox_analyzer'
      autoload :SpecsState,                'cocoapods/installer/analyzer/specs_state'
      autoload :TargetInspectionResult,    'cocoapods/installer/analyzer/target_inspection_result'
      autoload :TargetInspector,           'cocoapods/installer/analyzer/target_inspector'

      # The default version of iOS which requires binaries with only 64-bit architectures
      #
      IOS_64_BIT_ONLY_VERSION = Version.new('11.0')

      # The valid platforms for linting
      #
      IOS_64_BIT_ONLY_PROJECT_VERSION = 50

      # @return [Sandbox] The sandbox to use for this analysis.
      #
      attr_reader :sandbox

      # @return [Podfile] The Podfile specification that contains the information of the Pods that should be installed.
      #
      attr_reader :podfile

      # @return [Lockfile, nil] The Lockfile, if available, that stores the information about the Pods previously installed.
      #
      attr_reader :lockfile

      # @return [Array<Source>] Sources provided by plugins or `nil`.
      #
      attr_reader :plugin_sources

      # @return [Boolean] Whether the analysis has dependencies and thus sources must be configured.
      #
      # @note   This is used by the `pod lib lint` command to prevent update of specs when not needed.
      #
      attr_reader :has_dependencies
      alias_method :has_dependencies?, :has_dependencies

      # @return [Hash, Boolean, nil] Pods that have been requested to be updated or true if all Pods should be updated.
      #         This can be false if no pods should be updated.
      #
      attr_reader :pods_to_update

      # @return [InstallationOptions] the installation options specified by the Podfile
      #
      attr_reader :installation_options

      # @return [Source::Manager] the sources manager to use when resolving dependencies
      #
      attr_reader :sources_manager

      # Initialize a new instance
      #
      # @param  [Sandbox] sandbox @see #sandbox
      # @param  [Podfile] podfile @see #podfile
      # @param  [Lockfile, nil] lockfile @see #lockfile
      # @param  [Array<Source>] plugin_sources @see #plugin_sources
      # @param  [Boolean] has_dependencies @see #has_dependencies
      # @param  [Hash, Boolean, nil] pods_to_update @see #pods_to_update
      # @param  [Source::Manager] sources_manager @see #sources_manager
      #
      def initialize(sandbox, podfile, lockfile = nil, plugin_sources = nil, has_dependencies = true,
                     pods_to_update = false, sources_manager = Source::Manager.new(config.repos_dir))
        @sandbox  = sandbox
        @podfile  = podfile
        @lockfile = lockfile
        @plugin_sources = plugin_sources
        @has_dependencies = has_dependencies
        @pods_to_update = pods_to_update
        @installation_options = podfile.installation_options
        @podfile_dependency_cache = PodfileDependencyCache.from_podfile(podfile)
        @sources_manager = sources_manager
        @path_lists = {}
        @result = nil
        @cached_specs_by_target = {}
        @cached_aggregate_targets = {}
        @cached_pod_targets = {}
      end

      # Performs the analysis.
      #
      # The Podfile and the Lockfile provide the information necessary to
      # compute which specification should be installed. The manifest of the
      # sandbox returns which specifications are installed.
      #
      # @param  [Boolean] allow_fetches
      #         whether external sources may be fetched
      #
      # @return [AnalysisResult]
      #
      def analyze(allow_fetches = true)
        return @result if @result
        validate_podfile!
        validate_lockfile_version!
        if installation_options.integrate_targets?
          target_inspections = inspect_targets_to_integrate
        else
          verify_platforms_specified!
          target_inspections = {}
        end
        podfile_state = generate_podfile_state

        store_existing_checkout_options
        if allow_fetches == :outdated
          # special-cased -- we're only really resolving for outdated, rather than doing a full analysis
        elsif allow_fetches == true
          fetch_external_sources(podfile_state)
        elsif !dependencies_to_fetch(podfile_state).all?(&:local?)
          raise Informative, 'Cannot analyze without fetching dependencies since the sandbox is not up-to-date. Run `pod install` to ensure all dependencies have been fetched.' \
            "\n    The missing dependencies are:\n    \t#{dependencies_to_fetch(podfile_state).reject(&:local?).join("\n    \t")}"
        end

        locked_dependencies = generate_version_locking_dependencies(podfile_state)
        resolver_specs_by_target = resolve_dependencies(locked_dependencies)
        validate_platforms(resolver_specs_by_target)
        specifications = generate_specifications(resolver_specs_by_target)
        aggregate_targets, pod_targets = generate_targets(resolver_specs_by_target, target_inspections)
        sandbox_state = generate_sandbox_state(specifications)
        
        # Optimize specs_by_target generation with caching
        specs_by_target = generate_specs_by_target(resolver_specs_by_target)
        specs_by_source = generate_specs_by_source(resolver_specs_by_target)
        
        @result = AnalysisResult.new(podfile_state, specs_by_target, specs_by_source, specifications, sandbox_state,
                                     aggregate_targets, pod_targets, @podfile_dependency_cache)
      end

      # Updates the git source repositories.
      #
      def update_repositories
        sources.each do |source|
          if source.updateable?
            sources_manager.update(source.name, true)
          else
            UI.message "Skipping `#{source.name}` update because the repository is not an updateable repository."
          end
        end
      end

      #-------------------------------------------------------------------------#

      private

      # @!group Private methods

      # Optimized method to generate specs_by_target with caching
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @return [Hash] The specifications by target.
      #
      def generate_specs_by_target(resolver_specs_by_target)
        cache_key = resolver_specs_by_target.hash
        @cached_specs_by_target[cache_key] ||= resolver_specs_by_target.each_with_object({}) do |rspecs_by_target, hash|
          hash[rspecs_by_target[0]] = rspecs_by_target[1].map(&:spec)
        end
      end

      # Optimized method to generate specs_by_source with caching
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @return [Hash] The specifications by source.
      #
      def generate_specs_by_source(resolver_specs_by_target)
        cache_key = resolver_specs_by_target.hash
        @cached_specs_by_source ||= {}
        @cached_specs_by_source[cache_key] ||= begin
          specs_by_source = Hash[resolver_specs_by_target.values.flatten(1).group_by(&:source).map do |source, specs|
            [source, specs.map(&:spec).uniq]
          end]
          sources.each { |s| specs_by_source[s] ||= [] }
          specs_by_source
        end
      end

      # @return [Array<Source>] The sources that should be used for the
      #         resolution.
      #
      def sources
        @sources ||= begin
          if has_dependencies?
            if plugin_sources
              plugin_sources
            else
              sources_manager.all
            end
          else
            []
          end
        end
      end

      # @return [Boolean] Whether the analyzer is in update mode.
      #
      def update_mode?
        pods_to_update != nil
      end

      # @return [Symbol] The update mode for the analyzer.
      #
      def update_mode
        if !pods_to_update
          :none
        elsif pods_to_update == true
          :all
        else
          :selected
        end
      end

      # @return [Array<Dependency>] The dependencies from the Podfile.
      #
      def podfile_dependencies
        @podfile_dependency_cache.podfile_dependencies
      end

      # Validates the Podfile.
      #
      # @return [void]
      #
      def validate_podfile!
        validator = Installer::PodfileValidator.new(podfile, @podfile_dependency_cache)
        validator.validate!
      end

      # Validates the Lockfile version.
      #
      # @return [void]
      #
      def validate_lockfile_version!
        if lockfile && lockfile.cocoapods_version > Version.new(VERSION)
          raise Informative, 'The version of CocoaPods used to generate the lockfile ' \
            "(#{lockfile.cocoapods_version}) is higher than the version of the current executable (#{VERSION}). " \
            'Incompatibility issues may arise.'
        end
      end

      # Generates the Podfile state.
      #
      # @return [SpecsState] The Podfile state.
      #
      def generate_podfile_state
        if lockfile
          LockingDependencyAnalyzer.generate_state_from_lockfile(lockfile, podfile_dependencies)
        else
          SpecsState.new
        end
      end

      # Generates the aggregate targets and pod targets.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @return [Array<Array<AggregateTarget>, Array<PodTarget>>] The aggregate targets and pod targets.
      #
      def generate_targets(resolver_specs_by_target, target_inspections)
        resolver_specs_by_target = resolver_specs_by_target.reject { |td, _| td.abstract? && !td.platform }
        aggregate_targets = generate_aggregate_targets(resolver_specs_by_target, target_inspections)
        pod_targets = generate_pod_targets(resolver_specs_by_target, target_inspections)
        [aggregate_targets, pod_targets]
      end

      # Generates the aggregate targets.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @return [Array<AggregateTarget>] The aggregate targets.
      #
      def generate_aggregate_targets(resolver_specs_by_target, target_inspections)
        cache_key = [resolver_specs_by_target.hash, target_inspections.hash]
        @cached_aggregate_targets[cache_key] ||= resolver_specs_by_target.keys.map do |target_definition|
          next if target_definition.abstract? && !target_definition.platform
          pod_targets_by_target_definition = group_pod_targets_by_target_definition(pod_targets, resolver_specs_by_target)
          generate_aggregate_target(target_definition, target_inspections, pod_targets_by_target_definition)
        end.compact
      end

      # Generates an aggregate target.
      #
      # @param  [TargetDefinition] target_definition
      #         The target definition.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @param  [Hash] pod_targets_by_target_definition
      #         The pod targets by target definition.
      #
      # @return [AggregateTarget] The aggregate target.
      #
      def generate_aggregate_target(target_definition, target_inspections, pod_targets_by_target_definition)
        if installation_options.integrate_targets?
          target_inspection = target_inspections[target_definition]
          AggregateTarget.new(target_definition, sandbox, target_inspection, pod_targets_by_target_definition[target_definition])
        else
          AggregateTarget.new(target_definition, sandbox, nil, [])
        end
      end

      # Groups pod targets by target definition.
      #
      # @param  [Array<PodTarget>] pod_targets
      #         The pod targets.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @return [Hash] The pod targets grouped by target definition.
      #
      def group_pod_targets_by_target_definition(pod_targets, resolver_specs_by_target)
        pod_targets_by_target_definition = Hash.new { |h, td| h[td] = [] }
        pod_targets.each do |target|
          target.target_definitions.each do |td|
            pod_targets_by_target_definition[td] << target
          end
        end
        pod_targets_by_target_definition
      end

      # Generates the pod targets.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @return [Array<PodTarget>] The pod targets.
      #
      def generate_pod_targets(resolver_specs_by_target, target_inspections)
        cache_key = [resolver_specs_by_target.hash, target_inspections.hash]
        @cached_pod_targets[cache_key] ||= begin
          if installation_options.deduplicate_targets?
            specs_by_target = resolver_specs_by_target.each_with_object({}) do |rspecs_by_target, hash|
              hash[rspecs_by_target[0]] = rspecs_by_target[1].map(&:spec)
            end
            distinct_targets = specs_by_target.each_with_object({}) do |dependency, hash|
              dependent_specs = dependency[1]
              dependent_specs.group_by(&:root).each do |root_spec, resolver_specs|
                hash[root_spec] = resolver_specs
              end
            end
            generate_pod_targets_from_specs(distinct_targets, target_inspections)
          else
            generate_pod_targets_from_specs(resolver_specs_by_target, target_inspections)
          end
        end
      end

      # Generates pod targets from specifications.
      #
      # @param  [Hash] specs_by_target
      #         The specifications by target.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @return [Array<PodTarget>] The pod targets.
      #
      def generate_pod_targets_from_specs(specs_by_target, target_inspections)
        pod_targets = []
        specs_by_target.each do |target_definition, specs|
          next if target_definition.abstract? && !target_definition.platform
          target_inspection = target_inspections[target_definition]
          pod_targets.concat(generate_pod_targets_for_target_definition(target_definition, specs, target_inspection))
        end
        pod_targets
      end

      # Generates pod targets for a target definition.
      #
      # @param  [TargetDefinition] target_definition
      #         The target definition.
      #
      # @param  [Array<Specification>] specs
      #         The specifications.
      #
      # @param  [TargetInspectionResult] target_inspection
      #         The target inspection.
      #
      # @return [Array<PodTarget>] The pod targets.
      #
      def generate_pod_targets_for_target_definition(target_definition, specs, target_inspection)
        pod_targets = []
        specs.group_by(&:root).each do |root_spec, dependent_specs|
          pod_targets << generate_pod_target([target_definition], :library, target_inspection, dependent_specs)
        end
        pod_targets
      end

      # Generates a pod target.
      #
      # @param  [Array<TargetDefinition>] target_definitions
      #         The target definitions.
      #
      # @param  [Symbol] build_type
      #         The build type.
      #
      # @param  [Hash] target_inspections
      #         The target inspections.
      #
      # @param  [Array<Specification>] specs
      #         The specifications.
      #
      # @param  [String] scope_suffix
      #         The scope suffix.
      #
      # @param  [String] swift_version
      #         The Swift version.
      #
      # @return [PodTarget] The pod target.
      #
      def generate_pod_target(target_definitions, build_type, target_inspections, specs, scope_suffix: nil,
                              swift_version: nil)
        target_inspections = target_inspections.select { |t, _| target_definitions.include?(t) }.values
        platform = determine_platform(specs, target_definitions, build_type)
        swift_version ||= determine_swift_version(specs.first, target_definitions)
        file_accessors = create_file_accessors(specs, platform)
        PodTarget.new(target_definitions, build_type, target_inspections, specs, platform, file_accessors, swift_version, scope_suffix)
      end

      # Creates file accessors for specifications.
      #
      # @param  [Array<Specification>] specs
      #         The specifications.
      #
      # @param  [Platform] platform
      #         The platform.
      #
      # @return [Array<Sandbox::FileAccessor>] The file accessors.
      #
      def create_file_accessors(specs, platform)
        name = specs.first.name
        path_list = path_list_for_pod(name)
        specs.map { |spec| Sandbox::FileAccessor.new(path_list, spec, platform) }
      end

      # Determines the platform for specifications.
      #
      # @param  [Array<Specification>] specs
      #         The specifications.
      #
      # @param  [Array<TargetDefinition>] target_definitions
      #         The target definitions.
      #
      # @param  [Symbol] build_type
      #         The build type.
      #
      # @return [Platform] The platform.
      #
      def determine_platform(specs, target_definitions, build_type)
        library_specs = specs.select(&:library_specification?)
        if library_specs.empty?
          target_definitions.first.platform
        else
          library_specs.first.platform
        end
      end

      # Determines the Swift version for a specification.
      #
      # @param  [Specification] spec
      #         The specification.
      #
      # @param  [Array<TargetDefinition>] target_definitions
      #         The target definitions.
      #
      # @return [String] The Swift version.
      #
      def determine_swift_version(spec, target_definitions)
        if spec.swift_versions.empty?
          target_definitions.first.swift_version
        else
          spec.swift_versions.first
        end
      end

      # Determines the build type for a specification.
      #
      # @param  [Specification] spec
      #         The specification.
      #
      # @param  [Symbol] target_definition_build_type
      #         The target definition build type.
      #
      # @return [Symbol] The build type.
      #
      def determine_build_type(spec, target_definition_build_type)
        if target_definition_build_type.framework?
          :framework
        elsif spec.library_specification?
          :library
        else
          :framework
        end
      end

      # Generates version locking dependencies.
      #
      # @param  [SpecsState] podfile_state
      #         The Podfile state.
      #
      # @return [Array<Dependency>] The locked dependencies.
      #
      def generate_version_locking_dependencies(podfile_state)
        if update_mode == :all || !lockfile
          []
        else
          LockingDependencyAnalyzer.generate_version_locking_dependencies(lockfile, podfile_state)
        end
      end

      # Fetches external sources.
      #
      # @param  [SpecsState] podfile_state
      #         The Podfile state.
      #
      # @return [void]
      #
      def fetch_external_sources(podfile_state)
        verify_no_pods_with_different_sources!
        dependencies_to_fetch(podfile_state).each do |dependency|
          fetch_external_source(dependency, true)
        end
      end

      # Verifies that no pods have different sources.
      #
      # @return [void]
      #
      def verify_no_pods_with_different_sources!
        deps_with_different_sources = podfile_dependencies.group_by(&:root_name).
          select { |_root_name, deps| deps.map(&:external_source).compact.uniq.count > 1 }
        unless deps_with_different_sources.empty?
          raise Informative, 'The following dependencies are using different sources. ' \
            'CocoaPods does not support this and it may lead to issues with the Podfile.lock:' \
            "\n\n#{deps_with_different_sources.map { |root_name, deps| "  #{root_name} (#{deps.map(&:external_source).join(', ')})" }.join("\n")}"
        end
      end

      # Fetches an external source.
      #
      # @param  [Dependency] dependency
      #         The dependency.
      #
      # @param  [Boolean] use_lockfile_options
      #         Whether to use lockfile options.
      #
      # @return [void]
      #
      def fetch_external_source(dependency, use_lockfile_options)
        source = if use_lockfile_options && lockfile && checkout_options = lockfile.checkout_options_for_pod_named(dependency.root_name)
                   dependency.external_source.merge(checkout_options)
                 else
                   dependency.external_source
                 end
        ExternalSources.from_dependency(dependency, source).pre_download
      end

      # Returns the dependencies that need to be fetched.
      #
      # @param  [SpecsState] podfile_state
      #         The Podfile state.
      #
      # @return [Array<Dependency>] The dependencies to fetch.
      #
      def dependencies_to_fetch(podfile_state)
        @deps_to_fetch ||= begin
          if update_mode == :all
            podfile_dependencies.select(&:external_source)
          elsif update_mode == :selected
            podfile_dependencies.select { |dep| pods_to_update.include?(dep.root_name) && dep.external_source }
          else
            podfile_dependencies.select { |dep| checkout_requires_update?(dep) && dep.external_source }
          end
        end
      end

      # Checks if a checkout requires an update.
      #
      # @param  [Dependency] dependency
      #         The dependency.
      #
      # @return [Boolean] Whether the checkout requires an update.
      #
      def checkout_requires_update?(dependency)
        return true unless lockfile && sandbox.manifest
        return true unless lockfile.version_1?
        return true unless checkout_options = lockfile.checkout_options_for_pod_named(dependency.root_name)
        checkout_options != dependency.external_source
      end

      # Returns the pods that need to be fetched.
      #
      # @param  [SpecsState] podfile_state
      #         The Podfile state.
      #
      # @return [Array<String>] The pods to fetch.
      #
      def pods_to_fetch(podfile_state)
        @pods_to_fetch ||= begin
          if update_mode == :all
            podfile_dependencies.select(&:external_source).map(&:root_name)
          elsif update_mode == :selected
            pods_to_update & podfile_dependencies.select(&:external_source).map(&:root_name)
          else
            dependencies_to_fetch(podfile_state).map(&:root_name)
          end
        end
      end

      # Stores existing checkout options.
      #
      # @return [void]
      #
      def store_existing_checkout_options
        return unless lockfile
        podfile_dependencies.select(&:external_source).each do |dep|
          if checkout_options = lockfile.checkout_options_for_pod_named(dep.root_name)
            dep.external_source.merge!(checkout_options)
          end
        end
      end

      # Resolves dependencies.
      #
      # @param  [Array<Dependency>] locked_dependencies
      #         The locked dependencies.
      #
      # @return [Hash] The resolver specifications by target.
      #
      def resolve_dependencies(locked_dependencies)
        duplicate_dependencies = podfile_dependencies.group_by(&:name).
          select { |_name, deps| deps.count > 1 }
        unless duplicate_dependencies.empty?
          raise Informative, 'The following dependencies are duplicated in the Podfile:' \
            "\n\n#{duplicate_dependencies.map { |name, deps| "  #{name} (#{deps.map(&:external_source).join(', ')})" }.join("\n")}"
        end

        resolver = Resolver.new(sandbox, podfile, locked_dependencies, sources, specs_updated?,
                               podfile_dependency_cache: @podfile_dependency_cache,
                               sources_manager: sources_manager)
        resolver.resolve
      end

      # Validates platforms.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @return [void]
      #
      def validate_platforms(resolver_specs_by_target)
        resolver_specs_by_target.each do |target, specs|
          specs.each do |spec|
            unless spec.supported_on_platform?(target.platform)
              raise Informative, "The platform of the target `#{target.name}` (#{target.platform}) is not compatible with `#{spec.name}` which has a minimum deployment target of #{spec.platforms}"
            end
          end
        end
      end

      # Generates specifications.
      #
      # @param  [Hash] resolver_specs_by_target
      #         The resolver specifications by target.
      #
      # @return [Array<Specification>] The specifications.
      #
      def generate_specifications(resolver_specs_by_target)
        resolver_specs_by_target.values.flatten.map(&:spec).uniq
      end

      # Generates sandbox state.
      #
      # @param  [Array<Specification>] specifications
      #         The specifications.
      #
      # @return [Sandbox::State] The sandbox state.
      #
      def generate_sandbox_state(specifications)
        sandbox_state = nil
        if sandbox.manifest
          sandbox_state = SandboxAnalyzer.analyze(sandbox, specifications)
        end
        sandbox_state
      end

      # Returns whether specs are updated.
      #
      # @return [Boolean] Whether specs are updated.
      #
      def specs_updated?
        @specs_updated ||= begin
          if has_dependencies?
            sources.any?(&:updateable?)
          else
            false
          end
        end
      end

      # Verifies that platforms are specified.
      #
      # @return [void]
      #
      def verify_platforms_specified!
        return if installation_options.integrate_targets?
        podfile.target_definition_list.each do |target_definition|
          unless target_definition.platform
            raise Informative, "The target `#{target_definition.name}` doesn't have a platform specified. " \
              'CocoaPods does not support this and it may lead to issues with the Podfile.lock'
          end
        end
      end

      # Inspects targets to integrate.
      #
      # @return [Hash] The target inspections.
      #
      def inspect_targets_to_integrate
        inspection_result = {}
        podfile.target_definition_list.each do |target_definition|
          next if target_definition.abstract?
          inspection_result[target_definition] = TargetInspector.new(target_definition).compute_targets
        end
        inspection_result
      end

      # Returns the path list for a pod.
      #
      # @param  [String] pod_name
      #         The pod name.
      #
      # @return [Sandbox::PathList] The path list.
      #
      def path_list_for_pod(pod_name)
        @path_lists[pod_name] ||= Sandbox::PathList.new(sandbox.pod_dir(pod_name))
      end
    end
  end
end
