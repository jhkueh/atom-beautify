Promise = require('bluebird')
_ = require('lodash')
which = require('which')
spawn = require('child_process').spawn
path = require('path')
semver = require('semver')
shellEnv = require('shell-env')

parentConfigKey = "atom-beautify.executables"

module.exports = class Executable

  name: null
  cmd: null
  key: null
  homepage: null
  installation: null
  versionArgs: ['--version']
  versionParse: (text) -> semver.clean(text)
  versionRunOptions: {}
  versionsSupported: '>= 0.0.0'

  constructor: (options) ->
    # Validation
    if !options.cmd?
      throw new Error("The command (i.e. cmd property) is required for an Executable.")
    @name = options.name
    @cmd = options.cmd
    @key = @cmd.split('-').join('_')
    @homepage = options.homepage
    @installation = options.installation
    if options.version?
      versionOptions = options.version
      @versionArgs = versionOptions.args if versionOptions.args
      @versionParse = versionOptions.parse if versionOptions.parse
      @versionRunOptions = versionOptions.runOptions if versionOptions.runOptions
      @versionsSupported = versionOptions.supported if versionOptions.supported
    @setupLogger()

  init: () ->
    Promise.all([
      @loadVersion()
    ])
      .then(() => @verbose("Done init of #{@name}"))
      .then(() => @)

  ###
  Logger instance
  ###
  logger: null
  ###
  Initialize and configure Logger
  ###
  setupLogger: ->
    @logger = require('../logger')("#{@name} Executable")
    for key, method of @logger
      @[key] = method
    @verbose("#{@name} executable logger has been initialized.")

  isInstalled = null
  version = null
  loadVersion: (force = false) ->
    @verbose("loadVersion", @version, force)
    if force or !@version?
      @verbose("Loading version without cache")
      @runVersion()
        .then((text) => @versionParse(text))
        .then((version) ->
          valid = Boolean(semver.valid(version))
          if not valid
            throw new Error("Version is not valid: "+version)
          version
        )
        .then((version) =>
          @isInstalled = true
          @version = version
        )
        .then((version) =>
          @verbose("#{@cmd} version: #{version}")
          version
        )
        .catch((error) =>
          @isInstalled = false
          @error(error)
          Promise.reject(@commandNotFoundError())
        )
    else
      @verbose("Loading cached version")
      Promise.resolve(@version)

  runVersion: () ->
    @run(@versionArgs, @versionRunOptions)
      .then((version) =>
        @verbose("Version: " + version)
        version
      )

  isSupported: () ->
    @isVersion(@versionsSupported)

  isVersion: (range) ->
    semver.satisfies(@version, range)

  getConfig: () ->
    atom?.config.get("#{parentConfigKey}.#{@key}") or {}

  ###
  Run command-line interface command
  ###
  run: (args, options = {}) ->
    @debug("Run: ", @cmd, args, options)
    { cwd, ignoreReturnCode, help, onStdin, returnStderr } = options
    # Flatten args first
    args = _.flatten(args)
    exeName = @cmd
    config = @getConfig()

    # Resolve executable and all args
    Promise.all([@shellEnv(), Promise.all(args)])
      .then(([env, args]) =>
        @debug('exeName, args:', exeName, args)

        # Get PATH and other environment variables
        if config and config.path
          exePath = config.path
        else
          exePath = @which(exeName)
        Promise.all([exeName, args, env, exePath])
      )
      .then(([exeName, args, env, exePath]) =>
        @debug('exePath:', exePath)
        @debug('env:', env)
        @debug('args', args)

        exe = exePath ? exeName
        spawnOptions = {
          cwd: cwd
          env: env
        }

        @spawn(exe, args, spawnOptions, onStdin)
          .then(({returnCode, stdout, stderr}) =>
            @verbose('spawn result, returnCode', returnCode)
            @verbose('spawn result, stdout', stdout)
            @verbose('spawn result, stderr', stderr)

            # If return code is not 0 then error occured
            if not ignoreReturnCode and returnCode isnt 0
              # operable program or batch file
              windowsProgramNotFoundMsg = "is not recognized as an internal or external command"

              @verbose(stderr, windowsProgramNotFoundMsg)

              if @isWindows() and returnCode is 1 and stderr.indexOf(windowsProgramNotFoundMsg) isnt -1
                throw @commandNotFoundError(exeName, help)
              else
                throw new Error(stderr)
            else
              if returnStderr
                stderr
              else
                stdout
          )
          .catch((err) =>
            @debug('error', err)

            # Check if error is ENOENT (command could not be found)
            if err.code is 'ENOENT' or err.errno is 'ENOENT'
              throw @commandNotFoundError(exeName, help)
            else
              # continue as normal error
              throw err
          )
      )

  ###
  Spawn
  ###
  spawn: (exe, args, options, onStdin) ->
    # Remove undefined/null values
    args = _.without(args, undefined)
    args = _.without(args, null)

    return new Promise((resolve, reject) =>
      @debug('spawn', exe, args)

      cmd = spawn(exe, args, options)
      stdout = ""
      stderr = ""

      cmd.stdout.on('data', (data) ->
        stdout += data
      )
      cmd.stderr.on('data', (data) ->
        stderr += data
      )
      cmd.on('close', (returnCode) =>
        @debug('spawn done', returnCode, stderr, stdout)
        resolve({returnCode, stdout, stderr})
      )
      cmd.on('error', (err) =>
        @debug('error', err)
        reject(err)
      )

      onStdin cmd.stdin if onStdin
    )


  ###
  Add help to error.description

  Note: error.description is not officially used in JavaScript,
  however it is used internally for Atom Beautify when displaying errors.
  ###
  commandNotFoundError: (exe, help) ->
    exe ?= @name or @cmd
    # help ?= {
    #   program: @cmd
    #   link: @installation or @homepage
    # }
    # Create new improved error
    # notify user that it may not be
    # installed or in path
    message = "Could not find '#{exe}'. \
            The program may not be installed."
    er = new Error(message)
    er.code = 'CommandNotFound'
    er.errno = er.code
    er.syscall = 'beautifier::run'
    er.file = exe
    if help?
      if typeof help is "object"
        # Basic notice
        helpStr = "See #{help.link} for program \
                            installation instructions.\n"
        # Help to configure Atom Beautify for program's path
        helpStr += "You can configure Atom Beautify \
                    with the absolute path \
                    to '#{help.program or exe}' by setting \
                    '#{help.pathOption}' in \
                    the Atom Beautify package settings.\n" if help.pathOption
        # Optional, additional help
        helpStr += help.additional if help.additional
        # Common Help
        issueSearchLink =
          "https://github.com/Glavin001/atom-beautify/\
                  search?q=#{exe}&type=Issues"
        docsLink = "https://github.com/Glavin001/\
                  atom-beautify/tree/master/docs"
        helpStr += "Your program is properly installed if running \
                            '#{if @isWindows() then 'where.exe' \
                            else 'which'} #{exe}' \
                            in your #{if @isWindows() then 'CMD prompt' \
                            else 'Terminal'} \
                            returns an absolute path to the executable. \
                            If this does not work then you have not \
                            installed the program correctly and so \
                            Atom Beautify will not find the program. \
                            Atom Beautify requires that the program be \
                            found in your PATH environment variable. \n\
                            Note that this is not an Atom Beautify issue \
                            if beautification does not work and the above \
                            command also does not work: this is expected \
                            behaviour, since you have not properly installed \
                            your program. Please properly setup the program \
                            and search through existing Atom Beautify issues \
                            before creating a new issue. \
                            See #{issueSearchLink} for related Issues and \
                            #{docsLink} for documentation. \
                            If you are still unable to resolve this issue on \
                            your own then please create a new issue and \
                            ask for help.\n"
        er.description = helpStr
      else #if typeof help is "string"
        er.description = help
    return er


  @_envCache = null
  shellEnv: () ->
    @constructor.shellEnv()
  @shellEnv: () ->
    if @_envCache
      return Promise.resolve(@_envCache)
    else
      shellEnv()
        .then((env) =>
          @_envCache = env
        )

  ###
  Like the unix which utility.

  Finds the first instance of a specified executable in the PATH environment variable.
  Does not cache the results,
  so hash -r is not needed when the PATH changes.
  See https://github.com/isaacs/node-which
  ###
  which: (exe, options) ->
    @.constructor.which(exe, options)
  @_whichCache = {}
  @which: (exe, options = {}) ->
    if @_whichCache[exe]
      return Promise.resolve(@_whichCache[exe])
    # Get PATH and other environment variables
    @shellEnv()
      .then((env) =>
        new Promise((resolve, reject) =>
          options.path ?= env.PATH
          if @isWindows()
            # Environment variables are case-insensitive in windows
            # Check env for a case-insensitive 'path' variable
            if !options.path
              for i of env
                if i.toLowerCase() is "path"
                  options.path = env[i]
                  break

            # Trick node-which into including files
            # with no extension as executables.
            # Put empty extension last to allow for other real extensions first
            options.pathExt ?= "#{process.env.PATHEXT ? '.EXE'};"
          which(exe, options, (err, path) =>
            return resolve(exe) if err
            @_whichCache[exe] = path
            resolve(path)
          )
        )
      )

  ###
  If platform is Windows
  ###
  isWindows: () -> @constructor.isWindows()
  @isWindows: () -> new RegExp('^win').test(process.platform)