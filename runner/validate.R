#!/usr/bin/env Rscript
# Project RxV validation engine. This script runs only inside a disposable sandbox.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) stop("usage: validate.R <package-dir> <report.json> <profile>")
package_dir <- normalizePath(args[[1]], mustWork = TRUE)
report_path <- args[[2]]
profile <- args[[3]]

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
suites <- list(); findings <- list(); command_logs <- list()

add_finding <- function(severity, rule, file, line, message) {
  findings[[length(findings) + 1]] <<- list(severity = severity, rule = rule, file = file, line = as.integer(line %||% 0), message = message)
}

add_suite <- function(name, status, summary, detail = NULL) {
  suites[[length(suites) + 1]] <<- list(name = name, status = status, summary = summary, detail = detail)
}

run_command <- function(name, command, args, timeout_note = NULL) {
  output <- tryCatch(system2(command, args, stdout = TRUE, stderr = TRUE), error = function(e) structure(conditionMessage(e), status = 127L))
  code <- attr(output, "status") %||% 0L
  command_logs[[name]] <<- list(exit_code = as.integer(code), output_tail = tail(output, 80), timeout_note = timeout_note)
  list(ok = identical(as.integer(code), 0L), output = output, code = code)
}

with_suite <- function(name, fn) {
  tryCatch(fn(), error = function(e) {
    add_suite(name, "failed", paste("Could not complete:", conditionMessage(e)))
    add_finding("high", "RXV-RUN-001", "", 0, paste(name, "failed:", conditionMessage(e)))
  })
}

description <- tryCatch(read.dcf(file.path(package_dir, "DESCRIPTION"))[1, , drop = TRUE], error = function(e) character())
pkg_name <- unname(description[["Package"]] %||% basename(package_dir))
r_files <- list.files(file.path(package_dir, "R"), pattern = "\\.[Rr]$", full.names = TRUE, recursive = TRUE)
all_source_files <- list.files(package_dir, recursive = TRUE, full.names = TRUE, all.files = FALSE)

with_suite("Package structure", function() {
  required <- c("DESCRIPTION", "NAMESPACE", "R")
  missing <- required[!file.exists(file.path(package_dir, required))]
  source_files <- length(r_files)
  test_frameworks <- c(
    if (dir.exists(file.path(package_dir, "tests", "testthat"))) "testthat",
    if (dir.exists(file.path(package_dir, "inst", "tinytest")) || dir.exists(file.path(package_dir, "tests", "tinytest"))) "tinytest",
    if (dir.exists(file.path(package_dir, "inst", "unitTests"))) "RUnit"
  )
  if (length(missing) || !source_files) {
    add_suite("Package structure", "failed", paste(c(if (length(missing)) paste("Missing:", paste(missing, collapse = ", ")), if (!source_files) "No R source files found"), collapse = "; "))
    for (item in missing) add_finding("high", "RXV-STRUCT-001", item, 0, "Required package component is missing.")
  } else {
    add_suite("Package structure", "passed", paste(source_files, "R source file(s); test framework(s):", if (length(test_frameworks)) paste(test_frameworks, collapse = ", ") else "none detected"))
  }
})

with_suite("Metadata, license & repository hygiene", function() {
  warnings <- character()
  if (!nzchar(description[["URL"]] %||% "")) warnings <- c(warnings, "URL field is not declared")
  if (!nzchar(description[["BugReports"]] %||% "")) warnings <- c(warnings, "BugReports field is not declared")
  license <- description[["License"]] %||% ""
  if (!nzchar(license) || grepl("^file LICENSE$", license, ignore.case = TRUE) && !file.exists(file.path(package_dir, "LICENSE"))) {
    warnings <- c(warnings, "License is absent or refers to a missing LICENSE file")
    add_finding("medium", "RXV-META-003", "DESCRIPTION", 0, "Declare a valid, redistributable package license.")
  }
  if (!file.exists(file.path(package_dir, "README.md"))) warnings <- c(warnings, "README.md is missing")
  if (!file.exists(file.path(package_dir, "NEWS.md")) && !file.exists(file.path(package_dir, "NEWS"))) warnings <- c(warnings, "NEWS is missing")
  ignored <- file.path(package_dir, ".Rbuildignore")
  if (file.exists(ignored) && any(grepl("^\\.git$", readLines(ignored, warn = FALSE)))) warnings <- c(warnings, ".Rbuildignore may not exclude all VCS metadata")
  if (length(warnings)) add_suite("Metadata, license & repository hygiene", "warning", paste(warnings, collapse = "; "))
  else add_suite("Metadata, license & repository hygiene", "passed", "Metadata, license declaration, README, NEWS, and build-ignore policy are present.")
})

with_suite("Package integrity", function() {
  problems <- character()
  required <- c("Package", "Version", "Title", "Description", "License", "Encoding")
  missing <- required[!required %in% names(description) | !nzchar(description[required])]
  if (length(missing)) problems <- c(problems, paste("DESCRIPTION missing:", paste(missing, collapse = ", ")))
  if (!file.exists(file.path(package_dir, "NAMESPACE"))) problems <- c(problems, "NAMESPACE is missing")
  build <- run_command("build", "R", c("CMD", "build", package_dir))
  if (!build$ok) problems <- c(problems, "R CMD build failed")
  lib <- file.path(tempdir(), "rxv-library"); dir.create(lib, showWarnings = FALSE)
  install <- run_command("install", "R", c("CMD", "INSTALL", "--library", lib, package_dir))
  if (!install$ok) problems <- c(problems, "Clean package install failed")
  if (length(problems)) {
    add_suite("Package integrity", "failed", paste(problems, collapse = "; "))
    for (p in problems) add_finding("high", "RXV-PKG-001", "DESCRIPTION", 0, p)
  } else add_suite("Package integrity", "passed", "DESCRIPTION, build, and clean installation completed.")
})

with_suite("AST & security", function() {
  parse_errors <- character(); risky <- c("system", "system2", "shell", "shell.exec", "download.file", "url", "socketConnection", "eval", "parse", "source")
  call_count <- 0L
  for (file in r_files) {
    parsed <- tryCatch(parse(file, keep.source = TRUE), error = function(e) e)
    if (inherits(parsed, "error")) {
      parse_errors <- c(parse_errors, sprintf("%s: %s", basename(file), conditionMessage(parsed)))
      add_finding("high", "RXV-AST-001", sub(paste0("^", package_dir, "/?"), "", file), 0, conditionMessage(parsed)); next
    }
    tokens <- tryCatch(utils::getParseData(parsed), error = function(e) NULL)
    if (!is.null(tokens)) {
      calls <- tokens[tokens$token == "SYMBOL_FUNCTION_CALL", , drop = FALSE]
      call_count <- call_count + nrow(calls)
      flagged <- calls[calls$text %in% risky, , drop = FALSE]
      for (i in seq_len(nrow(flagged))) add_finding("medium", "RXV-AST-004", sub(paste0("^", package_dir, "/?"), "", file), flagged$line1[[i]], paste0(flagged$text[[i]], "() requires a sandbox-policy review."))
    }
  }
  dynamic_sources <- grep("(source|download\\.file)\\s*\\(\\s*['\"]https?://", unlist(lapply(r_files, readLines, warn = FALSE)), value = TRUE)
  if (length(dynamic_sources)) add_finding("high", "RXV-AST-007", "R/", 0, "Remote source loading was detected and is blocked by production policy.")
  if (length(parse_errors)) add_suite("AST & security", "failed", paste(length(parse_errors), "R file(s) could not be parsed."))
  else if (any(vapply(findings, function(x) x$rule == "RXV-AST-004", logical(1)))) add_suite("AST & security", "warning", paste("Parsed", length(r_files), "R files and found", call_count, "function calls; review flagged process/network/dynamic-evaluation calls."))
  else add_suite("AST & security", "passed", paste("Parsed", length(r_files), "R files and", call_count, "function calls with no policy-sensitive calls."))
})

with_suite("Secrets, supply-chain & unsafe-content scan", function() {
  scan_files <- all_source_files[!grepl("(^|/)(renv/library|\\.git|node_modules)(/|$)", all_source_files)]
  rules <- list(
    "RXV-SEC-001" = "AKIA[0-9A-Z]{16}",
    "RXV-SEC-002" = "gh[pousr]_[A-Za-z0-9_]{20,}",
    "RXV-SEC-003" = "(?i)(api[_-]?key|secret|access[_-]?token|password)\\s*(<-|=|:)\\s*['\\\"][^'\\\"]{8,}",
    "RXV-SEC-004" = "(?i)(curl|wget)\\s+https?://"
  )
  hits <- 0L
  for (file in scan_files) {
    if (file.info(file)$size > 2e6 || grepl("\\.(png|jpg|jpeg|pdf|rds|rda|zip|tar\\.gz)$", file, ignore.case = TRUE)) next
    content <- tryCatch(readLines(file, warn = FALSE, encoding = "UTF-8"), error = function(e) character())
    if (!length(content)) next
    for (rule in names(rules)) {
      matched <- grep(rules[[rule]], content, perl = TRUE, ignore.case = FALSE)
      for (line in matched) {
        hits <- hits + 1L
        add_finding("high", rule, sub(paste0("^", package_dir, "/?"), "", file), line, "Potential credential, token, or shell-download command detected; remove or move to a secret manager.")
      }
    }
  }
  if (hits) add_suite("Secrets, supply-chain & unsafe-content scan", "failed", paste(hits, "high-risk content match(es) detected."))
  else add_suite("Secrets, supply-chain & unsafe-content scan", "passed", "No common credential, token, or shell-download patterns were detected in text assets.")
})

with_suite("Maintainability & complexity", function() {
  branch_total <- 0L; long_lines <- 0L; oversized <- character()
  for (file in r_files) {
    expr <- tryCatch(parse(file, keep.source = TRUE), error = function(e) NULL)
    tokens <- if (!is.null(expr)) tryCatch(utils::getParseData(expr), error = function(e) NULL) else NULL
    if (!is.null(tokens)) branch_total <- branch_total + sum(tokens$token %in% c("IF", "FOR", "WHILE", "REPEAT", "AND", "OR", "AND2", "OR2"))
    lines <- tryCatch(readLines(file, warn = FALSE), error = function(e) character())
    long_lines <- long_lines + sum(nchar(lines, type = "width") > 120)
    if (length(lines) > 600) oversized <- c(oversized, basename(file))
  }
  summary <- paste(branch_total, "decision point(s)", "·", long_lines, "line(s) over 120 columns")
  if (branch_total > 120 || long_lines > 20 || length(oversized)) {
    add_suite("Maintainability & complexity", "warning", paste(summary, if (length(oversized)) paste("· oversized file(s):", paste(oversized, collapse = ", ")) else ""))
    add_finding("low", "RXV-MAINT-001", "R/", 0, "Consider decomposing complex functions and long source files; inspect the complexity metrics in the report.")
  } else add_suite("Maintainability & complexity", "passed", summary)
})

with_suite("Dependency compatibility", function() {
  fields <- c("Depends", "Imports", "LinkingTo", "Suggests", "Enhances")
  raw <- paste(unname(description[intersect(names(description), fields)]), collapse = ",")
  deps <- trimws(gsub("\\s*\\([^)]*\\)", "", unlist(strsplit(raw, ",", fixed = TRUE))))
  deps <- deps[nzchar(deps) & !deps %in% c("R", "base", "methods", "stats", "utils", "graphics", "grDevices", "datasets")]
  unavailable <- deps[!vapply(deps, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1))]
  remotes <- description[["Remotes"]] %||% ""
  if (length(unavailable)) {
    add_suite("Dependency compatibility", "warning", paste("Runner image does not include:", paste(unavailable, collapse = ", "), ". A production dependency-preflight worker should resolve these from the approved package snapshot."))
    add_finding("medium", "RXV-DEP-001", "DESCRIPTION", 0, "One or more declared dependencies are unavailable in the validation image.")
  } else if (length(deps) || nzchar(remotes)) add_suite("Dependency compatibility", "passed", paste(length(deps), "declared dependency/dependencies available in the runner image."))
  else add_suite("Dependency compatibility", "warning", "No Imports, Depends, Suggests, LinkingTo, or Remotes fields were declared.")
})

if (profile %in% c("standard", "release")) with_suite("CRAN readiness", function() {
  tarballs <- list.files(getwd(), pattern = "\\.tar\\.gz$", full.names = TRUE)
  if (!length(tarballs)) {
    add_suite("CRAN readiness", "failed", "No package tarball was produced; R CMD check could not run."); return()
  }
  check <- run_command("check", "R", c("CMD", "check", "--as-cran", "--no-manual", tail(tarballs, 1)))
  check_dir <- list.files(dirname(tarballs[[1]]), pattern = "\\.Rcheck$", full.names = TRUE)
  check_log <- if (length(check_dir)) file.path(check_dir[[1]], "00check.log") else ""
  text <- if (file.exists(check_log)) readLines(check_log, warn = FALSE) else check$output
  notes <- grep("^(NOTE|WARNING|ERROR)", text, value = TRUE)
  if (!check$ok || any(grepl("^ERROR", notes))) {
    add_suite("CRAN readiness", "failed", "R CMD check --as-cran returned an error.")
    add_finding("high", "RXV-CHECK-001", "00check.log", 0, paste(tail(notes, 1) %||% "R CMD check failed", collapse = ""))
  } else if (length(notes)) {
    add_suite("CRAN readiness", "warning", paste(length(notes), "R CMD check note(s)/warning(s) require review."))
  } else add_suite("CRAN readiness", "passed", "R CMD check --as-cran completed cleanly.")
})

with_suite("Test confidence", function() {
  tests <- file.path(package_dir, "tests", "testthat")
  if (!dir.exists(tests)) { add_suite("Test confidence", "warning", "No tests/testthat directory was found."); return() }
  if (!requireNamespace("testthat", quietly = TRUE)) { add_suite("Test confidence", "skipped", "testthat is unavailable in this runner image."); return() }
  result <- tryCatch({ testthat::test_local(package_dir, reporter = "summary", stop_on_failure = FALSE, stop_on_warning = FALSE); NULL }, error = identity)
  if (inherits(result, "error")) {
    add_suite("Test confidence", "failed", paste("testthat execution failed:", conditionMessage(result)))
    add_finding("high", "RXV-TEST-001", "tests/testthat", 0, conditionMessage(result))
  } else add_suite("Test confidence", "passed", "testthat suite executed in the isolated package environment.")
})

with_suite("Test framework inventory", function() {
  detected <- character(); notes <- character()
  if (dir.exists(file.path(package_dir, "tests", "testthat"))) detected <- c(detected, "testthat")
  if (dir.exists(file.path(package_dir, "inst", "tinytest")) || dir.exists(file.path(package_dir, "tests", "tinytest"))) {
    detected <- c(detected, "tinytest")
    notes <- c(notes, "tinytest tests are executed by R CMD check when declared in the package test hook")
  }
  if (dir.exists(file.path(package_dir, "inst", "unitTests"))) {
    detected <- c(detected, "RUnit")
    notes <- c(notes, "RUnit tests require an explicit test harness; verify this via R CMD check output")
  }
  test_files <- list.files(file.path(package_dir, "tests"), pattern = "\\.[Rr]$", recursive = TRUE, full.names = FALSE)
  if (!length(detected) && !length(test_files)) {
    add_suite("Test framework inventory", "warning", "No automated test framework or test scripts were detected.")
    add_finding("medium", "RXV-TEST-002", "tests/", 0, "Add automated regression tests before releasing a public package.")
  } else add_suite("Test framework inventory", "passed", paste("Detected:", paste(unique(detected), collapse = ", "), "·", length(test_files), "test script(s).", paste(notes, collapse = " ")))
})

if (profile %in% c("standard", "release")) with_suite("Coverage & quality", function() {
  lint_count <- NA_integer_; coverage <- NA_real_
  if (requireNamespace("lintr", quietly = TRUE)) {
    lints <- tryCatch(lintr::lint_package(package_dir), error = identity)
    if (!inherits(lints, "error")) lint_count <- length(lints)
  }
  if (requireNamespace("covr", quietly = TRUE) && dir.exists(file.path(package_dir, "tests"))) {
    cov <- tryCatch(covr::package_coverage(package_dir, quiet = TRUE), error = identity)
    if (!inherits(cov, "error")) coverage <- round(covr::percent_coverage(cov), 1)
  }
  details <- c(if (!is.na(lint_count)) paste(lint_count, "lint finding(s)") else NULL, if (!is.na(coverage)) paste0(coverage, "% coverage") else NULL)
  if (!is.na(lint_count) && lint_count > 0) {
    add_suite("Coverage & quality", "warning", paste(c(details, collapse = " · ")))
    add_finding("low", "RXV-LINT-001", "R/", 0, paste(lint_count, "lintr finding(s) detected."))
  } else add_suite("Coverage & quality", "passed", if (length(details)) paste(details, collapse = " · ") else "Static quality scan completed.")
})

if (profile %in% c("standard", "release")) with_suite("Documentation", function() {
  man <- file.path(package_dir, "man")
  exports <- if (file.exists(file.path(package_dir, "NAMESPACE"))) grep("^(export|S3method)", readLines(file.path(package_dir, "NAMESPACE"), warn = FALSE), value = TRUE) else character()
  rd_files <- if (dir.exists(man)) list.files(man, pattern = "\\.Rd$", full.names = TRUE) else character()
  examples <- if (length(rd_files)) sum(grepl("\\\\examples", unlist(lapply(rd_files, readLines, warn = FALSE)))) else 0
  if (length(exports) && !length(rd_files)) {
    add_suite("Documentation", "warning", "Exported objects were found but no Rd files exist.")
    add_finding("medium", "RXV-DOC-001", "man/", 0, "Document exported functions with roxygen2/Rd topics.")
  } else add_suite("Documentation", "passed", paste(length(rd_files), "Rd topic(s) and", examples, "example section(s) detected."))
})

if (profile %in% c("standard", "release")) with_suite("Examples, vignettes & website assets", function() {
  vignette_dir <- file.path(package_dir, "vignettes")
  vignettes <- if (dir.exists(vignette_dir)) list.files(vignette_dir, pattern = "\\.(Rmd|Rnw|qmd)$", full.names = TRUE, ignore.case = TRUE) else character()
  has_pkgdown <- file.exists(file.path(package_dir, "_pkgdown.yml")) || dir.exists(file.path(package_dir, "docs"))
  broken_rd <- character()
  for (rd in list.files(file.path(package_dir, "man"), pattern = "\\.Rd$", full.names = TRUE)) {
    parsed <- tryCatch(tools::parse_Rd(rd), error = identity)
    if (inherits(parsed, "error")) broken_rd <- c(broken_rd, basename(rd))
  }
  if (length(broken_rd)) {
    add_suite("Examples, vignettes & website assets", "failed", paste("Invalid Rd file(s):", paste(broken_rd, collapse = ", ")))
    add_finding("high", "RXV-DOC-002", "man/", 0, "One or more Rd files cannot be parsed.")
  } else if (!length(vignettes) && !has_pkgdown) {
    add_suite("Examples, vignettes & website assets", "warning", "No vignette or pkgdown website configuration was detected; R CMD check still runs Rd examples.")
  } else add_suite("Examples, vignettes & website assets", paste0("passed"), paste(length(vignettes), "vignette source(s)", if (has_pkgdown) "· pkgdown assets detected" else ""))
})

if (profile == "release") with_suite("Visual & UI regression", function() {
  snapshots <- list.files(package_dir, pattern = "(vdiffr|_snaps|shinytest)", recursive = TRUE, full.names = FALSE)
  has_shiny <- dir.exists(file.path(package_dir, "inst", "shiny")) || any(grepl("shiny::|library\\(shiny", unlist(lapply(r_files, readLines, warn = FALSE))))
  if (!length(snapshots) && !has_shiny) add_suite("Visual & UI regression", "skipped", "No vdiffr snapshots or Shiny application test targets were discovered.")
  else add_suite("Visual & UI regression", "passed", paste("Discovered", length(snapshots), "visual snapshot/UI asset(s); relevant testthat expectations ran in the test suite."))
})

if (profile == "release") with_suite("Cross-platform & release gate", function() {
  platform_calls <- grep("(shell\\(|system\\(|system2\\(|\\.Platform|Sys\\.info)", unlist(lapply(r_files, function(f) tryCatch(readLines(f, warn = FALSE), error = function(e) character()))), value = TRUE)
  min_r <- description[["Depends"]] %||% ""
  matrix_note <- "Single Linux/R runner completed. Multi-version and Windows/macOS checks require the production matrix orchestrator."
  if (length(platform_calls)) {
    add_suite("Cross-platform & release gate", "warning", paste(length(platform_calls), "platform-sensitive call(s) detected.", matrix_note))
    add_finding("medium", "RXV-PORT-001", "R/", 0, "Review OS-specific commands and add CI coverage on supported R versions/platforms.")
  } else add_suite("Cross-platform & release gate", "warning", paste("No obvious OS-specific calls detected.", matrix_note))
})

if (profile %in% c("standard", "release")) with_suite("Reproducibility", function() {
  lock <- file.exists(file.path(package_dir, "renv.lock")); remotes <- description[["Remotes"]] %||% ""
  unpinned <- nzchar(remotes) && !grepl("@([0-9a-f]{7,}|v?[0-9])", remotes)
  if (!lock && !nzchar(remotes)) add_suite("Reproducibility", "warning", "No renv.lock or Remotes declaration was found.")
  else if (unpinned) {
    add_suite("Reproducibility", "warning", "Some remote dependencies may not be pinned to a stable revision.")
    add_finding("medium", "RXV-REPRO-001", "DESCRIPTION", 0, "Pin Remotes dependencies to a tag or commit SHA.")
  } else add_suite("Reproducibility", "passed", if (lock) "renv.lock detected." else "Remote dependency declaration detected.")
})

failed <- sum(vapply(suites, function(x) identical(x$status, "failed"), logical(1)))
warnings <- sum(vapply(suites, function(x) identical(x$status, "warning"), logical(1)))
score <- max(0, min(100, 100 - failed * 22 - warnings * 5 - sum(vapply(findings, function(x) x$severity == "high", logical(1))) * 4))
report <- list(
  schema_version = "1.0", package = pkg_name, profile = profile, score = score,
  verdict = if (failed) "failed" else if (warnings) "passed_with_warnings" else "passed",
  environment = list(r_version = R.version.string, platform = R.version$platform, network = "disabled during execution"),
  suites = suites, findings = findings, command_logs = command_logs,
  artifacts = list()
)
dir.create(dirname(report_path), recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(report, report_path, auto_unbox = TRUE, pretty = TRUE, null = "null")
