#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

require_relative "../worker/protected_owner_notebook"

def assert(value, message)
  raise message unless value
end

helper = RemoteWork::ProtectedOwnerNotebook.new
arguments, stdin_data = helper.invocation({
  "action" => "recall", "query" => "两头乌", "max_results" => 2
})
assert(arguments == ["recall", "--scope", "notebook", "--query", "两头乌", "--max-results", "2"],
       "notebook recall escaped its fixed scope")
assert(stdin_data.empty?, "notebook recall unexpectedly forwarded stdin")

arguments, stdin_data = helper.invocation({
  "action" => "remember", "text" => "使用统一 Air Worker", "category" => "decision", "project_id" => "two-head-wu"
})
assert(arguments == ["remember", "--category", "decision", "--source", "owner-air", "--project-id", "two-head-wu"],
       "notebook remember invocation drifted")
assert(stdin_data == "使用统一 Air Worker", "notebook remember did not use stdin for text")

begin
  helper.invocation({ "action" => "remember", "text" => "x", "path" => "/home/example/private" })
  raise "protected notebook accepted an arbitrary path"
rescue RuntimeError => error
  assert(error.message.include?("unknown fields"), "protected notebook rejected a path for the wrong reason")
end

record_id = "pm-20260905T212000-0123abcd"
output = helper.project_output("remember", {
  "schema" => "two-head-wu.personal-memory.remember.v1",
  "id" => record_id,
  "stored" => true,
  "path" => "memory/explicit.md",
  "category" => "decision",
  "project_id" => "two-head-wu"
})
assert(output.fetch("schema") == "two-head-wu.personal-memory.owner-air.v1", "protected notebook output schema drifted")
assert(output.fetch("result").fetch("id") == record_id, "protected notebook lost the record id")
assert(!JSON.generate(output).include?("path"), "protected notebook exposed a storage path")

recall = helper.project_output("recall", {
  "schema" => "two-head-wu.personal-memory.recall.v1",
  "scope" => "notebook",
  "query" => "Air",
  "results" => [{
    "id" => record_id, "category" => "decision", "fact" => "Air 使用统一权限模型",
    "project_id" => "two-head-wu", "score" => 110, "private_extra" => "must-not-pass"
  }]
})
assert(recall.dig("result", "results", 0).keys.sort == %w[category fact id project_id score],
       "protected notebook recall output was not projected through the exact whitelist")

puts "protected owner notebook tests ok"
