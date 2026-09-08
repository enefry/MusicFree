#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

project_file = ARGV.fetch(0, "MusicFree.xcodeproj/project.pbxproj")
spec_file = ARGV.fetch(1, "project.yml")

spec = YAML.safe_load(File.read(spec_file), aliases: true)
local_packages = spec.fetch("packages", {}).each_with_object({}) do |(name, package), result|
  next unless package.is_a?(Hash) && package["path"]

  result[name] = package.fetch("path")
end

bindings = spec.fetch("targets", {}).values.flat_map do |target|
  Array(target["dependencies"]).filter_map do |dependency|
    next unless dependency.is_a?(Hash)

    package_name = dependency["package"]
    package_path = local_packages[package_name]
    next unless package_path

    [package_path, dependency["product"] || package_name]
  end
end.uniq

contents = File.read(project_file)
updated_count = 0

bindings.each do |package_path, product_name|
  reference_pattern = /^\s*([A-F0-9]{24}) \/\* XCLocalSwiftPackageReference "#{Regexp.escape(package_path)}" \*\/ = \{$/
  reference_match = contents.match(reference_pattern)
  abort("error: Missing local package reference for #{package_path}") unless reference_match

  reference_id = reference_match[1]
  product_pattern = /^\t\t[A-F0-9]{24} \/\* #{Regexp.escape(product_name)} \*\/ = \{\n.*?^\t\t\};$/m
  product_blocks = contents.scan(product_pattern)
  product_blocks.select! do |block|
    block.include?("isa = XCSwiftPackageProductDependency;") &&
      block.include?("productName = #{product_name};")
  end
  abort("error: Missing package product dependency for #{product_name}") if product_blocks.empty?

  product_blocks.each do |block|
    package_line = "\t\t\tpackage = #{reference_id} /* XCLocalSwiftPackageReference \"#{package_path}\" */;"
    if block.include?("\n\t\t\tpackage = ")
      abort("error: Package product #{product_name} is bound to the wrong package") unless block.include?(package_line)
      next
    end

    updated_block = block.sub(
      "\t\t\tisa = XCSwiftPackageProductDependency;",
      "\t\t\tisa = XCSwiftPackageProductDependency;\n#{package_line}"
    )
    contents.sub!(block, updated_block)
    updated_count += 1
  end
end

File.write(project_file, contents) if updated_count.positive?
puts "Bound #{bindings.length} local package products (#{updated_count} updated)."
