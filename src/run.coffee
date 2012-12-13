# Node.js-specific support: module loading, sourceMapping errors

fs = require 'fs'
path = require 'path'
Module = require 'module'
CoffeeScript = require './module'
{SourceMapConsumer} = require 'source-map'

# NodeJS / V8 have no support for transforming positions in stack traces using
# sourceMap, so we must monkey-patch Error to display CoffeeScript source
# positions.

# Ideally, this would happen in a way that is scalable to multiple compile-to-
# JS languages trying to do the same thing in the same NodeJS process. We can
# implement it as if there were an API, and then patch in support for that
# API. The following maybe should be in its own npm module that multiple
# compilers can include.

patched = false
patchStackTrace = ->
  return if patched
  patched = true

  # Map of filenames -> functions that return a sourceMap string.
  Module._sourceMaps = {}

  # (Assigning to a property of the Module object in the normal module cache is
  # unsuitable, because node deletes those objects from the cache if an
  # exception is thrown in the module body.)

  Error.prepareStackTrace = (err, stack) ->
    sourceFiles = {}

    getSourceMapping = (filename, line, column) ->
      mapString = Module._sourceMaps[filename]?()
      if mapString
        sourceMap = sourceFiles[filename] ?= new SourceMapConsumer mapString
        sourceMap.originalPositionFor {line, column}

    frames = for frame in stack
      break if frame.getFunction() is exports.runMain
      "  at #{formatSourcePosition frame, getSourceMapping}"

    "#{err.name}: #{err.message ? ''}\n#{frames.join '\n'}\n"

# Based on http://v8.googlecode.com/svn/tags/3.9.9/src/messages.js
# Modified to handle sourceMap
formatSourcePosition = (frame, getSourceMapping) ->
  fileName = undefined
  fileLocation = ''

  if frame.isNative()
    fileLocation = 'native'
  else if frame.isEval()
    fileName = frame.getScriptNameOrSourceURL()
    fileLocation = frame.getEvalOrigin() unless fileName
  else
    fileName = frame.getFileName()

  if fileName
    line = frame.getLineNumber()
    column = frame.getColumnNumber()

    # Check for a sourceMap position
    source = getSourceMapping fileName, line, column
    fileLocation =
      if source
        "#{fileName}:#{source.line}:#{source.column}, <js>:#{line}:#{column}"
      else
        "#{fileName}:#{line}:#{column}"

  fileLocation or= 'unknown source'

  functionName = frame.getFunction().name
  addPrefix = true
  isConstructor = frame.isConstructor()
  isMethodCall = not (frame.isToplevel() or isConstructor)
  line = ''
  if isMethodCall
    methodName = frame.getMethodName()
    line = "#{frame.getTypeName()}."
    if functionName
      line = "#{line}#{functionName} [as #{methodName}]" if methodName and methodName isnt functionName
    else
      line = "#{line}#{methodName or '<anonymous>'}"
  else if isConstructor
    line = "new #{functionName or '<anonymous>'}"
  else if functionName
    line = functionName
  else
    line = fileLocation
    addPrefix = false
  line = "#{line} (#{fileLocation})" if addPrefix
  line

# Run JavaScript as a main program - resetting process.argv and module lookup paths
exports.runMain = (csSource, jsSource, jsAst, filename) ->
  mainModule = new Module '.'
  mainModule.filename = process.argv[1] = filename

  # Set it as the main module -- this is used for require.main
  process.mainModule = mainModule

  # Add the module to the cache
  Module._cache[mainModule.filename] = mainModule

  # Assign paths for node_modules loading
  mainModule.paths = Module._nodeModulePaths path.dirname filename

  runModule mainModule, jsSource, jsAst, filename

runModule = (module, jsSource, jsAst, filename) ->
  do patchStackTrace

  Module._sourceMaps[filename] = ->
    CoffeeScript.sourceMap jsAst, filename

  module._compile jsSource, filename

require.extensions['.coffee'] = (module, filename) ->
  input = fs.readFileSync filename, 'utf8'
  csAst = CoffeeScript.parse input, raw: yes
  jsAst = CoffeeScript.compile csAst
  js = CoffeeScript.js jsAst

  runModule module, js, jsAst, filename
