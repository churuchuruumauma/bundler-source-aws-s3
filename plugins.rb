# frozen_string_literal: true

# Do we need to require bundler explicitly? It seems like it will be loaded
# already?
require 'bundler'
require 'fileutils'
require 'open3'

# Do we need both rubygems and rubygems/package or just rubygems/package?
require 'rubygems'
require 'rubygems/package'

class BundlerSourceAwsS3 < Bundler::Plugin::API
  source 'aws-s3'

  # Bundler plugin api, 
  def install(spec, opts)
    package = package_for(spec)
    destination = install_path.join(spec.full_name)

    mkdir_p(destination)
    package.extract_files(destination)

    # This was copied from bundler's examples, it seems like we need to write
    # the given gemspec into the extracted gem's directory. This is used to
    # calculate `loaded_from` which is used by bundler to calculate
    # `full_gem_path` for our plugin.
    spec_path = loaded_from_for(spec)
    spec_path.open('wb') { |f| f.write spec.to_ruby }

    # If we set this in `specs` can we skip this now?
    spec.loaded_from = spec_path.to_s

    post_install(spec)
  end

  # Bundler plugin api, we need to return a Bundler::Index
  def specs
    pull

    Bundler::Index.build do |index|
      packages.map(&:spec).each do |spec|
        spec.source = self

        # This isn't important on the initial install flow, but later when
        # bundler needs to load our gems, we need to provide a spec with
        # `loaded_from` set correctly.  Do we really need to verify that the
        # gemspec already exists (iow, has been installed)?
        spec_path = loaded_from_for(spec)
        if File.file?(spec_path)
          spec.loaded_from = spec_path.to_s
        end

        Bundler.rubygems.validate(spec)
        index << spec
      end
    end
  end

  # TODO What should this method actually do?
  def dependency_names_to_double_check
    []
  end

  private

  def loaded_from_for(spec)
    destination = install_path.join(spec.full_name)
    destination.join("#{spec.full_name}.gemspec")
  end

  # This path is going to be under bundler's gem_install_dir and we'll then
  # mirror the bucket/path directory structure from the source. This is where
  # we want to place our gems. This directory can hold multiple installed
  # gems.
  def install_path
    @install_path ||= gem_install_dir.join(bucket).join(path)
  end

  # This is the path to the s3 gems for our source uri. We will pull the s3
  # gems into this directory.
  def s3_gems_path
    user_bundle_path.join('bundler-source-aws-s3').join(bucket).join(path)
  end

  # Pull s3 gems from the source and store them in
  # .bundle/bundler-source-aws-s3/<bucket>/<path>. We will install, etc, from
  # this directory.
  def pull
    # We only want to pull once in a single bundler run.
    return @pull if defined?(@pull)

    mkdir_p(s3_gems_path)

    output, status = Open3.capture2e(sync_cmd)

    @pull = status.success?
  end

  # Produces a list of Gem::Package for the s3 gems.
  def packages
    Dir.entries(s3_gems_path.join('gems')).
      map { |entry| s3_gems_path.join('gems').join(entry) }.
      select { |gem_path| File.file?(gem_path) }.
      map { |gem_path| Gem::Package.new(gem_path.to_s) }
  end

  # Find the Gem::Package for a given spec.
  def package_for(spec)
    packages.find { |package| package.spec.full_name == spec.full_name }
  end

  def sync_cmd
    "aws s3 sync --delete #{uri} #{s3_gems_path}"
  end

  def bucket
    URI.parse(uri).normalize.host
  end

  def path
    # Remove the leading slash from the path.
    URI.parse(uri).normalize.path[1..-1]
  end
end
