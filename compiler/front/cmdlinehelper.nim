#
#
#           The Nim Compiler
#        (c) Copyright 2018 Nim contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Helpers for binaries that use compiler passes, e.g.: nim, nimsuggest, nimfix

import
  std/[
    os
  ],
  std/options as std_options,
  compiler/ast/[
    ast_idgen,
    idents,
    reports
  ],
  compiler/modules/[
    modulegraphs
  ],
  compiler/front/[
    nimconf,
    commands,
    msgs,
    options,
    condsyms
  ],
  compiler/utils/[
    pathutils,
    idioms
  ],
  compiler/backend/[
    extccomp
  ]

proc prependCurDir*(f: AbsoluteFile): AbsoluteFile =
  when defined(unix):
    if os.isAbsolute(f.string): result = f
    else: result = AbsoluteFile("./" & f.string)
  else:
    result = f

type
  NimProg* = ref object
    suggestMode*: bool
    supportsStdinFile*: bool
    processCmdLine*: proc(pass: TCmdLinePass, cmd: string; config: ConfigRef)

proc handleConfigEvent(
    conf: ConfigRef,
    evt: ConfigFileEvent,
    reportFrom: InstantiationInfo,
    eh: TErrorHandling = doNothing
  ) =
  # REFACTOR: this is a temporary bridge into existing reporting

  let kind =
    case evt.kind
    of cekParseExpectedX, cekParseExpectedCloseX:
      # xxx: rlexExpectedToken is not a "lexer" error, but a misguided
      #      attempt at code reuse -- fix after reporting is untangled.
      rlexExpectedToken
    of cekParseExpectedIdent:
      rparIdentExpected
    of cekInvalidDirective:
      rlexCfgInvalidDirective
    of cekWriteConfig:
      rintNimconfWrite
    of cekDebugTrace:
      rdbgCfgTrace
    of cekInternalError:
      rintIce
    of cekLexerErrorDiag, cekLexerWarningDiag, cekLexerHintDiag:
      evt.lexerDiag.kind.lexDiagToLegacyReportKind
    of cekDebugReadStart:
      rdbgStartingConfRead
    of cekDebugReadStop:
      rdbgFinishedConfRead
    of cekProgressConfStart:
      rextConf

  let rep =
    case evt.kind
    of cekInternalError, cekLexerErrorDiag, cekLexerWarningDiag,
        cekLexerHintDiag:
      evt.lexerDiag.lexerDiagToLegacyReport
    else:
      case kind
      of rlexCfgInvalidDirective:
        Report(
          category: repLexer,
          lexReport: LexerReport(
            location: std_options.some evt.location,
            reportInst: evt.instLoc.toReportLineInfo,
            msg: evt.msg,
            kind: kind))
      of rparIdentExpected:
        Report(
          category: repParser,
          parserReport: ParserReport(
            location: std_options.some evt.location,
            reportInst: evt.instLoc.toReportLineInfo,
            msg: evt.msg,
            kind: kind))
      of rintNimconfWrite:
        Report(
          category: repInternal,
          internalReport: InternalReport(
            location: std_options.some evt.location,
            reportInst: evt.instLoc.toReportLineInfo,
            msg: evt.msg,
            kind: kind))
      of rdbgCfgTrace:
        Report(
          category: repDebug,
          debugReport: DebugReport(
            location: std_options.some evt.location,
            reportInst: evt.instLoc.toReportLineInfo,
            kind: kind,
            str: evt.msg))
      of rdbgStartingConfRead, rdbgFinishedConfRead:
        Report(
          category: repDebug,
          debugReport: DebugReport(
            reportInst: evt.instLoc.toReportLineInfo,
            kind: kind,
            filename: evt.msg))
      of rextConf:
        Report(
          category: repExternal,
          externalReport: ExternalReport(
            reportInst: evt.instLoc.toReportLineInfo,
            kind: kind,
            msg: evt.msg))
      else:
        unreachable("handleConfigEvent unexpected kind: " & $kind)
  
  handleReport(conf, rep, reportFrom, eh)

proc initDefinesProg*(self: NimProg, conf: ConfigRef, name: string) =
  condsyms.initDefines(conf.symbols)
  defineSymbol conf, name

proc processCmdLineAndProjectPath*(self: NimProg, conf: ConfigRef, cmd: string = "") =
  self.processCmdLine(passCmd1, cmd, conf)
  if conf.projectIsCmd and conf.projectName in ["-", ""]:
    handleCmdInput(conf)
  elif self.supportsStdinFile and conf.projectName == "-":
    handleStdinInput(conf)
  elif conf.projectName != "":
    setFromProjectName(conf, conf.projectName)
  else:
    conf.projectPath = AbsoluteDir canonicalizePath(conf, AbsoluteFile getCurrentDir())

proc loadConfigs*(
  cfg: RelativeFile, cache: IdentCache,
  conf: ConfigRef, idgen: IdGenerator) {.inline.} =
  ## wrapper around `nimconf.loadConfigs` to connect to legacy reporting
  loadConfigs(cfg, cache, conf, idgen, handleConfigEvent)

proc loadConfigsAndProcessCmdLine*(self: NimProg, cache: IdentCache; conf: ConfigRef;
                                   graph: ModuleGraph): bool =
  ## Load all the necessary configuration files and command-line options.
  ## Main entry point for configuration processing.
  if self.suggestMode:
    conf.setCmd cmdIdeTools
  if conf.cmd == cmdNimscript:
    incl(conf, optWasNimscript)

  # load all config files
  loadConfigs(DefaultConfig, cache, conf, graph.idgen)

  if not self.suggestMode:
    let scriptFile = conf.projectFull.changeFileExt("nims")
    # 'nim foo.nims' means to just run the NimScript file and do nothing more:
    if fileExists(scriptFile) and scriptFile == conf.projectFull:
      if conf.cmd == cmdNone: conf.setCmd cmdNimscript
      if conf.cmd == cmdNimscript: return false
  # now process command line arguments again, because some options in the
  # command line can overwrite the config file's settings
  extccomp.initVars(conf)
  self.processCmdLine(passCmd2, "", conf)
  if conf.cmd == cmdNone:
    localReport(conf, ExternalReport(kind: rextCommandMissing))

  graph.suggestMode = self.suggestMode
  return true

proc loadConfigsAndRunMainCommand*(
    self: NimProg, cache: IdentCache; conf: ConfigRef; graph: ModuleGraph): bool =

  ## Alias for loadConfigsAndProcessCmdLine, here for backwards compatibility
  loadConfigsAndProcessCmdLine(self, cache, conf, graph)
